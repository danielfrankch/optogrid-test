% Analyse the OptoGrid WPT drain by sham + status + stim LED (test 3.1g: status LED + 60 s stimulation)
% Run from MATLAB (Run button, or `analyse_drain_by_sham_status_stim_led` from any folder).
% Input: <date_time>_drain-by-sham-status-stim-led*.mat written by ../og_wpt_drain_by_sham_status_stim_led.m,
% holding wpt_drain_df (sample, t_s, bat_mv, state) and config. By default the
% newest .mat in ../device_<name>/1g-drain-by-sham-status-stim-led/ is used.
% Sequence: idle baseline, status LED, status LED + one LED at full amplitude
% for one continuous pulse (sham LED also on during stimulation), idle.
% Every read carries its own PC time stamp (t_s); each read is a Bluetooth
% round trip, so the time resolution is one read interval.
% Stimulation edges come from the voltage itself: the first read halfway
% from the pre-trigger level down to the stimulation median, and the first
% read halfway back up from it to the final idle level (each edge is placed
% between that read and the one before). The plateau is the mean over the
% last plateauWin_s before the recovery edge.
% Drop and recovery: the step within one read (the fast part) and an
% exponential V = Vinf + A*exp(-t/tau) fitted from the second read after each
% edge (the slow part, the bank settling).
% Rx operating point: the Rx is a current source I_rx and the bank zener
% takes what the load and bank do not, V = Vk + Vs*ln(I_z/1 mA) + Rz*I_z with
% I_z = I_rx - I_use (soft-knee model of analyse_power_curve.m). I_rx comes
% from a recording at the same coil position named in the recording's
% <name>.meta.yml (run its analysis first):
%   power_curve_rec: <sub-test>/<rec>  (analyse_power_curve.m _summary.csv),
%     which also gives the zener knee;
%   rx_current_rec: <sub-test>/<rec>  (analyse_drain_by_sham_status.m
%     _rx_current.csv: median Rx current while that drain ran through
%     regulation), with the zener knee from zener_rec (a power-curve summary;
%     the zener is a property of the device, not of the coil position).
% With both, the idle and status voltages are predicted from the model and
% compared with the measured ones. At the plateau the zener carries almost
% nothing, so the Rx delivers about I_rx and P = V_plateau*I_rx. Without any
% key the Rx part is skipped. The load the device would draw with VCC in
% regulation is the test 1 sum idle + status + sham + LED.
% No readbattery calibration is applied: calibration_readbattery_wpt.csv
% (test 3.2c) holds for WPT off only.
% Figure 1: battery voltage over the session.
% Figure 2: a) drop at the trigger, b) recovery at the end, c) Rx power
%           against bank voltage (power-curve test) with the operating points.
% Output: figures and tables in results/device_<name>/1g-drain-by-sham-status-stim-led/,
% named after the recording: _overview.png, _drop_recovery.png, _epochs.csv,
% _summary.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 1-voltage-during-functions-on-wpt/
outDir  = fullfile(rootDir, 'results');
whichData  = 'newest';   % 'newest' (newest .mat overall), 'all' (newest per device) or 'every'
subTest    = '1g-drain-by-sham-status-stim-led';   % recordings in ../device_<name>/<subTest>/
recPattern = '*_drain-by-sham-status-stim-led*.mat';

% Figure style (as analyse_drain_by_sham_status.m, Paul Tol 'muted' palette)
figWidth      = 18;                  % cm
shadeStrength = 0.22;                % epoch shading (0 = white, 1 = full colour)
ink           = [0.15 0.15 0.15];
smoothWin_s   = 0.5;                 % running-mean window (s); dots show every read
stateHex      = {'#332288', '#DDCC77', '#117733'};   % idle, status, status + stimulation
fitColor      = [68 119 170]/255;

% Load currents from test 1 (task_summary.csv and led_summary.csv)
test1Dir = fullfile(fileparts(fileparts(testDir)), '1-current-consumption-test', 'analysis', 'results');

