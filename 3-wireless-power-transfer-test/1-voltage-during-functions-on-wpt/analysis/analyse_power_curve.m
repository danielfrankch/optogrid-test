% Analyse the OptoGrid WPT power-curve test (test 3.1h: load ladder at equilibrium)
% Run from MATLAB (Run button, or `analyse_power_curve` from any folder).
% Input: <date_time>_power-curve*.mat written by ../og_wpt_power_curve.m,
% holding wpt_power_df (sample, t_s, bat_mv, state, amplitude, load_mA) and
% config. By default the newest .mat in ../device_<name>/1h-power-curve/ is used.
% Sequence: idle, status LED, status LED + one LED at each amplitude (sham LED
% also on during stimulation; about 1 s with the LED off between amplitudes,
% "status+program"), idle.
% load_mA is the nominal load with VCC in regulation (currents in config).
% The device ends each pulse slightly before the PC step boundary, so reads
% after a jump of more than offJump_V in the last offWin_s of a stimulation
% step are dropped (LED already off).
% Per step: settled voltage V = mean over the last settleWin_s, slope dV/dt
% from a line over the last slopeWin_s. The bank (Cbank) supplies -C dV/dt,
% so the current the Rx delivers to the load and the bank is
% I_use = I_load + C dV/dt, and P_use = V*I_use. This holds while V >= vReg
% (load = nominal); below it the load is unknown and the step only gives its
% voltage. A step is settled when |dV/dt| < settledSlope.
% Trajectory: within a stimulation step that is still draining at its end
% (end slope below -settledSlope), from trajStart_s on, I_use(t) = I_load +
% C dV/dt from a running line over trajWin_s, for reads with V >= vReg. It
% extends the curve past the last settled step (where the Rx cannot keep up
% and the bank drains). Earlier in a step the node recovers through the
% bank's series resistance, and C dV/dt of the node is not the bank current.
% Model (circuit: Rx tank -> full-bridge rectifier -> Schottky -> V_BANK, with
% a 5.6 V zener, GDZ5V6, from V_BANK to ground): the tank and rectifier act as
% a current source I_rx, and the zener takes what the load and bank do not,
%   I_z = I_rx - I_use,   V = Vk + Vs*ln(I_z/1 mA) + Rz*I_z
% (soft knee: exponential below the knee, series resistance Rz above; Vk is
% the knee voltage at 1 mA without the Rz drop). I_rx, Vk, Vs and Rz are
% fitted to the settled steps and the trajectory, by the current residual
% I_rx - I_use - I_z(V); the trajectory as a whole weighs as trajWeight
% steps. As the load approaches I_rx the zener current, and with it the
% voltage, collapses: the useful power V*I_use peaks just below I_rx.
% Voltages are battery reads (no calibration), so Vk is in read volts.
% Figure 1: battery voltage over the session, with the step loads.
% Figure 2: a) V against I_use, b) power against I_use: useful (load + bank),
%           zener and total from the Rx.
% Output: figures and tables in results/device_<name>/1h-power-curve/, named
% after the recording: _overview.png, _power_curve.png, _steps.csv,
% _trajectory.csv, _summary.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 1-voltage-during-functions-on-wpt/
outDir  = fullfile(rootDir, 'results');
whichData  = 'newest';   % 'newest' (newest .mat overall), 'all' (newest per device) or 'every'
subTest    = '1h-power-curve';   % recordings in ../device_<name>/<subTest>/
recPattern = '*_power-curve*.mat';

% Figure style (as analyse_drain_by_sham_status.m, Paul Tol 'muted' palette)
figWidth = 18;                       % cm
ink      = [0.15 0.15 0.15];
cIdle    = [51 34 136]/255; cStatus = [221 204 119]/255; cStim = [17 119 51]/255;
cTraj    = [136 204 238]/255; cFit = [204 102 119]/255;
smoothWin_s = 0.5;                   % Figure 1 running mean (s)

