% OptoGrid wireless power transfer (WPT) test 3: stimulation amplitude sweep
% The device is powered through the fixed external coil. LED 1 is driven
% with one continuous 5 s pulse at each amplitude in amplitudes, in turn,
% with an ITI between them, while the "battery" (supply) voltage is read
% continuously. Idle fills the rest of the test, split evenly between the
% start and the end, so the whole test lasts totalMax_s.
% Order: idle, stim (amplitude 1), ITI, stim (amplitude 2), ..., ITI,
% stim (last amplitude), idle.
% Each amplitude needs its own og.program. The first is sent before the
% test starts; the others are sent at the start of the ITI before their
% stimulation (programming draws no measurable current, test 1). Phases end
% on a fixed schedule from the first read, so programming time comes out of
% the ITI rather than stretching the test.
% Output: wpt_opto_<date_time>.mat in recDir, holding the table wpt_opto_df
% with columns sample, t_s (time since the first read, from the PC clock),
% bat_mv, state ("idle" or "opto_LED1_a<amplitude>") and amplitude (0 when
% idle), and config (settings, plus the trigger and programming times).
% Follows the conventions of og_wpt_test_2.m.
clear; clc;

%% Settings
deviceName = 'LRV-O-0001';
zmqSocket  = 'tcp://localhost:5555';  % OptoGrid bridge
recDir     = 'device_LRV-O-0001';     % log folder, next to this script

% WPT link (logged only)
coil = struct('turns', 3, 'width_cm', 17, 'height_cm', 5);   % fixed external coil

% Stimulation: one pulse per trigger (period > duration)
stimLed    = 1;                              % LED number (LED n = bit n-1)
amplitudes = [20 40 60 70 80 90 100];        % % of full amplitude, in test order
optoSetting = struct( ...
    'sequence_length', 1, ...
    'led_selection',   bitset(uint64(0), stimLed), ...
    'duration',        5000, ...             % ms
    'period',          5001, ...             % ms
    'pulse_width',     5002, ...             % ms
    'amplitude',       amplitudes(1), ...    % set per stimulation
    'pwm_frequency',   50000, ...
    'ramp_up',         0, ...
    'ramp_down',       0);

% Timing (s)
stimDur     = optoSetting.duration/1000;     % battery reads labelled as stimulation
iti         = 6;     % between stimulations
totalMax_s  = 85;    % whole test, from the first read
endMargin_s = 0.5;   % finish this early (one read can overrun)

% Battery reads
fs = 100;            % battery sample rate (Hz); each read is a Bluetooth round trip

% Schedule: idle at the start and end shares what the stimulations leave
nStim = numel(amplitudes);
idleEdge = (totalMax_s - endMargin_s - nStim*stimDur - (nStim - 1)*iti) / 2;
if idleEdge < 1
    error('Stimulations and ITIs take too long: %.1f s idle left at each end within %g s.', ...
        idleEdge, totalMax_s);
end
phaseState = "idle"; phaseDur = idleEdge; phaseAmp = 0;
for k = 1:nStim
    if k > 1
        phaseState(end+1) = "idle"; phaseDur(end+1) = iti; phaseAmp(end+1) = 0; %#ok<SAGROW>
    end
    phaseState(end+1) = sprintf('opto_LED%d_a%d', stimLed, amplitudes(k)); %#ok<SAGROW>
    phaseDur(end+1) = stimDur; phaseAmp(end+1) = amplitudes(k);              %#ok<SAGROW>
end
phaseState(end+1) = "idle"; phaseDur(end+1) = idleEdge; phaseAmp(end+1) = 0;
phaseEnd = cumsum(phaseDur);
fprintf('LED %d, %d amplitudes (%s %%), %g s each, %g s ITI; %.2f s idle at each end; %g s total\n', ...
    stimLed, nStim, strjoin(string(amplitudes), ', '), stimDur, iti, idleEdge, phaseEnd(end) + endMargin_s);

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);
og.toggleShamLED(0);

