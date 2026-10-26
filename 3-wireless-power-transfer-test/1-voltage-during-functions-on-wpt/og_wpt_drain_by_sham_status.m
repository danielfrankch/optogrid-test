% OptoGrid WPT test 3.1b: drain by sham + status LED (to brown-out or bothLedMax)
% The device is powered through the fixed external coil. Status LED, sham
% LED, then both together, each followed by an ITI, while the "battery"
% (supply) voltage is read continuously. Sham + status runs for at most
% bothLedMax s and is switched off early once the voltage reaches vCut
% (nBelow reads in a row), to see how the supply sags under sham + status
% and how it recovers. The final ITI stretches until totalMax_s.
% Order: ITI (baseline), status LED, ITI, sham LED, ITI, sham + status LED
% (until vCut or bothLedMax), ITI until totalMax_s.
% Output: <date_time>_drain-by-sham-status[_<position>][_<recNote>].mat in recDir (date_time = when saved), holding the table
% wpt_drain_df with columns sample, t_s (time since the first task, from
% the PC clock), bat_mv and state ("idle", "status", "sham", "sham+status"),
% and config (settings, plus the measured sham + status on-time and whether
% the cutoff was reached).
% Follows the conventions of og_wpt_load_states.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recDir     = fullfile('device_LRV-O-0001', '1b-drain-by-sham-status');   % log folder, next to this script
position   = '';   % device on the Tx coil, e.g. 'coil-bundle-5mm' or 'coil-center'; logged and added to the file name
recNote    = '';   % appended to the file name, e.g. '110uF' (conditions that differ from the default)

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 8.5, ...   % fixed external coil
    'layout', 'one side: the 3 turns bundled together; opposite side: turns about 5 cm apart');

% Task durations (s)
iti          = 3;    % baseline before the first task, and between tasks
statusLedDur = 0;   % Task 1: status LED on
shamLedDur   = 0;   % Task 2: sham LED on
bothLedMax   = 75;   % Task 3: sham + status LED on, at most
totalMax_s   = 88;   % whole test, from the first read; the final ITI fills up to this
endMargin_s  = 0.5;  % stop the final ITI this early (one read can overrun)

% Cutoff for Task 3
vCut_mV = 1800;      % brown-out voltage
nBelow  = 2;         % reads in a row at or below vCut_mV to switch off (rejects a single bad read)
nFailed = 5;         % failed reads in a row that also end Task 3 (device may have browned out)

% Battery reads
fs = 100;            % battery sample rate (Hz); each read is a Bluetooth round trip

% Planned duration
minFinalIti = totalMax_s - endMargin_s - (iti + statusLedDur + iti + shamLedDur + iti + bothLedMax);
if minFinalIti < iti
    error('Tasks take too long: the final ITI would be %.1f s (at least %g s needed within %g s).', ...
        minFinalIti, iti, totalMax_s);
end
fprintf('Planned test duration: %g s (final ITI at least %.1f s)\n', totalMax_s, minFinalIti);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Battery log: one entry per read
log = struct('t', [], 'mv', [], 'state', strings(0, 1));
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);
bothOn_s = NaN; cutoffReached = false;

try
    %% Baseline
    mark('Baseline: idle');
    log = readBattery(og, t0, iti, "idle", fs, log);

    %% Task 1: Status LED
    og.toggleStatusLED(1);
    mark('Task 1: status LED on');
    log = readBattery(og, t0, statusLedDur, "status", fs, log);
    og.toggleStatusLED(0);
    log = readBattery(og, t0, iti, "idle", fs, log);

    %% Task 2: Sham LED
    og.toggleShamLED(1);
    mark('Task 2: sham LED on');
    log = readBattery(og, t0, shamLedDur, "sham", fs, log);
    og.toggleShamLED(0);
    log = readBattery(og, t0, iti, "idle", fs, log);

    %% Task 3: Sham + status LED, until the cutoff or bothLedMax
    og.toggleShamLED(1);
    og.toggleStatusLED(1);
    mark('Task 3: sham + status LED on');
    tOn = toc(t0);
    [log, cutoffReached, stopReason] = readBattery(og, t0, bothLedMax, "sham+status", fs, log, ...
        vCut_mV, nBelow, nFailed);
    bothOn_s = toc(t0) - tOn;
    mark(sprintf('Task 3 ended after %.2f s (%s)', bothOn_s, stopReason));
    og.toggleStatusLED(0);
    og.toggleShamLED(0);

    %% Final ITI, until totalMax_s
    mark('Final ITI');
    log = readBattery(og, t0, totalMax_s - endMargin_s - toc(t0), "idle", fs, log);
    mark('Done');
