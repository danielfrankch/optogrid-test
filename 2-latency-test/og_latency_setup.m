% OptoGrid latency test (test 2): device initialisation
% Connects, turns the status LED off and programs a single short stimulus,
% then ends. The trigger train is applied afterwards from the function
% generator (see triggerPeriod_ms / nTriggers) while the current is recorded.
% Follows the conventions of 1-current-consumption-test/og_current_test.m.
clear; clc;

%% Settings
deviceName = 'FKY-O-0024';
zmqSocket  = 'tcp://172.24.156.77:5555';  % OptoGrid bridge

% Stimulation programmed into the device, fired on each external trigger
optoSetting = struct( ...
    'sequence_length', 1, ...
    'led_selection',   uint64(1), ...  % LED 1 only
    'duration',        5, ...         % ms
    'period',          6, ...          % ms
    'pulse_width',     7, ...          % ms
    'amplitude',       100, ...
    'pwm_frequency',   50000, ...
    'ramp_up',         0, ...
    'ramp_down',       0);             % no ramp-down

% External trigger train, applied manually from the function generator after
% this script ends (for reference only; not used by the script)
triggerPeriod_ms = 31.3;   % not a multiple of the 7.5 ms Bluetooth connection interval
nTriggers        = 1917;   % about 60 s

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.ZMQSocket = zmqSocket;
og.start
og.connect
og.toggleStatusLED(0);

%% Program the stimulus
og.OptoSetting = optoSetting;
ok = og.program;
if ~ok
    error('Programming failed: device did not confirm the stimulation settings.');
end

%% Done
fprintf('Device ready: LED selection %d, %g ms pulse every %g ms, %g ms duration, no ramp-down.\n', ...
    optoSetting.led_selection, optoSetting.pulse_width, optoSetting.period, optoSetting.duration);
fprintf('Start the recording, then apply %d trigger pulses every %g ms (%.1f s).\n', ...
    nTriggers, triggerPeriod_ms, nTriggers*triggerPeriod_ms/1000);