% Power chain (as analyse_drain_by_sham_status.m)
vLdo        = 3.3;   % LDO output (V)
ldoDropout  = 0.1;   % LDO dropout (V); CHECK against the LDO datasheet
vReg        = vLdo + ldoDropout;   % lowest bank voltage with VCC in regulation (V)
vBrownOut   = 2.5;   % brown-out voltage (V)

% Analysis windows (s)
plateauWin_s = 20;   % plateau = mean over the last plateauWin_s of the stimulation
zoomPre_s    = 2;    % Figure 2 zoom: before each edge
zoomPost_s   = [15 20];   % Figure 2 zoom: after the drop, after the recovery

%% Find recordings
recs = findRecordings(testDir, subTest, recPattern, whichData);
if isempty(recs), error('No %s found in %s', recPattern, fullfile(testDir, 'device_*', subTest)); end
tc = hexColors(stateHex);
loadI = test1Currents(test1Dir);

for s = 1:numel(recs)
    [~, recName] = fileparts(recs(s).file);
    fprintf('=== %s: %s ===\n', recs(s).folder, recName);
    L = load(recs(s).file, 'wpt_drain_df', 'config');
    df = L.wpt_drain_df; cfg = L.config;
    sesDir = fullfile(outDir, recs(s).folder);
    if ~isfolder(sesDir), mkdir(sesDir); end
    t = df.t_s; v = df.bat_mv/1000;   % V
    st = df.state;
    dtMed = median(diff(t));
    fprintf('%d reads over %.1f s: %.1f Hz achieved (fs = %g Hz), %d failed (%s)\n', ...
        height(df), t(end), height(df)/t(end), cfg.fs, sum(isnan(v)), cfg.stopReason);

    %% Epochs (scheduled states)
    runStart = find([true; st(2:end) ~= st(1:end-1)]);
    runEnd   = [runStart(2:end) - 1; height(df)];
    tEdge = [0; (t(runEnd(1:end-1)) + t(runStart(2:end)))/2; t(end) + dtMed/2];
    nR = numel(runStart);
    Epoch = (1:nR)'; State = st(runStart); Start_s = tEdge(1:end-1); End_s = tEdge(2:end);
    Reads = runEnd - runStart + 1;
    Mean_V = arrayfun(@(r) mean(v(runStart(r):runEnd(r)), 'omitnan'), (1:nR)');
    Min_V  = arrayfun(@(r) min(v(runStart(r):runEnd(r))), (1:nR)');
    epochTbl = table(Epoch, State, Start_s, End_s, Reads, Mean_V, Min_V);
    writetable(epochTbl, fullfile(sesDir, [recName '_epochs.csv']));
    disp(epochTbl);

    %% Stimulation edges from the voltage
    iStim = find(startsWith(st, "status+opto"));
    iPre  = find(st == "status");
    vPre  = mean(v(iPre(max(1, end-4):end)), 'omitnan');          % last reads before the trigger
    tTrig = cfg.trigger_s;
    vEnd  = mean(v(end-19:end), 'omitnan');                        % final idle level
    vLow  = median(v(iStim), 'omitnan');                            % rough plateau, for the edges
    iOn  = find(t > tTrig & v < (vPre + vLow)/2, 1);
    iOff = iOn - 1 + find(t(iOn:end) > t(iOn) + 1 & v(iOn:end) > (vLow + vEnd)/2, 1);
    tOn  = (t(iOn - 1) + t(iOn))/2;
    tOff = (t(iOff - 1) + t(iOff))/2;
    onTime = tOff - tOn;
    vPlat = mean(v(t > tOff - plateauWin_s & t < tOff), 'omitnan');
    fprintf('Stimulation seen from %.2f to %.2f s: %.2f s (programmed %g s, trigger sent at %.2f s)\n', ...
        tOn, tOff, onTime, cfg.stimDur_s, tTrig);

    % Fast step (one read) and slow settling (exponential from the second read)
    stepDrop = v(iOn) - v(iOn - 1);
    stepRec  = v(iOff) - v(iOff - 1);
    kD = (iOn + 1):(iOff - 1);
    pD = expFit(t(kD) - t(iOn), v(kD));
    kR = (iOff + 1):height(df);
    pR = expFit(t(kR) - t(iOff), v(kR));
    fprintf('Drop: %.3f V within one read, then to %.3f V (tau %.1f s); recovery: +%.3f V, then to %.3f V (tau %.1f s)\n', ...
        stepDrop, pD(1), pD(3), stepRec, pR(1), pR(3));

    %% Rx operating point (recordings named in the meta.yml)
    vIdle0 = Mean_V(1);
    [recDir, recBase] = fileparts(recs(s).file);
    meta = struct();
    if isfile(fullfile(recDir, [recBase '.meta.yml'])), meta = readMeta(fullfile(recDir, [recBase '.meta.yml'])); end
    devRes = fullfile(outDir, fileparts(recs(s).folder));    % results/device_<name>/
    Irx = NaN; zp = [NaN NaN NaN]; Ppk = NaN; rxSrc = "none"; zSrc = "none";
    if isfield(meta, 'power_curve_rec'), zSrc = string(meta.power_curve_rec); end
    if isfield(meta, 'zener_rec'), zSrc = string(meta.zener_rec); end
    if zSrc ~= "none"
        PC = readtable(fullfile(devRes, zSrc + "_summary.csv"), 'TextType', 'string');
        pc = @(q) PC.value(PC.quantity == q);
        zp = [pc("zener_vk_V"), pc("zener_vs_V"), pc("zener_rz_ohm")];
    end
    if isfield(meta, 'power_curve_rec')
        rxSrc = zSrc; Irx = pc("current_limit_mA"); Ppk = pc("peak_power_mW");
    elseif isfield(meta, 'rx_current_rec')
        rxSrc = string(meta.rx_current_rec);
        RC = readtable(fullfile(devRes, rxSrc + "_rx_current.csv"));
        Irx = median(RC.Irx_mA);
    end
    zV = @(Iz) zp(1) + zp(2)*log(Iz) + zp(3)*Iz/1000;           % V at zener current Iz (mA)
    vIdlePred = zV(Irx - loadI.idle); vStatusPred = zV(Irx - loadI.status);
    izPlat = zenerI(vPlat, zp(1), zp(2), zp(3));
    iPlat = Irx - izPlat; pPlat = vPlat*iPlat;                    % mA, mW
    izIdle = Irx - loadI.idle;
    iDemand = loadI.idle + loadI.status + loadI.sham + loadI.led(cfg.stimLed);   % mA at 3.3 V
    fprintf(['Rx (%s; zener %s): I_rx %.2f mA; idle %.3f V (model %.3f), status %.3f V (model %.3f); ' ...
        'plateau %.3f V -> %.1f mW; demand in regulation %.1f mA\n'], rxSrc, zSrc, Irx, vIdle0, vIdlePred, ...
        Mean_V(2), vStatusPred, vPlat, pPlat, iDemand);

    rows = {
        'trigger_sent_s', tTrig, 'PC clock'
        'stim_seen_on_s', tOn, 'halfway between the reads around the drop'
        'stim_seen_off_s', tOff, 'halfway between the reads around the recovery'
        'stim_seen_duration_s', onTime, sprintf('programmed %g s; resolution about one read (%.2f s)', cfg.stimDur_s, dtMed)
        'v_before_V', vPre, 'status LED, last reads before the trigger'
        'drop_step_V', stepDrop, 'within one read of the trigger'
        'drop_fit_vinf_V', pD(1), 'exponential from the second read'
        'drop_fit_tau_s', pD(3), ''
        'plateau_V', vPlat, sprintf('mean over the last %g s before the recovery', plateauWin_s)
        'plateau_min_V', min(v(iStim)), ''
        'margin_to_brownout_V', vPlat - vBrownOut, sprintf('brown-out %g V', vBrownOut)
        'below_regulation_V', vReg - vPlat, sprintf('VCC in regulation above %g V', vReg)
        'cutoff_reached', ~isnan(cfg.cutoff_s), sprintf('vCut %g mV', cfg.vCut_mV)
        'recovery_step_V', stepRec, 'within one read of the end'
        'recovery_fit_vinf_V', pR(1), ''
        'recovery_fit_tau_s', pR(3), ''
        'idle_start_V', vIdle0, ''
        'idle_end_V', vEnd, 'last 20 reads'
        'rx_current_mA', Irx, sprintf('I_rx from %s', rxSrc)
        'zener_from', NaN, zSrc
        'idle_model_V', vIdlePred, 'zener model at I_rx - test 1 idle current'
        'status_V', Mean_V(2), 'measured, status LED epoch'
        'status_model_V', vStatusPred, 'zener model at I_rx - test 1 status current'
        'idle_zener_power_mW', vIdle0*izIdle, sprintf('of %.1f mW from the Rx at idle', vIdle0*Irx)
        'plateau_zener_mA', izPlat, ''
        'plateau_rx_current_mA', iPlat, 'I_rx - zener current at the plateau'
        'plateau_rx_power_mW', pPlat, 'plateau V x that current'
        'rx_peak_power_mW', Ppk, 'measured useful peak at this position (power-curve test; NaN without one)'
        'demand_in_regulation_mA', iDemand, 'test 1: idle + status + sham + LED'
        'failed_reads', sum(isnan(v)), ''
        };
    T = cell2table(rows, 'VariableNames', {'quantity', 'value', 'note'});
    writetable(T, fullfile(sesDir, [recName '_summary.csv']));

    %% Figure 1: overview
    f = newFigure(figWidth, 8);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.2 15.8 5.6]); hold(ax, 'on')
    labels = ["Idle", "Status LED", sprintf("Status LED + LED %d at %d%% (%g s)", cfg.stimLed, cfg.amplitude, cfg.stimDur_s)];
    keys = ["idle", "status", "status+opto"];
    hs = gobjects(1, 3);
    for r = 1:nR
        k = find(arrayfun(@(x) startsWith(State(r), x), keys), 1, 'last');
        c = 1 - shadeStrength*(1 - tc(k, :));
        hs(k) = patch(ax, [Start_s(r) End_s(r) End_s(r) Start_s(r)], [0 0 6 6], c, 'EdgeColor', 'none');
    end
    plot(ax, t, v, '.', 'Color', [0.6 0.6 0.6], 'MarkerSize', 4, 'HandleVisibility', 'off');
    plot(ax, t, movmean(v, max(1, round(smoothWin_s/dtMed)), 'omitnan'), '-', 'Color', ink, ...
        'LineWidth', 1, 'HandleVisibility', 'off');
    xr = [0 t(end)];
    refLine(ax, xr, vReg, sprintf('VCC regulation %.1f V', vReg), ink);
    refLine(ax, xr, vBrownOut, sprintf('brown-out %.1f V', vBrownOut), ink);
    plot(ax, [tOn tOff], vPlat*[1 1] - 0.08, '-', 'Color', tc(3, :), 'LineWidth', 1.5, 'HandleVisibility', 'off');
    text(ax, (tOn + tOff)/2, vPlat - 0.1, sprintf('plateau %.2f V, stimulation seen for %.1f s', vPlat, onTime), ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', 'FontSize', 8, 'Color', ink);
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, xr); ylim(ax, [2 5]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Battery read (V)');
    legend(ax, hs, cellstr(labels), 'Location', 'northoutside', 'Orientation', 'horizontal', 'Box', 'off', ...
        'FontSize', 8, 'Interpreter', 'none');
    saveFigure(f, fullfile(sesDir, [recName '_overview']));

    %% Figure 2: drop, recovery, Rx operating point
    f = newFigure(figWidth, 7);
    w = 4.6; gap = 1.35; x0 = 1.4;
    % a: drop
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0 1.2 w 4.8]); hold(ax, 'on')
    k = t > tOn - zoomPre_s & t < tOn + zoomPost_s(1);
    plot(ax, t(k) - tOn, v(k), '.', 'Color', tc(3, :), 'MarkerSize', 6);
    tt = linspace(0, zoomPost_s(1), 200);
    plot(ax, tt + t(iOn + 1) - tOn, pD(1) + pD(2)*exp(-tt/pD(3)), '-', 'Color', fitColor, 'LineWidth', 1);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [-zoomPre_s zoomPost_s(1)]);
    xlabel(ax, 'Time from drop (s)'); ylabel(ax, 'Battery read (V)');
    title(ax, sprintf('step %.2f V, then τ = %.1f s to %.2f V', stepDrop, pD(3), pD(1)));
    panelLetter(ax, 'a', -0.25);
    % b: recovery
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0 + w + gap 1.2 w 4.8]); hold(ax, 'on')
    k = t > tOff - zoomPre_s & t < tOff + zoomPost_s(2);
    plot(ax, t(k) - tOff, v(k), '.', 'Color', tc(1, :), 'MarkerSize', 6);
    tt = linspace(0, zoomPost_s(2), 200);
    plot(ax, tt + t(iOff + 1) - tOff, pR(1) + pR(2)*exp(-tt/pR(3)), '-', 'Color', fitColor, 'LineWidth', 1);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [-zoomPre_s zoomPost_s(2)]);
    xlabel(ax, 'Time from recovery (s)'); ylabel(ax, 'Battery read (V)');
    title(ax, sprintf('step +%.2f V, then τ = %.1f s to %.2f V', stepRec, pR(3), pR(1)));
    panelLetter(ax, 'b', -0.25);
    % c: power against bank voltage (zener model at this position's I_rx)
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0 + 2*(w + gap) 1.2 w 4.8]); hold(ax, 'on')
    vTop = max([vIdle0, vIdlePred]) + 0.15;
    V = linspace(2, vTop, 400);
    Izv = min(zenerI(V, zp(1), zp(2), zp(3)), Irx);
    plot(ax, V, V*Irx, ':', 'Color', ink, 'LineWidth', 1);                  % total from the Rx
    plot(ax, V, V.*(Irx - Izv), '-', 'Color', fitColor, 'LineWidth', 1);     % useful (load + bank)
    plot(ax, V, V.*Izv, '--', 'Color', ink, 'LineWidth', 0.75);              % zener
    pts = [vIdle0, Mean_V(2), vPlat];
    ptP = [vIdle0*loadI.idle, Mean_V(2)*loadI.status, pPlat];               % mW; idle, status: test 1 load
    for i = 1:3
        plot(ax, pts(i), ptP(i), 'o', 'MarkerSize', 5, 'MarkerFaceColor', tc(i, :), ...
            'MarkerEdgeColor', ink, 'LineWidth', 0.5);
    end
    plot(ax, [vIdlePred vStatusPred], [vIdlePred*loadI.idle, vStatusPred*loadI.status], 's', ...
        'MarkerSize', 6, 'MarkerEdgeColor', ink, 'LineWidth', 0.5);          % model prediction
    xline(ax, vReg, ':', 'Color', ink); xline(ax, vBrownOut, ':', 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [2 vTop]); ylim(ax, [0 vTop*Irx*1.1]);
    xlabel(ax, 'Bank voltage (V)'); ylabel(ax, 'Power (mW)');
    title(ax, sprintf('I_rx %.1f mA; plateau %.1f mW', Irx, pPlat));
    panelLetter(ax, 'c', -0.25);
    saveFigure(f, fullfile(sesDir, [recName '_drop_recovery']));
    fprintf('Saved figures and tables in %s\n', sesDir);
