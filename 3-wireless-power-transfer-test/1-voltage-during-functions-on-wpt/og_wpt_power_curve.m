% OptoGrid WPT test 3.1h: Rx power curve from a load ladder at equilibrium
% The device is powered through the fixed external coil. The load is raised
% step by step and held at each step long enough to settle, while the
% "battery" (supply) voltage is read continuously: idle, status LED, then
% status LED + one LED at each amplitude in amplitudes (the firmware also
% holds the sham LED on during stimulation), then idle to recover. The
% settled voltage against the load current gives the Rx line V = Voc - Rs*I
% and the power curve P = V*I, with its peak Voc^2/(4 Rs) at I = Voc/(2 Rs).
% Order: idle, status, status + LED at amplitudes(1), ..., status + LED at
% amplitudes(end), idle until totalMax_s.
% Nominal load per step (in regulation, VCC = 3.3 V) from the currents in
% the settings, with the LED current assumed proportional to amplitude:
%   status + LED at a% = status_mA + (sham_mA - idle_mA) + (stim_mA - sham_mA)*a/100.
% Below the LDO regulation voltage the device draws less than nominal, so
% only steps that stay in regulation give an independent point on the line.
% Each amplitude is one continuous pulse (pulse_width > period > duration)
% of stepDur - offGap seconds; the next amplitude is programmed once the
% pulse has ended (about 0.6 s, no reads meanwhile) and triggered at the
% start of the next step, so the LED is off for about offGap at each step
% change. The first amplitude is programmed before the test starts. Steps
% start on a fixed schedule from the first read.
% Output: <date_time>_power-curve[_<position>][_<recNote>].mat in recDir (date_time =
% when saved), holding the table wpt_power_df with columns sample, t_s
% (time since the first read, from the PC clock), bat_mv, state ("idle",
% "status", "status+opto_LED<n>_a<amplitude>", "status+program"), amplitude
% (0 without stimulation) and load_mA (nominal load of the state; NaN while
% programming), and config (settings, step schedule, trigger and
% programming times).
% Follows the conventions of og_wpt_stim_sweep.m and og_wpt_drain_by_sham_status_stim_led.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recKind    = 'power-curve';           % file name
recDir     = fullfile('device_LRV-O-0001', '1h-power-curve');   % log folder, next to this script
position   = '';   % device on the Tx coil, e.g. 'coil-bundle-5mm' or 'coil-center'; logged and added to the file name
recNote    = '';   % appended to the file name, e.g. '110uF' (conditions that differ from the default)

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 8.5, ...   % fixed external coil
    'layout', 'one side: the 3 turns bundled together; opposite side: turns about 5 cm apart');

% Nominal device currents with VCC in regulation (mA)
idle_mA   = 1.11;    % connected idle (test 1, mean of two devices)
status_mA = 4.78;    % status LED on
sham_mA   = 3.72;    % sham LED on
stim_mA   = 11.04;   % stimulation at 100 %: sham + cortical LED

% Stimulation ladder
stimLed    = 1;                              % LED number (LED n = bit n-1)
amplitudes = [5 10 15 20 30 45 65 100];      % % of full amplitude, rising load
pwmFreq    = 50000;

% Timing (s)
idleDur     = 5;     % baseline
statusDur   = 6;     % status LED alone
stepDur     = 8;     % each amplitude step, trigger to trigger
offGap      = 1.0;   % pulse ends this long before the next step (programming takes about 0.6 s)
totalMax_s  = 88;    % whole test, from the first read; the final idle fills up to this
endMargin_s = 0.5;   % finish this early (one read can overrun)
minFinal_s  = 8;     % shortest final idle (recovery)

% Battery reads
fs = 100;            % battery sample rate (Hz); each read is a Bluetooth round trip

% Schedule
nAmp = numel(amplitudes);
pulseDur = stepDur - offGap;
if round(1000*pulseDur) + 2 > intmax('uint16')
    error('stepDur - offGap = %g s is too long for the uint16 ms pulse fields.', pulseDur);
end
stepStart = idleDur + statusDur + stepDur*(0:nAmp-1);     % trigger times
stimEnd   = stepStart(end) + stepDur;                     % status LED off here
finalIdle = totalMax_s - endMargin_s - stimEnd;
if finalIdle < minFinal_s
    error('Steps take too long: the final idle would be %.1f s (at least %g s needed within %g s).', ...
        finalIdle, minFinal_s, totalMax_s);
end
stepLoad_mA = status_mA + (sham_mA - idle_mA) + (stim_mA - sham_mA)*amplitudes/100;
fprintf('Loads (nominal, mA): idle %.2f, status %.2f, status + LED %s\n', idle_mA, status_mA, ...
    strjoin(compose('%d%%: %.2f', amplitudes(:), stepLoad_mA(:)), ', '));
fprintf('%d steps of %g s (pulse %g s); final idle %.1f s; %g s total\n', ...
    nAmp, stepDur, pulseDur, finalIdle, totalMax_s);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Program the first amplitude now, so it is not part of the test
optoSetting = pulseSetting(stimLed, amplitudes(1), pulseDur, pwmFreq);
og.OptoSetting = optoSetting;
if ~og.program
    error('Programming failed: device did not confirm the stimulation settings.');
end

% Battery log: one entry per read
log = struct('t', [], 'mv', [], 'state', strings(0, 1), 'amp', [], 'load', []);
trigger_s = nan(1, nAmp); program_s = nan(1, nAmp); program_s(1) = 0;
stopReason = "completed";
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

