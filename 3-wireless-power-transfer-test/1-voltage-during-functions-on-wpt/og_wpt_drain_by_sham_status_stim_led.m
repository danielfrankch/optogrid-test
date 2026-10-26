% OptoGrid WPT test 3.1g: drain by sham + status + stim LED (status LED + 60 s continuous stimulation)
% The device is powered through the fixed external coil. After an idle
% baseline the status LED is switched on, then one LED is driven with a
% single continuous 60 s pulse at full amplitude while the status LED stays
% on (the firmware also holds the sham LED on during stimulation), while
% the "battery" (supply) voltage is read continuously. Afterwards the status
% LED is switched off and the final idle shows the recovery.
% Order: idle (baseline), status LED, status LED + stimulation (stimDur),
% idle until totalMax_s.
% One continuous pulse: pulse_width (stimDur + 2 ms) > period (stimDur +
% 1 ms) > duration (stimDur), as in og_wpt_stim_sweep_just_100percent_but_
% different_duration.m. The three fields are uint16 ms, so stimDur is at
% most 65.5 s. The pulse is programmed before the test starts. A triggered
% pulse cannot be stopped, so the cutoff vCut_mV is only logged (time of
% the first nBelow reads in a row at or below it); reads continue, and
% failed reads (brown-out) are stored as NaN.
% Phases end on a fixed schedule from the first read.
% Output: <date_time>_drain-by-sham-status-stim-led[_<position>][_<recNote>].mat in recDir (date_time =
% when saved), holding the table wpt_drain_df with columns sample, t_s (time
% since the first read, from the PC clock), bat_mv and state ("idle",
% "status", "status+opto_LED<n>_a<amplitude>_d<duration>ms"), and config
% (settings, plus the trigger time and when the cutoff was first reached).
% Follows the conventions of og_wpt_drain_by_sham_status.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recKind    = 'drain-by-sham-status-stim-led';   % file name
recDir     = fullfile('device_LRV-O-0001', '1g-drain-by-sham-status-stim-led');   % log folder, next to this script
position   = '';   % device on the Tx coil, e.g. 'coil-bundle-5mm' or 'coil-center'; logged and added to the file name
recNote    = '';   % appended to the file name, e.g. '110uF' (conditions that differ from the default)

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 8.5, ...   % fixed external coil
    'layout', 'one side: the 3 turns bundled together; opposite side: turns about 5 cm apart');

% Stimulation: one continuous pulse (pulse_width > period > duration)
stimLed   = 1;       % LED number (LED n = bit n-1)
amplitude = 100;     % % of full amplitude
stimDur   = 60;      % s; period = stimDur + 1 ms, pulse_width = stimDur + 2 ms
pwmFreq   = 50000;

% Timing (s)
iti          = 3;    % idle baseline before the status LED
statusLead   = 3;    % status LED alone, before the trigger
totalMax_s   = 88;   % whole test, from the first read; the final idle fills up to this
endMargin_s  = 0.5;  % finish this early (one read can overrun)

% Cutoff (logged only)
vCut_mV = 1800;      % brown-out voltage
nBelow  = 2;         % reads in a row at or below vCut_mV (rejects a single bad read)

% Battery reads
fs = 100;            % battery sample rate (Hz); each read is a Bluetooth round trip

% Schedule
if round(1000*stimDur) + 2 > intmax('uint16')
    error('stimDur %g s is too long: pulse_width (stimDur + 2 ms) must fit in uint16 ms (max %.3f s).', ...
        stimDur, (double(intmax('uint16')) - 2)/1000);
end
stimState = sprintf('status+opto_LED%d_a%d_d%gms', stimLed, amplitude, 1000*stimDur);
phaseState = ["idle", "status", stimState, "idle"];
phaseEnd = cumsum([iti, statusLead, stimDur, 0]);
phaseEnd(end) = totalMax_s - endMargin_s;
if phaseEnd(end) - phaseEnd(end-1) < iti
    error('Tasks take too long: the final idle would be %.1f s (at least %g s needed within %g s).', ...
        phaseEnd(end) - phaseEnd(end-1), iti, totalMax_s);
end
fprintf('LED %d at %d%% for %g s with the status LED on; final idle %.1f s; %g s total\n', ...
    stimLed, amplitude, stimDur, phaseEnd(end) - phaseEnd(end-1), totalMax_s);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Program the pulse now, so it is not part of the test
