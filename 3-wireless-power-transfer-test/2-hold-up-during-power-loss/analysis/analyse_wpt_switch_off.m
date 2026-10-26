% Analyse the OptoGrid hold-up after WPT switch-off (test 3.2a, BLE battery reads)
% Run from MATLAB (Run button, or `analyse_wpt_switch_off` from any folder).
% Input: <date_time>_wpt-off_ble*.mat written by ../og_holdup_ble_log.m, holding
% wpt_holdup_df (sample, t_s, bat_mv, ok) and config. By default the newest
% .mat in the recording folders (../device_<name>/2a-wpt-switch-off/) is used.
% The device idles on WPT power; the WPT is switched off by hand and reads
% go on until the device stops answering.
% WPT off: the start of the final run of reads more than offStep_V below the
% powered level (median of the first baseline_s), i.e. the drop the voltage
% never recovers from (the last good read must be offDrop_V below it); it is
% placed halfway between that read and the last powered read before it. Earlier drops that recover (brief WPT dropouts)
% are counted and shaded but not taken as the switch-off.
% Hold-up: from the switch-off to the last good read (lower bound) and to
% the first failed read (upper bound). The device may run below the nominal
% brown-out (vBrownOut); the time to vBrownOut is reported separately, from
% the running median, so sessions that die at different voltages compare.
% Calibration: with no supply the battery ADC samples at the bottom of the
% radio dips, well below the bank's running level (see
% analyse_ble_vs_scope.m). Reads after the switch-off are mapped to
% the running-mean bank voltage with calibration_readbattery_wpt.csv
% (interpolated within its range, linear fit to the table outside it); the
% discharge figures and numbers use the calibrated voltage. Reads with the
% WPT on are not calibrated (the dips are shallower there and not measured).
% An optional <recording>.meta.yml next to the log can set
% ble_calibration: none (e.g. with an added V_BANK capacitor the dips are
% mostly gone and the reads already follow the bank) or valid: false (skip).
% Discharge: with no WPT the bank supplies the idle load alone, so
%   C*dV/dt = -(I_load + I_self(V))
% The slope dV/dt (local linear fit over slopeWin_s) gives the capacitance
% implied by the test 1 idle current, and the load current implied by the
% nominal bank capacitance; one of the two must be off if they disagree.
% Figure 1: a) voltage over the test, with the switch-off, any earlier
%           dropouts, the hold-up, the raw BLE reads and the calibrated
%           bank level (running median of the calibrated reads);
%           b) implied capacitance and c) implied load current against
%           voltage during the discharge.
% Output: PNG figure and a one-row table in results/device_<name>/<subTest>/,
% named after the recording: _holdup.png, _holdup.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 2-hold-up-during-power-loss/
outDir  = fullfile(rootDir, 'results');
whichData = 'newest';   % 'newest' (newest .mat overall), 'all' (newest per device) or 'every'
subTest    = '2a-wpt-switch-off';   % recordings in ../device_<name>/<subTest>/
recPattern = '*_wpt-off_ble*.mat';

% Figure style (as analyse_load_states.m)
figWidth  = 18;                      % cm
ink       = [0.15 0.15 0.15];
offColor  = [0.93 0.93 0.93];        % shading after the switch-off
fitColor  = [0.27 0.47 0.67];

% Load current, from test 1 (task_summary.csv of every device in
% ../../1-current-consumption-test/analysis/results/)
test1Dir = fullfile(fileparts(fileparts(testDir)), '1-current-consumption-test', 'analysis', 'results');

% Power circuit (as analyse_load_states.m)
Ccell_mF  = 11;      % supercapacitor cell capacitance (mF), rated 3.3 V
nPar      = 3;       % cells in parallel per group
nSer      = 2;       % groups in series (6.6 V rating)
Rbal_kOhm = 200;     % balancing resistor across each group (kOhm)
leak_uA   = 0;       % extra constant self-consumption: cell + zener leakage (uA, datasheets)
vLdo      = 3.3;     % LDO output (V)
vBrownOut = 1.8;     % nominal brown-out voltage (V); the device may run below it