try
    %% Baseline
    mark('Baseline: idle');
    log = readBattery(og, t0, idleDur, "idle", 0, idle_mA, fs, log);

    %% Status LED
    og.toggleStatusLED(1);
    mark('Status LED on');
    log = readBattery(og, t0, stepStart(1), "status", 0, status_mA, fs, log);

    %% Amplitude ladder, status LED on
    for k = 1:nAmp
        if k > 1
            % previous pulse has ended: program this amplitude, then wait for the step start
            program_s(k) = toc(t0);
            og.OptoSetting = pulseSetting(stimLed, amplitudes(k), pulseDur, pwmFreq);
            if ~og.program, error('Programming %d%% failed.', amplitudes(k)); end
            log = readBattery(og, t0, stepStart(k), "status+program", 0, NaN, fs, log);
        end
        trigger_s(k) = toc(t0);
        if ~og.trigger, warning('Trigger %d not confirmed', k); end
        mark(sprintf('Step %d of %d: LED %d at %d%% (nominal %.2f mA)', k, nAmp, stimLed, ...
            amplitudes(k), stepLoad_mA(k)));
        state = sprintf('status+opto_LED%d_a%d', stimLed, amplitudes(k));
        log = readBattery(og, t0, trigger_s(k) + pulseDur, state, amplitudes(k), stepLoad_mA(k), fs, log);
    end
    log = readBattery(og, t0, stimEnd, "status", 0, status_mA, fs, log);
    og.toggleStatusLED(0);

    %% Final idle (recovery)
    mark('Final idle');
    log = readBattery(og, t0, totalMax_s - endMargin_s, "idle", 0, idle_mA, fs, log);
    mark('Done');
catch err
    % keep what was logged (the device may have browned out and dropped the link)
    warning('Test stopped early: %s', err.message);
    stopReason = "error: " + string(err.message);
    try og.toggleStatusLED(0); catch, end
end

%% Save the battery data frame
nS = numel(log.mv);
sample = (1:nS)';
wpt_power_df = table(sample, log.t, log.mv, log.state, log.amp, log.load, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'state', 'amplitude', 'load_mA'});
config = struct('deviceName', deviceName, 'coil', coil, 'position', position, 'optoSetting', optoSetting, ...
    'stimLed', stimLed, 'amplitudes', amplitudes, 'pwmFreq', pwmFreq, ...
    'currents_mA', struct('idle', idle_mA, 'status', status_mA, 'sham', sham_mA, 'stim', stim_mA), ...
    'stepLoad_mA', stepLoad_mA, 'idleDur_s', idleDur, 'statusDur_s', statusDur, ...
    'stepDur_s', stepDur, 'pulseDur_s', pulseDur, 'offGap_s', offGap, 'stepStart_s', stepStart, ...
    'totalMax_s', totalMax_s, 'fs', fs, 'trigger_s', trigger_s, 'program_s', program_s, ...
    'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + "_" + recKind;
if ~isempty(position), outFile = outFile + "_" + position; end
if ~isempty(recNote), outFile = outFile + "_" + recNote; end
outFile = fullfile(outDir, outFile + ".mat");
save(outFile, 'wpt_power_df', 'config');

%% Summary: last 2 s of each state
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads (%s)\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(log.mv)), stopReason);
fprintf('%-28s %10s %14s\n', 'state', 'load mA', 'last 2 s mV');
runStart = find([true; log.state(2:end) ~= log.state(1:end-1)]);
runEnd = [runStart(2:end) - 1; nS];
for r = 1:numel(runStart)
    if log.state(runStart(r)) == "status+program", continue, end
    k = runStart(r):runEnd(r);
    k = k(log.t(k) > log.t(runEnd(r)) - 2);
    fprintf('%-28s %10.2f %14.0f\n', log.state(runStart(r)), log.load(runStart(r)), mean(log.mv(k), 'omitnan'));
end
fprintf('Saved %s\n', outFile);

%% Local functions
function s = pulseSetting(led, amplitude, dur_s, pwmFreq)
% One continuous pulse of dur_s per trigger: pulse_width > period > duration
d = round(1000*dur_s);   % ms
s = struct( ...
    'sequence_length', 1, ...
    'led_selection',   bitset(uint64(0), led), ...
    'duration',        d, ...            % ms
    'period',          d + 1, ...        % ms
    'pulse_width',     d + 2, ...        % ms
    'amplitude',       amplitude, ...
    'pwm_frequency',   pwmFreq, ...
    'ramp_up',         0, ...
    'ramp_down',       0);
end

function log = readBattery(og, t0, tEnd, state, amp, load, fs, log)
% Read the battery voltage repeatedly until tEnd seconds after t0, at up
% to fs Hz, labelling each sample with state, amplitude, nominal load and
% its time since t0. Failed reads are stored as NaN. Reads are scheduled on
% a fixed grid; a slow read is not made up for.
period = 1/fs;
next = toc(t0);
while toc(t0) < tEnd
    if toc(t0) < next, pause(next - toc(t0)); end
    [v, ok] = og.readbattery();
    if ~ok, v = NaN; end
    log.t(end+1, 1) = toc(t0);
    log.mv(end+1, 1) = v;
    log.state(end+1, 1) = state;
    log.amp(end+1, 1) = amp;
    log.load(end+1, 1) = load;
    next = max(next + period, toc(t0));
end
end
