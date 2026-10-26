% OptoGrid WPT test 3.1d: stimulation duration sweep at 100 % amplitude
% The device is powered through the fixed external coil. LED 1 is driven
% with one continuous pulse of each duration in stimDurs, in turn, at the
% same amplitude, with the ITI in itis between consecutive pulses, while
% the "battery" (supply) voltage is read continuously. Idle fills the rest
% of the test, split evenly between the start and the end, so the whole
% test lasts totalMax_s.
% Order: idle, pulse 1, ITI 1, pulse 2, ..., ITI n-1, pulse n, idle.
% A pulse whose duration differs from the programmed one needs its own
% og.program. The first is sent before the test starts; the others are sent
% at the start of the ITI before their pulse (programming draws no
% measurable current, test 1). Phases end on a fixed schedule from the first
% read, so programming time comes out of the ITI rather than stretching the
% test. Same engine as og_wpt_stim_sweep_just_100percent_but_different_iti.m;
% only the settings differ.
% Output: <date_time>_<recKind>[_<recNote>].mat in recDir (date_time = when
% saved), holding the table wpt_opto_df with columns sample, t_s (time since
% the first read, from the PC clock), bat_mv, state ("idle" or
% "opto_LED<n>_a<amplitude>_d<duration>ms"), amplitude (0 when idle) and
% pulse (pulse number, 0 when idle), and config (settings, plus the trigger
% and programming times).
% Follows the conventions of og_wpt_stim_sweep.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recKind    = 'stim-duration';         % file name and sub-test folder
recDir     = fullfile('device_LRV-O-0001', '1d-stim-duration-sweep');   % log folder, next to this script
recNote    = '';   % appended to the file name, e.g. '110uF' (conditions that differ from the default)

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 8.5, ...   % fixed external coil
    'layout', 'one side: the 3 turns bundled together; opposite side: turns about 5 cm apart');

% Stimulation: one continuous pulse per trigger (pulse_width > period > duration)
stimLed   = 1;                             % LED number (LED n = bit n-1)
amplitude = 100;                           % % of full amplitude, every pulse
stimDurs  = [0.5 1 1.5 2 2.5 3];           % pulse durations (s), in test order
itis      = repmat(10, 1, numel(stimDurs) - 1);   % ITI between consecutive pulses (s)
pwmFreq   = 50000;

% Timing (s)
totalMax_s  = 85;    % whole test, from the first read
endMargin_s = 0.5;   % finish this early (one read can overrun)

% Battery reads
fs = 100;            % battery sample rate (Hz); each read is a Bluetooth round trip

% Schedule: idle at the start and end shares what the pulses and ITIs leave
nStim = numel(stimDurs);
if numel(itis) ~= nStim - 1
    error('itis needs %d values (one between each pair of pulses), not %d.', nStim - 1, numel(itis));
end
idleEdge = (totalMax_s - endMargin_s - sum(stimDurs) - sum(itis)) / 2;
if idleEdge < 1
    error('Pulses and ITIs take too long: %.1f s idle left at each end within %g s.', ...
        idleEdge, totalMax_s);
end
phaseState = "idle"; phaseDur = idleEdge; phasePulse = 0;
for k = 1:nStim
    if k > 1
        phaseState(end+1) = "idle"; phaseDur(end+1) = itis(k-1); phasePulse(end+1) = 0; %#ok<SAGROW>
    end
    phaseState(end+1) = sprintf('opto_LED%d_a%d_d%gms', stimLed, amplitude, 1000*stimDurs(k)); %#ok<SAGROW>
    phaseDur(end+1) = stimDurs(k); phasePulse(end+1) = k;                                         %#ok<SAGROW>
end
phaseState(end+1) = "idle"; phaseDur(end+1) = idleEdge; phasePulse(end+1) = 0;
phaseEnd = cumsum(phaseDur);
fprintf('LED %d at %d%%: %d pulses of %s s, ITIs %s s; %.2f s idle at each end; %g s total\n', ...
    stimLed, amplitude, nStim, strjoin(string(stimDurs), ', '), strjoin(string(itis), ', '), ...
    idleEdge, phaseEnd(end) + endMargin_s);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Program the first pulse now, so it is not part of the test