% Power chain (as analyse_drain_by_sham_status.m)
Cbank_F   = 16.5e-3;   % supercapacitor bank: 11 mF cells, 3 in parallel, 2 groups in series
vReg      = 3.4;       % lowest bank voltage with VCC in regulation (V): 3.3 V LDO + 0.1 V dropout (CHECK)
vBrownOut = 2.5;       % brown-out voltage (V)

% Step analysis (s, V)
offWin_s     = 0.5;    % look for the pulse-off jump in the last offWin_s of a stimulation step
offJump_V    = 0.15;   % read-to-read rise that marks the LED off
settleWin_s  = 2;      % settled voltage: mean over the last settleWin_s
slopeWin_s   = 3;      % end slope: line over the last slopeWin_s
settledSlope = 0.015;  % V/s; steps flatter than this count as settled
trajStart_s  = 2;      % trajectory: skip the fast part at the start of each stimulation step
trajWin_s    = 1;      % trajectory: running line over this window
trajWeight   = 3;      % model fit: the whole trajectory counts as this many settled steps

%% Find recordings
recs = findRecordings(testDir, subTest, recPattern, whichData);
if isempty(recs), error('No %s found in %s', recPattern, fullfile(testDir, 'device_*', subTest)); end

for s = 1:numel(recs)
    [~, recName] = fileparts(recs(s).file);
    fprintf('=== %s: %s ===\n', recs(s).folder, recName);
    L = load(recs(s).file, 'wpt_power_df', 'config');
    df = L.wpt_power_df; cfg = L.config;
    sesDir = fullfile(outDir, recs(s).folder);
    if ~isfolder(sesDir), mkdir(sesDir); end
    t = df.t_s; v = df.bat_mv/1000; st = df.state;
    dtMed = median(diff(t));
    fprintf('%d reads over %.1f s: %.1f Hz (fs = %g Hz), %d failed (%s)\n', ...
        height(df), t(end), height(df)/t(end), cfg.fs, sum(isnan(v)), cfg.stopReason);

    %% Steps: runs of one state with a nominal load
    runStart = find([true; st(2:end) ~= st(1:end-1)]);
    runEnd   = [runStart(2:end) - 1; height(df)];
    keep = true(height(df), 1);
    rows = struct('State', {}, 'Amplitude', {}, 'Start_s', {}, 'End_s', {}, 'Load_mA', {}, ...
        'V_settled', {}, 'Slope_mV_s', {}, 'Settled', {}, 'InRegulation', {}, 'Iuse_mA', {}, 'Puse_mW', {});
    trajI = []; trajV = []; trajT = [];
    for r = 1:numel(runStart)
        k = (runStart(r):runEnd(r))';
        I0 = df.load_mA(k(1));
        if isnan(I0) || t(k(end)) - t(k(1)) < settleWin_s + 0.5, continue, end   % programming gaps, short tails
        isStim = df.amplitude(k(1)) > 0;
        if isStim
            % drop reads after the LED went off
            kl = find(t(k) > t(k(end)) - offWin_s);
            j = kl(find(diff(v(k(kl))) > offJump_V, 1));
            if ~isempty(j), keep(k(j+1:end)) = false; k = k(1:j); end
        end
        ks = k(t(k) > t(k(end)) - settleWin_s);
        kp = k(t(k) > t(k(end)) - slopeWin_s);
        p = polyfit(t(kp), v(kp), 1);
        V = mean(v(ks), 'omitnan');
        inReg = V >= vReg;
        Iuse = I0 + 1000*Cbank_F*p(1);           % mA
        if ~inReg, Iuse = NaN; end
        rows(end+1) = struct('State', st(k(1)), 'Amplitude', df.amplitude(k(1)), 'Start_s', t(k(1)), ...
            'End_s', t(k(end)), 'Load_mA', I0, 'V_settled', V, 'Slope_mV_s', 1000*p(1), ...
            'Settled', abs(p(1)) < settledSlope, 'InRegulation', inReg, 'Iuse_mA', Iuse, ...
            'Puse_mW', V*Iuse); %#ok<SAGROW>
        if isStim && p(1) < -settledSlope
            % trajectory: running slope after the fast step
            kt = k(t(k) > t(k(1)) + trajStart_s);
            for i = 1:numel(kt)
                kw = k(abs(t(k) - t(kt(i))) <= trajWin_s/2);
                if numel(kw) < 4 || v(kt(i)) < vReg, continue, end
                pw = polyfit(t(kw), v(kw), 1);
                trajI(end+1, 1) = I0 + 1000*Cbank_F*pw(1); %#ok<SAGROW>
                trajV(end+1, 1) = mean(v(kw)); trajT(end+1, 1) = t(kt(i)); %#ok<SAGROW>
            end
        end
    end
    stepTbl = struct2table(rows);
    writetable(stepTbl, fullfile(sesDir, [recName '_steps.csv']));
    trajTbl = table(trajT, trajV, trajI, trajV.*trajI, 'VariableNames', {'t_s', 'V', 'Iuse_mA', 'Puse_mW'});
    writetable(trajTbl, fullfile(sesDir, [recName '_trajectory.csv']));
    disp(stepTbl(:, {'State', 'Load_mA', 'V_settled', 'Slope_mV_s', 'Settled', 'InRegulation', 'Iuse_mA', 'Puse_mW'}));

    %% Model: Rx current source + zener soft knee
    good = stepTbl.Settled & stepTbl.InRegulation;
    fitV = [stepTbl.V_settled(good); trajV];
    fitI = [stepTbl.Iuse_mA(good); trajI];
    w = [ones(nnz(good), 1); repmat(sqrt(trajWeight/max(1, numel(trajV))), numel(trajV), 1)];
    resid = @(q) w.*(q(1) - fitI - zenerI(fitV, q(2), exp(q(3)), exp(q(4))));
    q0 = [max(fitI) + 0.3, 4.45, log(0.05), log(20)];
    q = fminsearch(@(q) sum(resid(q).^2), q0, optimset('MaxFunEvals', 2e4, 'MaxIter', 2e4, 'TolX', 1e-8, 'TolFun', 1e-12));
    Irx = q(1); Vk = q(2); Vs = exp(q(3)); Rz = exp(q(4));
    zV = @(Iz) Vk + Vs*log(Iz) + Rz*Iz/1000;                  % V at zener current Iz (mA)
    stepIz = Irx - stepTbl.Iuse_mA;
    rmsStep = rms(stepIz(good) - zenerI(stepTbl.V_settled(good), Vk, Vs, Rz));
    rmsTraj = rms(Irx - trajI - zenerI(trajV, Vk, Vs, Rz));
    % useful power along the model, and its peak
    Iu = [linspace(0, Irx - 1e-2, 3000), Irx - logspace(-2.01, -9, 300)];   % dense near I_rx, where V collapses
    Pu = Iu.*zV(Irx - Iu);
    [PpkM, ipm] = max(Pu);
    % measured
    allP = [stepTbl.Puse_mW(good); trajV.*trajI];
    allI = [stepTbl.Iuse_mA(good); trajI];
    allV = [stepTbl.V_settled(good); trajV];
    [Ppk, ipk] = max(allP);
    iIdle = find(good & stepTbl.Amplitude == 0 & ~startsWith(stepTbl.State, "status"), 1);
    vIdle = stepTbl.V_settled(iIdle); izIdle = Irx - stepTbl.Iuse_mA(iIdle);
    fprintf(['Model: I_rx %.2f mA; zener Vk %.3f V at 1 mA, Vs %.1f mV, Rz %.1f ohm; rms %.2f mA (steps), ' ...
        '%.2f mA (trajectory)\n'], Irx, Vk, 1000*Vs, Rz, rmsStep, rmsTraj);
    fprintf(['Useful power: model peak %.1f mW at %.2f mA, %.2f V; measured peak %.1f mW at %.2f mA, %.2f V. ' ...
        'Idle: zener %.2f mA, %.1f mW of %.1f mW from the Rx\n'], PpkM, Iu(ipm), zV(Irx - Iu(ipm)), Ppk, ...
        allI(ipk), allV(ipk), izIdle, vIdle*izIdle, vIdle*Irx);
    lowSteps = stepTbl(~stepTbl.InRegulation, :);
    sumRows = {
        'current_limit_mA', Irx, 'I_rx: Rx current (current source), model fit'
        'zener_vk_V', Vk, 'zener knee voltage at 1 mA, without the Rz drop (battery-read volts)'
        'zener_vs_V', Vs, 'zener knee slope: V per e-fold of current'
        'zener_rz_ohm', Rz, 'zener series resistance'
        'fit_rms_steps_mA', rmsStep, sprintf('%d settled steps in regulation', nnz(good))
        'fit_rms_trajectory_mA', rmsTraj, sprintf('%d trajectory points (C = %g mF)', numel(trajV), 1000*Cbank_F)
        'model_peak_power_mW', PpkM, 'useful power (load + bank), model'
        'model_peak_power_I_mA', Iu(ipm), ''
        'model_peak_power_V', zV(Irx - Iu(ipm)), ''
        'peak_power_mW', Ppk, 'largest measured useful power (settled step or trajectory)'
        'peak_power_I_mA', allI(ipk), ''
        'peak_power_V', allV(ipk), ''
        'idle_zener_mA', izIdle, 'zener current at idle'
        'idle_zener_power_mW', vIdle*izIdle, sprintf('of %.1f mW from the Rx at idle', vIdle*Irx)
        'steps_below_regulation', height(lowSteps), strjoin(lowSteps.State, ', ')
        'lowest_step_V', min(stepTbl.V_settled), sprintf('brown-out %g V', vBrownOut)
        };
    writetable(cell2table(sumRows, 'VariableNames', {'quantity', 'value', 'note'}), ...
        fullfile(sesDir, [recName '_summary.csv']));

    %% Figure 1: overview
    f = newFigure(figWidth, 8);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.2 15.8 5.6]); hold(ax, 'on')
    for r = 1:height(stepTbl)
        if stepTbl.Amplitude(r) > 0, c = cStim; elseif startsWith(stepTbl.State(r), "status"), c = cStatus; else, c = cIdle; end
        patch(ax, [stepTbl.Start_s(r) stepTbl.End_s(r) stepTbl.End_s(r) stepTbl.Start_s(r)], [0 0 6 6], ...
            1 - 0.22*(1 - c), 'EdgeColor', 'none');
        lab = sprintf('%.1f mA', stepTbl.Load_mA(r));
        if stepTbl.Amplitude(r) > 0, lab = sprintf('%d%%\n%s', stepTbl.Amplitude(r), lab); end
        text(ax, (stepTbl.Start_s(r) + stepTbl.End_s(r))/2, 2.05, lab, 'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'bottom', 'FontSize', 6, 'Color', ink);
    end
    plot(ax, t(keep), v(keep), '.', 'Color', [0.6 0.6 0.6], 'MarkerSize', 4);
    plot(ax, t(~keep), v(~keep), 'x', 'Color', [0.6 0.6 0.6], 'MarkerSize', 3);
    plot(ax, t, movmean(v, max(1, round(smoothWin_s/dtMed))), '-', 'Color', ink, 'LineWidth', 0.8);
    refLine(ax, [0 t(end)], vReg, sprintf('VCC regulation %.1f V', vReg), ink);
    refLine(ax, [0 t(end)], vBrownOut, sprintf('brown-out %.1f V', vBrownOut), ink);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [0 t(end)]); ylim(ax, [2 5]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Battery read (V)');
    title(ax, 'Shading: idle, status LED, status LED + LED 1 (amplitude and nominal load below)');
    saveFigure(f, fullfile(sesDir, [recName '_overview']));

    %% Figure 2: V-I and power against the useful current
    f = newFigure(figWidth, 7.5);
    Iz = Irx - Iu; okC = zV(Iz) >= 3.2;                       % model curve down to 3.2 V
    xMax = Irx*1.12;
    % a: bank voltage
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.2 7.2 5.4]); hold(ax, 'on')
    hT = plot(ax, trajI, trajV, '.', 'Color', cTraj, 'MarkerSize', 5);
    hM = plot(ax, Iu(okC), zV(Iz(okC)), '-', 'Color', cFit, 'LineWidth', 1);
    hS = plot(ax, stepTbl.Iuse_mA(good), stepTbl.V_settled(good), 'o', 'MarkerSize', 5, ...
        'MarkerFaceColor', cStim, 'MarkerEdgeColor', ink, 'LineWidth', 0.5);
    xline(ax, Irx, ':', 'Color', ink); yline(ax, vReg, ':', 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [0 xMax]); ylim(ax, [3.2 max(fitV) + 0.15]);
    xlabel(ax, 'Load + bank current I_use (mA)'); ylabel(ax, 'Bank voltage (V)');
    legend(ax, [hS hT hM], {'settled step', 'bank draining (I_load + C dV/dt)', ...
        sprintf('model: zener takes %.2f mA - I_use', Irx)}, 'Location', 'southwest', 'Box', 'off', ...
        'FontSize', 7, 'Interpreter', 'none');
    title(ax, sprintf('I_rx %.2f mA; zener %.2f V at 1 mA, %.0f mV/e-fold, %.0f Ω', Irx, Vk, 1000*Vs, Rz));
    panelLetter(ax, 'a', -0.18);
    % b: power
    ax = axes(f, 'Units', 'centimeters', 'Position', [10.5 1.2 7.2 5.4]); hold(ax, 'on')
    hU = plot(ax, Iu(okC), Pu(okC), '-', 'Color', cFit, 'LineWidth', 1);
    hZ = plot(ax, Iu(okC), zV(Iz(okC)).*Iz(okC), '--', 'Color', ink, 'LineWidth', 0.75);
    hR = plot(ax, Iu(okC), zV(Iz(okC))*Irx, ':', 'Color', ink, 'LineWidth', 1);
    plot(ax, trajI, trajV.*trajI, '.', 'Color', cTraj, 'MarkerSize', 5);
    plot(ax, stepTbl.Iuse_mA(good), stepTbl.Puse_mW(good), 'o', 'MarkerSize', 5, ...
        'MarkerFaceColor', cStim, 'MarkerEdgeColor', ink, 'LineWidth', 0.5);
    plot(ax, allI(ipk), Ppk, 'p', 'MarkerSize', 9, 'MarkerFaceColor', cFit, 'MarkerEdgeColor', ink);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [0 xMax]); ylim(ax, [0 max(zV(Iz(okC))*Irx)*1.35]);
    xlabel(ax, 'Load + bank current I_use (mA)'); ylabel(ax, 'Power (mW)');
    legend(ax, [hU hZ hR], {'useful (load + bank)', 'zener', 'total from the Rx'}, 'Location', 'north', ...
        'Orientation', 'horizontal', 'Box', 'off', 'FontSize', 7);
    title(ax, sprintf('peak %.1f mW measured at %.2f mA (model %.1f mW)', Ppk, allI(ipk), PpkM));
    panelLetter(ax, 'b', -0.18);
    saveFigure(f, fullfile(sesDir, [recName '_power_curve']));
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

function Iz = zenerI(V, Vk, Vs, Rz)
% Zener current (mA) at voltage V for V = Vk + Vs*ln(Iz/1 mA) + Rz*Iz
% (bisection on ln Iz, vectorised; 0 below 1 nA)
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
