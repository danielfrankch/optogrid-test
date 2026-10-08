% OptoGrid current consumption test
% Plays out a fixed sequence of events over Bluetooth while current is
% recorded externally. All timing settings are defined below.
clear; clc;

%% Settings
deviceName = 'FKY-O-0024';

% Task durations (s)
idleDur      = 5;  % Task 1: idle current
statusLedDur = 5;   % Task 2: status LED on
shamLedDur   = 5;   % Task 3: sham LED on
programDur   = 5;   % Task 4: hold after og.program
triggerDur   = 5;   % Task 5: hold after og.trigger (covers stimulation)
imuDur       = 15;  % Task 6: IMU streaming

% Repeated reads (Tasks 7-8)
nBatteryReads  = 10;   % Task 7: number of og.readbattery calls
batteryReadGap = 0.5;  % Task 7: pause between reads (s)
nULedChecks    = 10;   % Task 8: number of og.readuLEDCheck calls
uLedCheckGap   = 0.5;  % Task 8: pause between reads (s)
readLatencyEst = 0.3;  % Estimated Bluetooth round trip per read (s), for budget only

% Stimulation settings loaded into og.OptoSetting before og.program
nCh = 64;
optoSetting = struct( ...
    'sequence_length', 1, ...
    'led_selection',   intmax('uint64'), ...  % 2^64-1: all LEDs
    'duration',        (nCh*2 + 2) * 20, ...
    'period',          nCh*2 + 2, ...
    'pulse_width',     2, ...
    'amplitude',       100, ...
    'pwm_frequency',   50000, ...
    'ramp_up',         0, ...
    'ramp_down',       (nCh*2 + 2) * 5);

% Inter-trial interval between tasks (s)
iti = 3;

% Maximum total test time (s)
maxTotal = 80;

% Check planned duration fits within the budget
batteryDur = nBatteryReads * readLatencyEst + (nBatteryReads - 1) * batteryReadGap;
uLedDur    = nULedChecks * readLatencyEst + (nULedChecks - 1) * uLedCheckGap;
taskDurs = [idleDur statusLedDur shamLedDur programDur triggerDur imuDur batteryDur uLedDur];
plannedTotal = sum(taskDurs) + iti * (numel(taskDurs) - 1);
fprintf('Planned test duration: %g s (limit %g s)\n', plannedTotal, maxTotal);
if plannedTotal > maxTotal
    error('Planned duration %g s exceeds %g s limit. Reduce task durations or ITI.', ...
        plannedTotal, maxTotal);
end

%% Start
og = OptoGrid();
og.DeviceName = deviceName;
og.start
og.connect
og.toggleStatusLED(0);

t0 = tic;
logEvent = @(msg) fprintf('[%6.2f s] %s\n', toc(t0), msg);

%% Task 1: Idle current
logEvent('Task 1 start: idle');
pause(idleDur)
logEvent('Task 1 end');
pause(iti)

%% Task 2: Status LED current
logEvent('Task 2 start: status LED on');
og.toggleStatusLED(1)
pause(statusLedDur)
og.toggleStatusLED(0)
logEvent('Task 2 end');
pause(iti)

%% Task 3: Sham LED current
logEvent('Task 3 start: sham LED on');
og.toggleShamLED(1)
pause(shamLedDur)
og.toggleShamLED(0)
logEvent('Task 3 end');
pause(iti)

%% Task 4: Programming current
logEvent('Task 4 start: program');
og.OptoSetting = optoSetting;
og.program
pause(programDur)
logEvent('Task 4 end');
pause(iti)

%% Task 5: Stimulation trigger current
logEvent('Task 5 start: trigger');
og.trigger
pause(triggerDur)
logEvent('Task 5 end');
pause(iti)

%% Task 6: IMU streaming current
logEvent('Task 6 start: IMU streaming');
og.enableIMU
pause(imuDur)
og.disableIMU
logEvent('Task 6 end');
pause(iti)

%% Task 7: Battery read current
logEvent('Task 7 start: read battery');
batteryMv = nan(1, nBatteryReads);
for k = 1:nBatteryReads
    [batteryMv(k), ok] = og.readbattery();
    if ~ok
        warning('Battery read %d failed', k);
    end
    if k < nBatteryReads
        pause(batteryReadGap)
    end
end
logEvent(sprintf('Task 7 end: battery %s mV', mat2str(batteryMv)));
pause(iti)

%% Task 8: uLED check current
logEvent('Task 8 start: uLED check');
uLedCheck = cell(1, nULedChecks);
for k = 1:nULedChecks
    [uLedCheck{k}, ok] = og.readuLEDCheck();
    if ~ok
        warning('uLED check %d failed', k);
    end
    if k < nULedChecks
        pause(uLedCheckGap)
    end
end
logEvent('Task 8 end');
fprintf('uLED check results:\n');
for k = 1:nULedChecks
    fprintf('  %2d: %s\n', k, uLedCheck{k});
end

%% Done
totalElapsed = toc(t0);
fprintf('Test complete. Actual duration: %.2f s\n', totalElapsed);
if totalElapsed > maxTotal
    warning('Actual duration %.2f s exceeded %g s limit (Bluetooth command latency).', ...
        totalElapsed, maxTotal);
end