% Program the first amplitude now, so it is not part of the test
og.OptoSetting = optoSetting;
if ~og.program
    error('Programming failed: device did not confirm the stimulation settings.');
end
programmedAmp = amplitudes(1);

% Battery log: one entry per read
log = struct('t', [], 'mv', [], 'state', strings(0, 1), 'amp', []);
trigger_s = nan(nStim, 1); program_s = nan(nStim, 1); program_s(1) = 0;
stopReason = "completed";
t0 = tic;
mark = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

try
    for p = 1:numel(phaseState)
        if phaseAmp(p) > 0
            %% Stimulation at this amplitude
            k = find(amplitudes == phaseAmp(p), 1);
            trigger_s(k) = toc(t0);
            mark(sprintf('Stimulation %d of %d: amplitude %d%%', k, nStim, phaseAmp(p)));
            if ~og.trigger, warning('Trigger %d not confirmed', k); end
        else
            %% Idle; program the next amplitude first if one is due
            k = find(amplitudes == programmedAmp, 1) + 1;
            if p > 1 && k <= nStim && any(phaseAmp(p+1:end) == amplitudes(k))
                tProg = toc(t0);
                optoSetting.amplitude = amplitudes(k);
                og.OptoSetting = optoSetting;
                if ~og.program
                    error('Programming amplitude %d%% failed.', amplitudes(k));
                end
                programmedAmp = amplitudes(k);
                program_s(k) = tProg;
                mark(sprintf('ITI: programmed amplitude %d%% (%.2f s)', amplitudes(k), toc(t0) - tProg));
            elseif p == 1
                mark('Idle');
            end
        end
        log = readBattery(og, t0, phaseEnd(p), phaseState(p), phaseAmp(p), fs, log);
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
wpt_opto_df = table(sample, log.t, log.mv, log.state, log.amp, ...
    'VariableNames', {'sample', 't_s', 'bat_mv', 'state', 'amplitude'});
config = struct('deviceName', deviceName, 'coil', coil, 'optoSetting', optoSetting, ...
    'stimLed', stimLed, 'amplitudes', amplitudes, 'stimDur_s', stimDur, 'iti', iti, ...
    'idleEdge_s', idleEdge, 'totalMax_s', totalMax_s, 'fs', fs, ...
    'phaseState', phaseState, 'phaseEnd_s', phaseEnd, 'trigger_s', trigger_s, ...
    'program_s', program_s, 'stopReason', stopReason);
outDir = fullfile(fileparts(mfilename('fullpath')), recDir);
if ~isfolder(outDir), mkdir(outDir); end
outFile = fullfile(outDir, "wpt_opto_" + string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + ".mat");
save(outFile, 'wpt_opto_df', 'config');

%% Summary
totalElapsed = toc(t0);
fprintf('\n%d samples in %.1f s: achieved %.1f Hz (fs = %g Hz), %d failed reads (%s)\n', ...
    nS, totalElapsed, nS/totalElapsed, fs, sum(isnan(log.mv)), stopReason);
states = unique(log.state, 'stable');
fprintf('%-18s %8s %8s %8s\n', 'state', 'samples', 'mean mV', 'min mV');
for i = 1:numel(states)
    v = log.mv(log.state == states(i));
    fprintf('%-18s %8d %8.0f %8.0f\n', states(i), numel(v), mean(v, 'omitnan'), min(v));
end
fprintf('Saved %s\n', outFile);

%% Local functions
function log = readBattery(og, t0, tEnd, state, amp, fs, log)
% Read the battery voltage repeatedly until tEnd seconds after t0, at up
% to fs Hz, labelling each sample with state, amplitude and its time since
% t0. Failed reads are stored as NaN. Reads are scheduled on a fixed grid;
% a slow read is not made up for.
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
    next = max(next + period, toc(t0));
end
end