optoSetting = pulseSetting(stimLed, amplitude, stimDur, pwmFreq);
og.OptoSetting = optoSetting;
if ~og.program
    error('Programming failed: device did not confirm the stimulation settings.');
end

% Battery log: one entry per read
log = struct('t', [], 'mv', [], 'state', strings(0, 1));
trigger_s = NaN; cutoff_s = NaN;
stopReason = "completed";
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

try
    %% Baseline
    mark('Baseline: idle');
    log = readBattery(og, t0, phaseEnd(1), phaseState(1), fs, log);

    %% Status LED
    og.toggleStatusLED(1);
    mark('Status LED on');
    log = readBattery(og, t0, phaseEnd(2), phaseState(2), fs, log);

    %% Status LED + stimulation
    trigger_s = toc(t0);
    if ~og.trigger, warning('Trigger not confirmed'); end
    mark(sprintf('Stimulation: LED %d at %d%% for %g s, status LED on', stimLed, amplitude, stimDur));
    [log, cutoff_s] = readBattery(og, t0, trigger_s + stimDur, phaseState(3), fs, log, vCut_mV, nBelow);
    if ~isnan(cutoff_s), mark(sprintf('Cutoff %g mV first reached at %.2f s', vCut_mV, cutoff_s)); end
    og.toggleStatusLED(0);

    %% Final idle (recovery)
    mark('Final idle');
    log = readBattery(og, t0, phaseEnd(4), phaseState(4), fs, log);
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
wpt_drain_df = table(sample, log.t, log.mv, log.state, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'state'});
config = struct('deviceName', deviceName, 'coil', coil, 'position', position, 'optoSetting', optoSetting, ...
    'stimLed', stimLed, 'amplitude', amplitude, 'stimDur_s', stimDur, 'iti_s', iti, ...
    'statusLead_s', statusLead, 'totalMax_s', totalMax_s, 'fs', fs, ...
    'phaseState', phaseState, 'phaseEnd_s', phaseEnd, 'trigger_s', trigger_s, ...
    'vCut_mV', vCut_mV, 'nBelow', nBelow, 'cutoff_s', cutoff_s, 'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + "_" + recKind;
if ~isempty(position), outFile = outFile + "_" + position; end
if ~isempty(recNote), outFile = outFile + "_" + recNote; end
outFile = fullfile(outDir, outFile + ".mat");
save(outFile, 'wpt_drain_df', 'config');

%% Summary
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads (%s)\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(log.mv)), stopReason);
fprintf('Cutoff %g mV reached: %d', vCut_mV, ~isnan(cutoff_s));
if ~isnan(cutoff_s), fprintf(' (%.2f s after the trigger)', cutoff_s - trigger_s); end
fprintf('\n%-34s %8s %8s %8s\n', 'state', 'samples', 'mean mV', 'min mV');
states = unique(log.state, 'stable');
for i = 1:numel(states)
    v = log.mv(log.state == states(i));
    fprintf('%-34s %8d %8.0f %8.0f\n', states(i), numel(v), mean(v, 'omitnan'), min(v));
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

function [log, cut_s] = readBattery(og, t0, tEnd, state, fs, log, vCut, nBelow)
% Read the battery voltage repeatedly until tEnd seconds after t0, at up
% to fs Hz, labelling each sample with state and its time since t0. Failed
% reads are stored as NaN. With vCut given, cut_s is the time of the first
% read that completes nBelow reads in a row at or below vCut (mV); reading
% carries on. Reads are scheduled on a fixed grid; a slow read is not made
% up for.
if nargin < 7, vCut = -Inf; nBelow = Inf; end
cut_s = NaN;
period = 1/fs;
next = toc(t0); below = 0;
while toc(t0) < tEnd
    if toc(t0) < next, pause(next - toc(t0)); end
    [v, ok] = og.readbattery();
    if ~ok, v = NaN; end
    log.t(end+1, 1) = toc(t0);
    log.mv(end+1, 1) = v;
    log.state(end+1, 1) = state;
    below = (below + 1) * (v <= vCut);       % NaN compares false and resets the count
    if below >= nBelow && isnan(cut_s), cut_s = log.t(end); end
    next = max(next + period, toc(t0));
end
end