catch err
    % keep what was logged (the device may have browned out and dropped the link)
    warning('Test stopped early: %s', err.message);
    stopReason = "error: " + string(err.message);
    if isnan(bothOn_s) && any(log.state == "sham+status")
        bothOn_s = toc(t0) - tOn;
    end
    try og.toggleStatusLED(0); og.toggleShamLED(0); catch, end
end

%% Save the battery data frame
nS = numel(log.mv);
sample = (1:nS)';
wpt_drain_df = table(sample, log.t, log.mv, log.state, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'state'});
config = struct('deviceName', deviceName, 'coil', coil, 'position', position, 'iti', iti, 'fs', fs, ...
    'durations_s', struct('status', statusLedDur, 'sham', shamLedDur, 'shamStatusMax', bothLedMax, ...
    'totalMax', totalMax_s), 'vCut_mV', vCut_mV, 'nBelow', nBelow, 'nFailed', nFailed, ...
    'shamStatusOn_s', bothOn_s, 'cutoffReached', cutoffReached, 'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + "_drain-by-sham-status";
if ~isempty(position), outFile = outFile + "_" + position; end
if ~isempty(recNote), outFile = outFile + "_" + recNote; end
outFile = fullfile(outDir, outFile + ".mat");
save(outFile, 'wpt_drain_df', 'config');

%% Summary
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(log.mv)));
fprintf('Sham + status on for %.2f s; cutoff at %g mV reached: %d (%s)\n', ...
    bothOn_s, vCut_mV, cutoffReached, stopReason);
states = unique(log.state, 'stable');
fprintf('%-14s %8s %8s %8s\n', 'state', 'samples', 'mean mV', 'min mV');
for i = 1:numel(states)
    v = log.mv(log.state == states(i));
    fprintf('%-14s %8d %8.0f %8.0f\n', states(i), numel(v), mean(v, 'omitnan'), min(v));
end
fprintf('Saved %s\n', outFile);

%% Local functions
function [log, cut, reason] = readBattery(og, t0, dur, state, fs, log, vCut, nBelow, nFailed)
% Read the battery voltage repeatedly for dur seconds at up to fs Hz,
% labelling each sample with state and its time since t0. Failed reads are
% stored as NaN. With vCut given, stop early after nBelow reads in a row at
% or below vCut (mV), or nFailed failed reads in a row.
% Reads are scheduled on a fixed grid; a slow read is not made up for.
if nargin < 7, vCut = -Inf; nBelow = Inf; nFailed = Inf; end
cut = false; reason = "duration";
period = 1/fs;
tStart = tic;
next = 0; below = 0; failed = 0;
while toc(tStart) < dur
    if toc(tStart) < next, pause(next - toc(tStart)); end
    [v, ok] = og.readbattery();
    if ~ok, v = NaN; end
    log.t(end+1, 1) = toc(t0);
    log.mv(end+1, 1) = v;
    log.state(end+1, 1) = state;
    below = (below + 1) * (v <= vCut);       % NaN compares false and resets the count
    failed = (failed + 1) * isnan(v);
    if below >= nBelow
        cut = true; reason = sprintf("cutoff: %d reads <= %g mV", nBelow, vCut);
        return
    end
    if failed >= nFailed
        reason = sprintf("%d failed reads in a row", nFailed);
        return
    end
    next = max(next + period, toc(tStart));
end
end