optoSetting = pulseSetting(stimLed, amplitude, stimDurs(1), pwmFreq);
og.OptoSetting = optoSetting;
if ~og.program
    error('Programming failed: device did not confirm the stimulation settings.');
end
programmedDur = stimDurs(1);

% Battery log: one entry per read
log = struct('t', [], 'mv', [], 'state', strings(0, 1), 'amp', [], 'pulse', []);
trigger_s = nan(nStim, 1); program_s = nan(nStim, 1); program_s(1) = 0;
stopReason = "completed";
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

try
    for p = 1:numel(phaseState)
        k = phasePulse(p);
        if k > 0
            %% Pulse k
            trigger_s(k) = toc(t0);
            mark(sprintf('Pulse %d of %d: %g s at %d%%', k, nStim, stimDurs(k), amplitude));
            if ~og.trigger, warning('Trigger %d not confirmed', k); end
        else
            %% Idle; program the next pulse first if its duration differs
            kNext = find(phasePulse(p+1:end) > 0, 1);
            if ~isempty(kNext), kNext = phasePulse(p + kNext); end
            if p > 1 && ~isempty(kNext) && stimDurs(kNext) ~= programmedDur
                tProg = toc(t0);
                optoSetting = pulseSetting(stimLed, amplitude, stimDurs(kNext), pwmFreq);
                og.OptoSetting = optoSetting;
                if ~og.program
                    error('Programming the %g s pulse failed.', stimDurs(kNext));
                end
                programmedDur = stimDurs(kNext);
                program_s(kNext) = tProg;
                mark(sprintf('ITI: programmed %g s pulse (%.2f s)', stimDurs(kNext), toc(t0) - tProg));
            elseif p == 1
                mark('Idle');
            end
        end
        log = readBattery(og, t0, phaseEnd(p), phaseState(p), amplitude*(k > 0), k, fs, log);
    end
    mark('Done');
catch err
    % keep what was logged (the device may have browned out and dropped the link)
    warning('Test stopped early: %s', err.message);
    stopReason = "error: " + string(err.message);
end

%% Save the battery data frame
nS = numel(log.mv);
sample = (1:nS)';
wpt_opto_df = table(sample, log.t, log.mv, log.state, log.amp, log.pulse, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'state', 'amplitude', 'pulse'});
config = struct('deviceName', deviceName, 'coil', coil, 'optoSetting', optoSetting, ...
    'stimLed', stimLed, 'amplitude', amplitude, 'stimDurs_s', stimDurs, 'itis_s', itis, ...
    'idleEdge_s', idleEdge, 'totalMax_s', totalMax_s, 'fs', fs, ...
    'phaseState', phaseState, 'phaseEnd_s', phaseEnd, 'phasePulse', phasePulse, ...
    'trigger_s', trigger_s, 'program_s', program_s, 'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + "_" + recKind;
if ~isempty(recNote), outFile = outFile + "_" + recNote; end
outFile = fullfile(outDir, outFile + ".mat");
save(outFile, 'wpt_opto_df', 'config');

%% Summary
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads (%s)\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(log.mv)), stopReason);
fprintf('%-26s %8s %8s %8s\n', 'phase', 'samples', 'mean mV', 'min mV');
fprintf('%-26s %8d %8.0f %8.0f\n', 'idle', nnz(log.pulse == 0), ...
    mean(log.mv(log.pulse == 0), 'omitnan'), min(log.mv(log.pulse == 0)));
for k = 1:nStim
    v = log.mv(log.pulse == k);
    fprintf('%-26s %8d %8.0f %8.0f\n', sprintf('pulse %d (%s)', k, phaseState(2*k)), numel(v), ...
        mean(v, 'omitnan'), min(v));
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

function log = readBattery(og, t0, tEnd, state, amp, pulse, fs, log)
% Read the battery voltage repeatedly until tEnd seconds after t0, at up
% to fs Hz, labelling each sample with state, amplitude, pulse number and
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
    log.pulse(end+1, 1) = pulse;
    next = max(next + period, toc(t0));
end
end
