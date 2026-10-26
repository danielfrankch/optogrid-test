% OptoGrid hold-up test 3.2a / 3.2c: BLE battery reads through a power cut
% The device is powered through the fixed external coil and idles (status
% and sham LEDs off) while its "battery" (supply) voltage is read
% continuously. The WPT is switched off by hand partway through; reads go
% on until the device stops answering (brown-out, Bluetooth link lost) or
% totalMax_s is reached. The time from the voltage drop to the last good
% read is how long the bank keeps the device alive without power.
% Switch the WPT off early (before about offBefore_s) so the bank has the
% rest of the test to run down: the model predicts about 30 s at idle.
% A read normally returns in about 0.1 s; once the device is gone it waits
% for the receive timeout, shortened here to readTimeout_ms after
% connecting so a lost device ends the test quickly. The test ends after
% nFailed failed reads in a row.
% The same logger runs for test 3.2c (DC supply pulled by hand while the scope
% records the bank): set holdupKind = 'dc-cut'.
% Output: <date_time>_<holdupKind>_ble[_<recNote>].mat in recDir (date_time =
% when saved), holding the table
% wpt_holdup_df with columns sample, t_s (time since the first read, PC
% clock; the time the read was sent), bat_mv (NaN for a failed read) and ok,
% and config (settings, the time of the last good read and why the test
% stopped).
% Follows the conventions of ../1-voltage-during-functions-on-wpt/og_wpt_drain_by_sham_status.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
holdupKind = 'wpt-off';   % 'wpt-off' (3.2a, WPT switched off) or 'dc-cut' (3.2c, DC supply pulled, scope on the bank)
recNote    = '';          % appended to the file name, e.g. '4.77V_110uF' (supply, added capacitor)
subTests   = struct('wpt_off', '2a-wpt-switch-off', 'dc_cut', '2c-dc-cut-scope-and-ble');
recDir     = fullfile('device_LRV-O-0001', subTests.(strrep(holdupKind, '-', '_')));   % log folder, next to this script

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 8.5, ...   % fixed external coil
    'layout', 'one side: the 3 turns bundled together; opposite side: turns about 5 cm apart');

% Timing
totalMax_s     = 88;     % whole test, from the first read
offBefore_s    = 20;     % reminder only: switch the WPT off before this time
progressEvery_s = 5;     % print the time and voltage this often

% Battery reads
fs             = 1;    % battery sample rate (Hz); each read is a Bluetooth round trip
readTimeout_ms = 2000;   % reply timeout for each read once connected (OptoGrid default 60000)
nFailed        = 3;      % failed reads in a row that end the test (device gone)

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);
og.socket.socket.setReceiveTimeOut(readTimeout_ms);   % fail fast once the device is gone

fprintf('\nReading for up to %g s. Switch the WPT OFF by hand before about %g s.\n\n', ...
    totalMax_s, offBefore_s);

%% Read until the device stops answering
log = struct('t', [], 'mv', [], 'ok', false(0, 1));
period = 1/fs;
failed = 0; lastOk_s = NaN; nextPrint = 0;
stopReason = "time limit";
t0 = tic;
next = 0;
while toc(t0) < totalMax_s
    if toc(t0) < next, pause(next - toc(t0)); end
    tRead = toc(t0);
    try
        [v, ok] = og.readbattery();
    catch err
        % the socket refuses to send after a timed-out request
        v = NaN; ok = false;
        stopReason = "read error: " + string(err.message);
    end
    if ~ok, v = NaN; end
    log.t(end+1, 1) = tRead;
    log.mv(end+1, 1) = v;
    log.ok(end+1, 1) = ok;
    if ok
        failed = 0; lastOk_s = tRead;
    else
        failed = failed + 1;
        fprintf('[%6.2f s] read failed (%d in a row)\n', tRead, failed);
        if failed >= nFailed || startsWith(stopReason, "read error")
            if ~startsWith(stopReason, "read error")
                stopReason = sprintf("%d failed reads in a row", nFailed);
            end
            break
        end
    end
    if tRead >= nextPrint && ok
        fprintf('[%6.2f s] %5.0f mV\n', tRead, v);
        nextPrint = nextPrint + progressEvery_s;
    end
    next = max(next + period, toc(t0));
end
fprintf('[%6.2f s] Stopped: %s. Last good read at %.2f s.\n', toc(t0), stopReason, lastOk_s);

%% Save the battery data frame
nS = numel(log.mv);
sample = (1:nS)';
wpt_holdup_df = table(sample, log.t, log.mv, log.ok, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'ok'});
config = struct('deviceName', deviceName, 'coil', coil, 'fs', fs, 'totalMax_s', totalMax_s, ...
    'readTimeout_ms', readTimeout_ms, 'nFailed', nFailed, 'lastOk_s', lastOk_s, ...
    'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + "_" + holdupKind + "_ble";
if ~isempty(recNote), outFile = outFile + "_" + recNote; end
outFile = fullfile(outDir, outFile + ".mat");
save(outFile, 'wpt_holdup_df', 'config');

%% Summary
good = log.mv(log.ok);
if isempty(good), good = NaN; end
fprintf('\n%d reads (%d good) in %.1f s; first %.0f mV, last good %.0f mV at %.2f s\n', ...
    nS, nnz(log.ok), log.t(end), good(1), good(end), lastOk_s);
fprintf('Saved %s\n', outFile);
try og.cleanup; catch, end   % close the sockets; they may be stuck after a timeout
