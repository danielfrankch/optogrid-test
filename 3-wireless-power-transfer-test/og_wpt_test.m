% OptoGrid wireless power transfer (WPT) test (test 3)
% The device is powered through a fixed external coil. It steps through
% known consumption states while its "battery" (supply) voltage is read
% continuously at a target of 100 Hz, so the voltage the WPT link can hold
% up is logged for each load. Order: idle, status LED, sham LED, sham +
% status LED, stimulation (single triggers), IMU streaming, with an ITI
% between tasks. Battery reads run throughout, ITIs included.
% Output: wpt_battery_<date_time>.mat in recDir, holding the table
% wpt_battery_df with columns sample, fs, bat_mv and state (state is "idle"
% unless a task is on: "status", "sham", "sham+status", "opto_<params>",
% "imu_<rate>Hz").
% Follows the conventions of 1-current-consumption-test/og_current_test.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recDir     = 'device_LRV-O-0001';         % log folder, next to this script

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 5);   % fixed external coil

% Task durations (s)
idleDur      = 5;  % Task 1: idle
statusLedDur = 5;  % Task 2: status LED on
shamLedDur   = 5;  % Task 3: sham LED on
bothLedDur   = 10;  % Task 4: sham + status LED on
imuDur       = 10;  % Task 6: IMU streaming
iti          = 3;   % between tasks, and between stimulation triggers

% Task 5: stimulation, one trigger, the stimulation, then one ITI, repeated
nTriggers = 5;

% Battery reads
fs         = 100;   % battery sample rate (Hz); each read is a Bluetooth round trip
imuRate_Hz = 100;   % IMU stream rate (set in firmware; logged only)

% Stimulation settings loaded into og.OptoSetting before og.program
stimLeds = [2 7];                          % LED numbers (LED n = bit n-1)
ledSel = uint64(0);
for n = stimLeds, ledSel = bitset(ledSel, n); end
optoSetting = struct( ...
    'sequence_length', 1, ...
    'led_selection',   ledSel, ...          % LEDs 2 and 7
    'duration',        500, ...             % ms
    'period',          25, ...              % ms
    'pulse_width',     5, ...              % ms
    'amplitude',       100, ...
    'pwm_frequency',   50000, ...
    'ramp_up',         0, ...
    'ramp_down',       0);

% State labels for the state column
optoState = sprintf('opto_LED%s_pw%gms_p%gms_d%gms', strjoin(string(stimLeds), '+'), ...
    optoSetting.pulse_width, optoSetting.period, optoSetting.duration);
imuState  = sprintf('imu_%gHz', imuRate_Hz);
stimDur   = optoSetting.duration/1000;   % s

% Planned duration
plannedTotal = idleDur + statusLedDur + shamLedDur + bothLedDur + imuDur ...
    + nTriggers*(stimDur + iti) + 5*iti;
fprintf('Stimulation state: %s (led_selection = %d)\n', optoState, optoSetting.led_selection);
fprintf('Planned test duration: about %g s\n', plannedTotal);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Program the stimulus now, so programming is not part of any task
og.OptoSetting = optoSetting;
if ~og.program
    error('Programming failed: device did not confirm the stimulation settings.');
end

% Battery log: one entry per read
log = struct('mv', [], 'state', strings(0, 1));
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

%% Task 1: Idle
mark('Task 1: idle');
log = readBattery(og, idleDur, "idle", fs, log);
log = readBattery(og, iti, "idle", fs, log);

%% Task 2: Status LED
og.toggleStatusLED(1);
mark('Task 2: status LED on');
log = readBattery(og, statusLedDur, "status", fs, log);
og.toggleStatusLED(0);
log = readBattery(og, iti, "idle", fs, log);

%% Task 3: Sham LED
og.toggleShamLED(1);
mark('Task 3: sham LED on');
log = readBattery(og, shamLedDur, "sham", fs, log);
og.toggleShamLED(0);
log = readBattery(og, iti, "idle", fs, log);

%% Task 4: Sham + status LED
og.toggleShamLED(1);
og.toggleStatusLED(1);
mark('Task 4: sham + status LED on');
log = readBattery(og, bothLedDur, "sham+status", fs, log);
og.toggleStatusLED(0);
og.toggleShamLED(0);
log = readBattery(og, iti, "idle", fs, log);

%% Task 5: Stimulation, one trigger then the ITI, repeated
for k = 1:nTriggers
    mark(sprintf('Task 5: trigger %d of %d', k, nTriggers));
    if ~og.trigger, warning('Trigger %d not confirmed', k); end
    log = readBattery(og, stimDur, string(optoState), fs, log);
    log = readBattery(og, iti, "idle", fs, log);
end

%% Task 6: IMU streaming
og.enableIMU;
mark('Task 6: IMU streaming');
log = readBattery(og, imuDur, string(imuState), fs, log);
og.disableIMU;
mark('Done');

%% Save the battery data frame
nS = numel(log.mv);
sample = (1:nS)';
bat_mv = log.mv;
state  = log.state;
wpt_battery_df = table(sample, repmat(fs, nS, 1), bat_mv, state, ...
    'VariableNames', {'sample', 'fs', 'bat_mv', 'state'});
config = struct('deviceName', deviceName, 'coil', coil, 'optoSetting', optoSetting, ...
    'stimLeds', stimLeds, 'iti', iti, 'nTriggers', nTriggers, 'fs', fs, 'imuRate_Hz', imuRate_Hz, ...
    'durations_s', struct('idle', idleDur, 'status', statusLedDur, 'sham', shamLedDur, ...
    'shamStatus', bothLedDur, 'imu', imuDur));
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = fullfile(outDir, "wpt_battery_" + string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + ".mat");
save(outFile, 'wpt_battery_df', 'config');

%% Summary
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(bat_mv)));
states = unique(state, 'stable');
fprintf('%-40s %8s %8s %8s\n', 'state', 'samples', 'mean mV', 'min mV');
for i = 1:numel(states)
    v = bat_mv(state == states(i));
    fprintf('%-40s %8d %8.0f %8.0f\n', states(i), numel(v), mean(v, 'omitnan'), min(v));
end
fprintf('Saved %s\n', outFile);

%% Local functions
function log = readBattery(og, dur, state, fs, log)
% Read the battery voltage repeatedly for dur seconds at up to fs Hz,
% labelling each sample with state. Failed reads are stored as NaN.
% Reads are scheduled on a fixed grid; a slow read is not made up for.
period = 1/fs;
t0 = tic;
next = 0;
while toc(t0) < dur
    if toc(t0) < next, pause(next - toc(t0)); end
    [v, ok] = og.readbattery();
    if ~ok, v = NaN; end
    log.mv(end+1, 1) = v;
    log.state(end+1, 1) = state;
    next = max(next + period, toc(t0));
end
end