end

%% Local functions
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

function p = expFit(tt, vv)
% Least-squares fit of V = Vinf + A*exp(-tt/tau); p = [Vinf A tau]
ok = ~isnan(vv); tt = tt(ok); vv = vv(ok);
model = @(p, x) p(1) + p(2)*exp(-x/max(p(3), 1e-3));
p0 = [vv(end), vv(1) - vv(end), max(tt)/3];
p = fminsearch(@(p) sum((vv - model(p, tt)).^2), p0, optimset('MaxFunEvals', 2e4, 'MaxIter', 2e4));
p(3) = max(p(3), 1e-3);
end

function I = test1Currents(test1Dir)
% Per-state load currents (mA) from the test 1 results, averaged over devices
d = dir(fullfile(test1Dir, '*', 'task_summary.csv'));
if isempty(d)
    error('No test 1 results in %s; run analyse_current_test (whichData = ''all'') first.', test1Dir);
end
idle = []; status = []; sham = []; led = [];
for k = 1:numel(d)
    T = readtable(fullfile(d(k).folder, d(k).name), 'TextType', 'string');
    get = @(name) T.Mean_mA(T.Task == name);
    idle(end+1) = get("Idle"); status(end+1) = get("Status LED"); sham(end+1) = get("Sham LED"); %#ok<AGROW>
    Lt = readtable(fullfile(d(k).folder, 'led_summary.csv'));
    led(:, end+1) = Lt.LedMean_mA; %#ok<AGROW>