% Detection and fits
baseline_s = 2;      % powered level: median of the reads in the first baseline_s
offDrop_V  = 0.5;    % the last good read must be this far below the powered level (power really lost)
offStep_V  = 0.15;   % switch-off: first read of the final run more than this below the powered level
slopeWin_s = 2;      % window of the local linear fit for dV/dt (s)
smoothWin_s = 1;     % running-median window for the discharge trace (s)
outlier_V  = 0.1;    % reads this far from the running median are left out of the slopes
calFile    = fullfile(rootDir, 'calibration_readbattery_wpt.csv');   % BLE read -> bank level, no supply

%% Find recordings
recs = findRecordings(testDir, subTest, recPattern, whichData);
if isempty(recs), error('No %s found in %s', recPattern, fullfile(testDir, 'device_*', subTest)); end
loadI = test1Currents(test1Dir);
cal = readtable(calFile);                        % BLE_V, Actual_V, N
fprintf('Calibration %s: BLE %.2f-%.2f V\n', calFile, min(cal.BLE_V), max(cal.BLE_V));
C  = nPar*Ccell_mF/nSer;                        % mF, nominal bank
Rb = nSer*Rbal_kOhm;                            % kOhm
Iself = @(V) V/Rb + leak_uA/1000;               % mA

for s = 1:numel(recs)
    [~, recName] = fileparts(recs(s).file);
    fprintf('=== %s: %s ===\n', recs(s).folder, recName);
    L = load(recs(s).file, 'wpt_holdup_df', 'config');
    df = L.wpt_holdup_df; cfg = L.config;
    sesDir = fullfile(outDir, recs(s).folder);
    if ~isfolder(sesDir), mkdir(sesDir); end
    t = df.t_s; v = df.bat_mv/1000; ok = df.ok;
    [recDir, recBase] = fileparts(recs(s).file);
    recMeta = struct();
    if isfile(fullfile(recDir, [recBase '.meta.yml'])), recMeta = readMeta(fullfile(recDir, [recBase '.meta.yml'])); end
    if (isfield(recMeta, 'valid') && strcmpi(recMeta.valid, 'false')) || nnz(ok) < 10
        warning('%s: %d valid reads (or marked invalid in its meta.yml); skipped.', recName, nnz(ok));
        continue
    end
    useCal = ~(isfield(recMeta, 'ble_calibration') && strcmpi(recMeta.ble_calibration, 'none'));
    if ~useCal, fprintf('No calibration (meta.yml: ble_calibration none; %s)\n', ...
            regexprep(string(getfieldDefault(recMeta, 'added_capacitor', '')), '\s+#.*', '')); end
    fprintf('%d reads (%d good) over %.1f s; stopped: %s\n', height(df), nnz(ok), t(end), cfg.stopReason);

    %% Switch-off and hold-up
    Vpow0 = median(v(ok & t <= t(1) + baseline_s), 'omitnan');
    low = ok & v < Vpow0 - offDrop_V;
    iLast = find(ok, 1, 'last');
    if ~low(iLast)
        warning('%s: the voltage never stayed %.2f V below %.2f V; was the WPT switched off?', ...
            recName, offDrop_V, Vpow0);
        continue
    end
    lowS = ok & v < Vpow0 - offStep_V;           % below the powered level by the (small) switch-off step
    iPow = find(ok & ~lowS, 1, 'last');          % last powered read
    iOff = find(lowS & (1:numel(v))' > iPow, 1); % first read of the final drop
    tOff = (t(iPow) + t(iOff))/2;
    pow = ok & ~lowS & t < tOff;
    Vpow = median(v(pow), 'omitnan');            % powered (WPT on)
    Vstep = v(iOff);                             % first read without WPT
    iFail = find(~ok & t > t(iLast), 1);
    % earlier dropouts: runs of low reads before the last powered read
    lowEarly = low & (1:numel(v))' < iPow;
    dStart = find(lowEarly & ~[false; lowEarly(1:end-1)]);
    dEnd   = find(lowEarly & ~[lowEarly(2:end); false]);
    if ~isempty(dStart)
        fprintf('%d earlier WPT dropout(s), at %s s\n', numel(dStart), mat2str(round(t(dStart)', 1)));
    end
    HoldUp_s = t(iLast) - tOff;
    HoldUpMax_s = NaN; if ~isempty(iFail), HoldUpMax_s = t(iFail) - tOff; end
    Vlast = v(iLast);
    fprintf('WPT off at %.2f s: %.3f V -> %.3f V within one read (%.2f s)\n', tOff, Vpow, Vstep, ...
        t(iOff) - t(iOff - 1));
    fprintf('Hold-up: %.1f s to the last good read (%.3f V), < %.1f s to the first failed read\n', ...
        HoldUp_s, Vlast, HoldUpMax_s);

    %% Discharge
    k = (iOff:iLast)'; k = k(ok(k));
    td = t(k) - t(k(1)); vRawD = v(k);
    if useCal
        [vd, extrap] = applyCal(vRawD, cal);     % calibrated bank level (V)
    else
        vd = vRawD; extrap = false(size(vd));    % reads already follow the bank
    end
    fprintf('Calibrated: %.3f V just after the switch-off, %.3f V at the last read (%d%% of reads extrapolated)\n', ...
        vd(1), vd(end), round(100*mean(extrap)));
    VstepCal = vd(1); VlastCal = vd(end);
    vs = movmedian(vd, smoothWin_s, 'SamplePoints', td);   % running median
    good = abs(vd - vs) <= outlier_V;
    iBo = find(vs <= vBrownOut, 1);              % first time the trace reaches vBrownOut
    ToBrownOut_s = NaN; if ~isempty(iBo), ToBrownOut_s = t(k(iBo)) - tOff; end
    dVdt = nan(size(k));                         % local slope (V/s)
    for j = 1:numel(k)
        m = good & abs(td - td(j)) <= slopeWin_s/2;
        if nnz(m) >= 5, q = polyfit(td(m), vd(m), 1); dVdt(j) = q(1); end
    end
    Iidle = loadI.idle;
    Cimp = (Iidle + Iself(vd)) ./ -dVdt;         % mF at the test 1 idle current
    Iimp = -dVdt*C - Iself(vd);                  % mA at the nominal bank
    Qidle = Iidle*HoldUp_s;                      % mC drawn at the test 1 idle current
    Cavg = Qidle / (vd(1) - VlastCal);           % mF over the whole discharge
    Iavg = C*(vd(1) - VlastCal)/HoldUp_s;        % mA at the nominal bank
    E_mJ = 0.5*C*(vd(1)^2 - VlastCal^2);         % energy the nominal bank gives up (mF V^2 = mJ)
    mid = @(x) median(x(td <= 3), 'omitnan'); late = @(x) median(x(td >= td(end) - 3), 'omitnan');
    fprintf('Discharge (calibrated) %.3f -> %.3f V: slope %.3f V/s at the start, %.3f V/s at the end\n', ...
        vd(1), VlastCal, mid(dVdt), late(dVdt));
    fprintf('  at the test 1 idle current (%.2f mA): C = %.1f mF overall (%.1f at the start, %.1f at the end)\n', ...
        Iidle, Cavg, mid(Cimp), late(Cimp));
    fprintf('  at the nominal %.1f mF: load %.2f mA overall (%.2f at the start, %.2f at the end)\n', ...
        C, Iavg, mid(Iimp), late(Iimp));
    fprintf('  bank level reached %.2f V after %.1f s (NaN: died above it); died at %.2f V (BLE read %.2f V)\n', ...
        vBrownOut, ToBrownOut_s, VlastCal, Vlast);
    % predictions, nominal bank at the test 1 idle current
    tPred = @(V0, V1) Rb*C*log((V0 + Iidle*Rb) / (V1 + Iidle*Rb));
    fprintf('Predicted (nominal bank, test 1 idle): %.1f s from %.2f V, %.1f s from %.2f V, to %.2f V; %.1f s to %.2f V\n', ...
        tPred(Vpow, vBrownOut), Vpow, tPred(VstepCal, vBrownOut), VstepCal, vBrownOut, tPred(VstepCal, VlastCal), VlastCal);

    tbl = table(tOff, numel(dStart), Vpow, Vstep, Vlast, VstepCal, VlastCal, mean(extrap), HoldUp_s, HoldUpMax_s, ToBrownOut_s, ...
        mid(dVdt), late(dVdt), Cavg, mid(Cimp), late(Cimp), Iavg, E_mJ, tPred(Vpow, vBrownOut), ...
        tPred(VstepCal, vBrownOut), tPred(VstepCal, VlastCal), ...
        'VariableNames', {'Off_s', 'EarlierDropouts', 'Powered_V', 'AfterOff_V', 'LastGood_V', ...
        'AfterOffCal_V', 'LastGoodCal_V', 'ExtrapolatedFrac', ...
        'HoldUp_s', 'HoldUpMax_s', 'ToBrownOut_s', 'SlopeStart_Vps', 'SlopeEnd_Vps', 'C_atIdle_mF', ...
        'CStart_atIdle_mF', 'CEnd_atIdle_mF', 'Iload_atNominalC_mA', 'E_nominalC_mJ', ...
        'PredFromPowered_s', 'PredFromAfterOff_s', 'PredToLastGood_s'});
    writetable(tbl, fullfile(sesDir, [recName '_holdup.csv']));

    %% Figure (time from the switch-off)
    f = newFigure(figWidth, 16);
    tr = t - tOff;                               % s after WPT off
    xl = [floor(tr(1)) ceil(tr(end)) + 1];
    yl = [1.0, max(5, ceil(max(v(ok))*2)/2) + 0.75];
    % a: voltage over the test
    ax = axes(f, 'Units', 'centimeters', 'Position', [2.0 8.4 figWidth - 2.5 6.0]); hold(ax, 'on')
    patch(ax, [0 xl(2) xl(2) 0], yl([1 1 2 2]), offColor, 'EdgeColor', 'none', 'HandleVisibility', 'off');
    for j = 1:numel(dStart)                      % earlier brief dropouts
        a0 = (tr(dStart(j)) + tr(max(1, dStart(j) - 1)))/2; b0 = (tr(dEnd(j)) + tr(min(end, dEnd(j) + 1)))/2;
        patch(ax, [a0 b0 b0 a0], yl([1 1 2 2]), offColor, 'EdgeColor', 'none', 'HandleVisibility', 'off');
    end
    plot(ax, xl, vLdo*[1 1], ':', 'Color', ink, 'LineWidth', 1, 'HandleVisibility', 'off');
    plot(ax, xl, vBrownOut*[1 1], ':', 'Color', ink, 'LineWidth', 1, 'HandleVisibility', 'off');
    text(ax, 0.92*HoldUp_s, vLdo, sprintf('LDO output %.1f V', vLdo), 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'bottom', 'FontSize', 9, 'Color', ink);
    text(ax, xl(1) + 0.5, vBrownOut, sprintf('nominal brown-out %.1f V', vBrownOut), ...
        'VerticalAlignment', 'bottom', 'FontSize', 9, 'Color', ink);
    hR = scatter(ax, tr(ok), v(ok), 9, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.6);
    hC = plot(ax, tr(k), vs, '-', 'Color', fitColor, 'LineWidth', 1.8);
    hF = gobjects(0);
    for i = find(~ok)'
        hF = xline(ax, tr(i), '-', 'Color', [0.8 0.3 0.3], 'LineWidth', 1);
    end
    xline(ax, 0, '--', 'Color', ink, 'LineWidth', 1, 'HandleVisibility', 'off');
    % hold-up bracket and labels
    yA = yl(2) - 0.35;
    plot(ax, [0 HoldUp_s], [yA yA], '-', 'Color', ink, 'LineWidth', 1, 'HandleVisibility', 'off');
    plot(ax, [0 0; HoldUp_s HoldUp_s]', yA + [-0.12 0.12; -0.12 0.12]', '-', 'Color', ink, 'LineWidth', 1, 'HandleVisibility', 'off');
    text(ax, HoldUp_s/2, yA, sprintf('hold-up %.1f s', HoldUp_s), 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'bottom', 'FontSize', 11, 'FontWeight', 'bold', 'Color', ink);
    text(ax, 0.6, yA - 0.25, sprintf('WPT off (%.2f V \x2192 %.2f V)', Vpow, Vstep), 'VerticalAlignment', 'top', ...
        'FontSize', 9, 'Color', ink);
    plot(ax, HoldUp_s, Vlast, 'o', 'MarkerSize', 7, 'MarkerEdgeColor', [0.8 0.3 0.3], 'LineWidth', 1.5, 'HandleVisibility', 'off');
    text(ax, HoldUp_s - 0.8, (yl(1) + vBrownOut)/2 - 0.05, sprintf('last good read %.2f V at %.1f s', Vlast, HoldUp_s), ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'middle', 'FontSize', 9, 'Color', ink);
    calLabel = 'Bank level, calibrated (1 s median)';
    if ~useCal, calLabel = 'BLE read, 1 s running median'; end
    lh = [hR hC]; lt = {'BLE battery read', calLabel};
    if ~isempty(hF), lh(end+1) = hF; lt{end+1} = 'failed read (device off)'; end
    legend(ax, lh, lt, 'Location', 'northoutside', 'Orientation', 'horizontal', 'Box', 'off', 'FontSize', 9);
    hold(ax, 'off'); styleAxes(ax); ax.Layer = 'top';
    xlim(ax, xl); ylim(ax, yl);
    xlabel(ax, 'Time after WPT switch-off (s)'); ylabel(ax, 'Battery voltage (V)');
    panelLetter(ax, 'a', -0.09);
    vName = 'Bank voltage, calibrated (V)'; if ~useCal, vName = 'Bank voltage (BLE read, V)'; end
    wB = (figWidth - 5.0)/2;
    % b: implied capacitance against voltage
    ax = axes(f, 'Units', 'centimeters', 'Position', [2.0 1.4 wB 4.8]); hold(ax, 'on')
    plot(ax, vd(good), Cimp(good), '.', 'Color', fitColor, 'MarkerSize', 7);
    plot(ax, [min(vd) max(vd)], C*[1 1], '--', 'Color', ink, 'LineWidth', 1);
    text(ax, min(vd(good)), C, sprintf('nominal bank %.1f mF', C), 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'top', 'FontSize', 9, 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); set(ax, 'XDir', 'reverse');
    xlim(ax, [floor(min(vd(good))*10)/10 ceil(max(vd)*10)/10]);
    ylim(ax, [0 ceil(max(Cimp(good & isfinite(Cimp)))/10)*10]);
    xlabel(ax, vName); ylabel(ax, sprintf('C implied at %.2f mA (mF)', Iidle));
    panelLetter(ax, 'b', -0.24);
    % c: implied load current at the nominal bank
    ax = axes(f, 'Units', 'centimeters', 'Position', [2.0 + wB + 2.5 1.4 wB 4.8]); hold(ax, 'on')
    plot(ax, vd(good), Iimp(good), '.', 'Color', fitColor, 'MarkerSize', 7);
    plot(ax, [min(vd) max(vd)], Iidle*[1 1], '--', 'Color', ink, 'LineWidth', 1);
    text(ax, min(vd(good)), Iidle, sprintf('test 1 idle %.2f mA', Iidle), 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'bottom', 'FontSize', 9, 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); set(ax, 'XDir', 'reverse');
    xlim(ax, [floor(min(vd(good))*10)/10 ceil(max(vd)*10)/10]);
    ylim(ax, [0 max(1.5, ceil(max(Iimp(good))*2)/2)]);
    xlabel(ax, vName); ylabel(ax, sprintf('Load implied at %.1f mF (mA)', C));
    panelLetter(ax, 'c', -0.24);
    saveFigure(f, fullfile(sesDir, [recName '_holdup']));
    fprintf('Results saved to %s\n\n', sesDir);
end

%% Local functions
function v = getfieldDefault(s, f, d)
if isfield(s, f), v = s.(f); else, v = d; end
end

function meta = readMeta(file)
% Minimal reader for the flat "key: value  # comment" lines of meta.yml
meta = struct();
lines = splitlines(fileread(file));
for i = 1:numel(lines)
    tok = regexp(lines{i}, '^\s*([A-Za-z0-9_]+):\s*(.*)$', 'tokens', 'once');
    if isempty(tok) || isempty(tok{2}), continue, end
    val = regexprep(tok{2}, '\s+#.*$', '');
    meta.(matlab.lang.makeValidName(tok{1})) = strtrim(regexprep(val, '^"(.*)"$', '$1'));
end
end

function [y, extrap] = applyCal(x, cal)
% BLE read (no supply) -> running-mean bank voltage: interpolate within the
% calibration table, linear fit to the table outside it
p = polyfit(cal.BLE_V, cal.Actual_V, 1);
y = interp1(cal.BLE_V, cal.Actual_V, x, 'linear');
extrap = isnan(y);
y(extrap) = polyval(p, x(extrap));
end

function recs = findRecordings(testDir, subTest, pattern, which)
% Recordings matching pattern in ../device_<name>/<subTest>/. File names start
% with the date and time, so sorting by name sorts by time. 'newest': the
% newest overall; 'all': the newest per device; 'every': all of them.
d = dir(fullfile(testDir, 'device_*', subTest, pattern));
[~, o] = sort({d.name}); d = d(o);
recs = struct('folder', {}, 'file', {});
for i = 1:numel(d)
    [~, dev] = fileparts(fileparts(d(i).folder));
    recs(end+1) = struct('folder', fullfile(dev, subTest), 'file', fullfile(d(i).folder, d(i).name)); %#ok<AGROW>
end
if isempty(recs), return, end
switch which
    case 'newest'
        recs = recs(end);
    case 'all'
        dev = cellfun(@fileparts, {recs.folder}, 'UniformOutput', false);
        [~, last] = unique(dev, 'last');
        recs = recs(sort(last));
end
end

function I = test1Currents(test1Dir)
% Per-state load currents (mA) from the test 1 results, averaged over devices
d = dir(fullfile(test1Dir, '*', 'task_summary.csv'));
if isempty(d)
    error('No test 1 results in %s; run analyse_current_test (whichData = ''all'') first.', test1Dir);
end
idle = []; status = []; sham = []; imu = []; led = [];
for k = 1:numel(d)
    T = readtable(fullfile(d(k).folder, d(k).name), 'TextType', 'string');
    get = @(name) T.Mean_mA(T.Task == name);
    idle(end+1) = get("Idle"); status(end+1) = get("Status LED"); %#ok<AGROW>
    sham(end+1) = get("Sham LED"); imu(end+1) = get("IMU streaming"); %#ok<AGROW>
    Lt = readtable(fullfile(d(k).folder, 'led_summary.csv'));
    led(:, end+1) = Lt.LedMean_mA; %#ok<AGROW>
end
I = struct('idle', mean(idle), 'status', mean(status), 'sham', mean(sham), 'imu', mean(imu), ...
    'led', mean(led, 2), 'devices', {{d.folder}});
fprintf('Test 1 currents (mean of %d devices): idle %.2f, status %.2f, sham %.2f, IMU %.2f mA\n', ...
    numel(d), I.idle, I.status, I.sham, I.imu);
end

function panelLetter(ax, s, x)
% Bold panel letter above the top-left corner (x in normalized axes units)
if nargin < 3, x = -0.2; end
text(ax, x, 1.06, s, 'Units', 'normalized', 'FontSize', 13, 'FontWeight', 'bold', ...
    'Color', [0.15 0.15 0.15]);
end

function f = newFigure(wCm, hCm)
f = figure('Units', 'centimeters', 'Position', [2 2 wCm hCm], 'Color', 'w');
try theme(f, 'light'); catch, end  % R2025a+ may default to dark
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
    'DefaultTextInterpreter', 'none', 'DefaultAxesTickLabelInterpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 10, 'LabelFontSizeMultiplier', 1.1, ...
    'TitleFontSizeMultiplier', 9/8, 'TitleFontWeight', 'normal', 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', ...
    'XColor', ink, 'YColor', ink, 'Layer', 'bottom');
ax.XLabel.Interpreter = 'none'; ax.YLabel.Interpreter = 'none';
ax.Toolbar.Visible = 'off';
end

function saveFigure(f, base)
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
close(f);
end