end
I = struct('idle', mean(idle), 'status', mean(status), 'sham', mean(sham), 'led', mean(led, 2));
fprintf('Test 1 currents (mean of %d devices): idle %.2f, status %.2f, sham %.2f mA\n', ...
    numel(d), I.idle, I.status, I.sham);
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

function Iz = zenerI(V, Vk, Vs, Rz)
% Zener current (mA) at voltage V for V = Vk + Vs*ln(Iz/1 mA) + Rz*Iz
% (soft-knee model of analyse_power_curve.m; bisection on ln Iz, 0 below 1 nA)
if isnan(Vk), Iz = zeros(size(V)); return, end
lo = log(1e-6)*ones(size(V)); hi = log(100)*ones(size(V));
for it = 1:60
    mid = (lo + hi)/2;
    up = Vk + Vs*mid + Rz*exp(mid)/1000 > V;
    hi(up) = mid(up); lo(~up) = mid(~up);
end
Iz = exp((lo + hi)/2);
Iz(Vk + Vs*log(1e-6) + Rz*1e-9 > V) = 0;
end

function refLine(ax, xr, y, label, ink)
% Dotted horizontal reference line, labelled at its left end
plot(ax, xr, [y y], ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
text(ax, xr(1) + 0.01*diff(xr), y, label, 'HorizontalAlignment', 'left', 'VerticalAlignment', 'bottom', ...
    'FontSize', 7, 'Color', ink);
end

function panelLetter(ax, s, x)
% Bold panel letter above the top-left corner (x in normalized axes units)
if nargin < 3, x = -0.2; end
text(ax, x, 1.06, s, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', ...
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
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, ...
    'TitleFontSizeMultiplier', 9/8, 'TitleFontWeight', 'normal', 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', ...
    'XColor', ink, 'YColor', ink, 'Layer', 'top');
ax.XLabel.Interpreter = 'none'; ax.YLabel.Interpreter = 'none';
ax.Title.Interpreter = 'none'; ax.Title.FontSize = 7;
ax.Toolbar.Visible = 'off';
end

function saveFigure(f, base)
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
close(f);
end

function c = hexColors(hex)
c = zeros(numel(hex), 3);
for k = 1:numel(hex)
    c(k, :) = sscanf(hex{k}(2:end), '%2x%2x%2x')' / 255;
end
end
