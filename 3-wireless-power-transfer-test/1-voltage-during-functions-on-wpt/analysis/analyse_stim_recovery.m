% Analyse the 100 % stimulation pulse trains on WPT (tests 3.1d and 3.1e):
% how far the supply drops during a pulse and how fast the bank recharges
% in the ITI after it.
% Run from MATLAB (Run button, or `analyse_stim_recovery` from any folder).
% Input: <date_time>_stim-duration*.mat (3.1d, pulse durations vary, ITI
% fixed) and <date_time>_stim-iti*.mat (3.1e, 1 s pulses, ITI varies),
% written by ../og_wpt_stim_sweep_just_100percent_but_different_duration.m
% and _iti.m, holding wpt_opto_df (sample, t_s, bat_mv, state, amplitude,
% pulse) and config (stimDurs_s, itis_s, trigger_s). The newest recording of
% each sub-test (../device_<name>/<subTest>/) is used.
% Pulse end on the device: halfway between the last read below the split
% level (splitFrac of the way from the pre-pulse level down to the lowest read
% of the pulse, so it works however deep the sag is) and
% the first read above it after trigger + duration (the PC phase clock and
% the device differ by the trigger latency and the read round trip). Where
% the reads leave a gap longer than maxGap_s there (3.1d programs the next
% pulse at the start of the ITI, pausing the reads), the end is placed at
% trigger + duration + the median delay of the well-bracketed pulses.
% Recovery model: the deficit below the baseline (median of the idle before
% the first pulse) that pulse k leaves behind decays as
%   h_k(t) = A1_k*exp(-t/tau1) + A2_k*exp(-t/tau2),  t = time since its end
% (a fast part, the node recharging, and a slow part, the bank). Deficits of
% successive pulses add (linear superposition, small-signal approximation),
% so a short ITI starts the next pulse from a lower level. tau1 and tau2 are
% shared by all pulses of a recording; the amplitudes are linear in the
% model and solved by least squares for each (tau1, tau2) (variable
% projection), so only the two time constants are searched. Fitted: every
% read between the end of a pulse and the next trigger. 3.1e: one (A1, A2)
% for all pulses (identical pulses); 3.1d: one per pulse.
% Train prediction (3.1e): a long train of identical pulses at period
% T = duration + ITI settles where the pre-pulse deficit is
%   D_ss(ITI) = sum over n >= 0 of h(ITI + n*T)
% Figure (3.1e, _recovery.png): a) voltage over the test with the model in
%   the ITIs; b) deficit after each pulse against time since its end, with
%   the single-pulse model h(t); c) pre-pulse deficit of every pulse,
%   measured and modelled; d) model: pre-pulse deficit in a long train and
%   after a single pulse against ITI, with the measured end of each ITI block.
% Figure (3.1d, _recovery.png): a) voltage over the test; b) sag during each
%   pulse from its trigger; c) deficit after each pulse, with the fits;
%   d) fitted fast and slow amplitudes and the measured deficit 1 s after the
%   pulse against pulse duration.
% Output: results/device_<name>/<subTest>/<recording>_recovery.png and
% _pulses.csv (one row per pulse), _recovery_model.csv (time constants,
% amplitudes; 3.1e also the train prediction per ITI).
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 1-voltage-during-functions-on-wpt/
outDir  = fullfile(rootDir, 'results');
subTests = struct('name', {'1e-stim-iti-sweep', '1d-stim-duration-sweep'}, ...
                  'pattern', {'*_stim-iti*.mat', '*_stim-duration*.mat'});

baseline_s = 3;      % baseline: idle reads in the last baseline_s before the first pulse
preWin_s   = 0.5;    % pre-pulse level: reads in the last preWin_s before each trigger
endWin_s   = 0.25;   % pulse-end level: reads in the last endWin_s of the pulse
splitFrac  = 0.5;    % split level between the pre-pulse level (0) and the pulse minimum (1): below = pulse
maxGap_s   = 0.25;   % pulse end: longest read gap across it that still brackets it (s)
probe_s    = 1;      % measured deficit this long after the pulse end (3.1d panel d)
tau0       = [0.2 3];    % starting time constants (s)
itiGrid    = logspace(log10(0.25), log10(30), 200);   % ITIs for the train prediction (s)
itiReport  = [0.5 1 2 3 5 10 20];                     % ITIs listed in the model table (s)
nTrain     = 200;    % pulses summed for the steady-state train deficit

figWidth = 18;                       % cm
ink      = [0.15 0.15 0.15];
stimShade = [0.87 0.91 0.96];        % pulse shading
colLo    = [0.67 0.84 0.93];         % colour of the shortest ITI / duration
colHi    = [0.13 0.27 0.53];         % colour of the longest
modelColor = [0.80 0.40 0.47];

%% Analyse the newest recording of each sub-test
for s = 1:numel(subTests)
    d = dir(fullfile(testDir, 'device_*', subTests(s).name, subTests(s).pattern));
    if isempty(d), warning('No %s in %s', subTests(s).pattern, subTests(s).name); continue, end
    [~, o] = sort({d.name}); d = d(o(end));
    [~, dev] = fileparts(fileparts(d.folder));
    [~, recName] = fileparts(d.name);
    fprintf('=== %s/%s: %s ===\n', dev, subTests(s).name, recName);
    L = load(fullfile(d.folder, d.name), 'wpt_opto_df', 'config');
    df = L.wpt_opto_df; cfg = L.config;
    sesDir = fullfile(outDir, dev, subTests(s).name);
    if ~isfolder(sesDir), mkdir(sesDir); end
    isIti = startsWith(subTests(s).name, '1e');

    t = df.t_s; v = df.bat_mv/1000;
    ok = ~isnan(v); t = t(ok); v = v(ok);
    dur = cfg.stimDurs_s(:); tOn = cfg.trigger_s(:); n = numel(tOn);
    nextOn = [tOn(2:end); t(end) + 1];
    fprintf('%d reads over %.1f s (%.1f Hz); %d pulses at %d%%: %s s, ITIs %s s\n', numel(t), t(end), ...
        numel(t)/t(end), n, cfg.amplitude, mat2str(dur'), mat2str(cfg.itis_s));

    %% Per-pulse levels
    vBase = median(v(t > tOn(1) - baseline_s & t < tOn(1)));
    tEnd = nan(n, 1); gap = tEnd; Pre_V = tEnd; PulseMin_V = tEnd; PulseEnd_V = tEnd; FirstUp_V = tEnd;
    Probe_mV = tEnd; EndIti_V = tEnd; ItiAfter_s = tEnd;
    for k = 1:n
        Pre_V(k) = median(v(t > tOn(k) - preWin_s & t < tOn(k)));
        vMin = min(v(t > tOn(k) & t < min(tOn(k) + dur(k) + 0.5, nextOn(k))));
        vSplit = Pre_V(k) - splitFrac*(Pre_V(k) - vMin);
        iLow = find(t > tOn(k) & t < nextOn(k) & v < vSplit);
        iUp = find(t > tOn(k) + 0.5*dur(k) & t < nextOn(k) & v >= vSplit, 1);
        iLow = iLow(iLow < iUp);
        tEnd(k) = (t(iLow(end)) + t(iUp))/2;
        gap(k) = t(iUp) - t(iLow(end));
        PulseMin_V(k) = min(v(iLow));
        PulseEnd_V(k) = median(v(iLow(t(iLow) > t(iLow(end)) - endWin_s)));
        FirstUp_V(k) = v(iUp);
        m = t > tEnd(k) & t < nextOn(k);
        Probe_mV(k) = 1000*(vBase - interp1(t(m), v(m), tEnd(k) + probe_s, 'linear', NaN));
        EndIti_V(k) = median(v(m & t > nextOn(k) - preWin_s));
        if k < n, ItiAfter_s(k) = tOn(k + 1) - tEnd(k); else, ItiAfter_s(k) = t(end) - tEnd(k); end
    end
    EndIti_V(n) = median(v(t > t(end) - preWin_s));
    lag = tEnd - tOn - dur; wide = gap > maxGap_s;
    if any(wide)
        tEnd(wide) = tOn(wide) + dur(wide) + median(lag(~wide));
        fprintf('Pulse end from trigger + duration + %.0f ms for pulse(s) %s (read gap > %g s)\n', ...
            1000*median(lag(~wide)), mat2str(find(wide)'), maxGap_s);
        for k = find(wide)'
            m = t > tEnd(k) & t < nextOn(k);
            Probe_mV(k) = 1000*(vBase - interp1(t(m), v(m), tEnd(k) + probe_s, 'linear', NaN));
            if k < n, ItiAfter_s(k) = tOn(k + 1) - tEnd(k); else, ItiAfter_s(k) = t(end) - tEnd(k); end
        end
    end
    PreDeficit_mV = 1000*(vBase - Pre_V);
    fprintf('Baseline %.3f V; pulse end on the device %.0f-%.0f ms after trigger + duration\n', vBase, ...
        1000*min(lag(~wide)), 1000*max(lag(~wide)));

    %% Recovery model (variable projection over tau1, tau2)
    inIti = false(size(t));
    for k = 1:n, inIti = inIti | (t > tEnd(k) & t < nextOn(k)); end
    inIti = inIti & t > tEnd(1);
    tf = t(inIti); D = 1000*(vBase - v(inIti));             % mV
    if isIti, group = ones(n, 1); else, group = (1:n)'; end
    cost = @(q) recoveryLS(sort(exp(q)), tf, tEnd, D, group);
    q = fminsearch(cost, log(tau0), optimset('TolX', 1e-6, 'TolFun', 1e-9, 'MaxFunEvals', 2000));
    tau = sort(exp(q));
    [sse, A, X] = recoveryLS(tau, tf, tEnd, D, group);
    A = reshape(A, 2, [])';                                 % rows: groups; columns: fast, slow (mV)
    rmsRes = sqrt(sse/numel(D));
    fprintf('Recovery: tau1 = %.3f s (fast), tau2 = %.2f s (slow); rms residual %.1f mV over %d reads\n', ...
        tau(1), tau(2), rmsRes, numel(D));
    Dmodel = X*reshape(A', [], 1);
    h = @(tt, a) a(1)*exp(-tt/tau(1)) + a(2)*exp(-tt/tau(2));   % deficit after one pulse (mV)
    % model deficit at any time: sum over the pulses that have ended
    Dat = @(tt) sum(cell2mat(arrayfun(@(k) (tt > tEnd(k)).*h(max(tt - tEnd(k), 0), A(group(k), :)), ...
        (1:n), 'UniformOutput', false)), 2);
    ModelPre_mV = Dat(tOn);

    Pulse = (1:n)'; Dur_s = dur;
    pulseTbl = table(Pulse, Dur_s, ItiAfter_s, Pre_V, PreDeficit_mV, ModelPre_mV, PulseMin_V, PulseEnd_V, ...
        FirstUp_V, Probe_mV, EndIti_V);
    if ~isIti
        pulseTbl.A1_fast_mV = A(:, 1); pulseTbl.A2_slow_mV = A(:, 2);
    end
    writetable(pulseTbl, fullfile(sesDir, [recName '_pulses.csv']));
    disp(pulseTbl)

    if isIti
        %% Train prediction: pre-pulse deficit at steady state, and after a single pulse
        T = dur(1) + itiGrid;
        Dss = sum(h(itiGrid(:) + (0:nTrain - 1).*T(:), A(1, :)), 2)';
        Dsingle = h(itiGrid, A(1, :));
        tTo = @(lvl) fzero(@(tt) h(tt, A(1, :)) - lvl, [0 200]);
        fprintf('Single 1 s pulse: deficit %.0f mV just after (model), %.0f mV slow part; within 20 mV after %.1f s, 10 mV after %.1f s, 5 mV after %.1f s\n', ...
            sum(A(1, :)), A(1, 2), tTo(20), tTo(10), tTo(5));
        ITI_s = itiReport(:);
        TrainPre_mV = interp1(itiGrid, Dss, ITI_s); SinglePulse_mV = h(ITI_s, A(1, :));
        DutyCycle_pct = 100*dur(1)./(dur(1) + ITI_s);
        modelTbl = table(ITI_s, DutyCycle_pct, SinglePulse_mV, TrainPre_mV);
        disp(modelTbl)
        % measured: pre-pulse deficit at the end of each block of equal ITIs
        itiNom = round(cfg.itis_s(:));
        blk = [find([true; diff(itiNom) ~= 0]); numel(itiNom) + 1];
        BlockIti_s = itiNom(blk(1:end-1)); BlockN = diff(blk);
        BlockEndPre_mV = PreDeficit_mV(blk(2:end));          % pulse after the last ITI of the block
        BlockModelSS_mV = interp1(itiGrid, Dss, BlockIti_s);
        blkTbl = table(BlockIti_s, BlockN, BlockEndPre_mV, BlockModelSS_mV);
        disp(blkTbl)
        mt = table(tau(1), tau(2), A(1, 1), A(1, 2), rmsRes, 'VariableNames', ...
            {'Tau1_s', 'Tau2_s', 'A1_fast_mV', 'A2_slow_mV', 'RmsResidual_mV'});
        writetable([repmat(mt, numel(ITI_s), 1) modelTbl], fullfile(sesDir, [recName '_recovery_model.csv']));
    else
        mt = table(Pulse, Dur_s, repmat(tau(1), n, 1), repmat(tau(2), n, 1), A(:, 1), A(:, 2), ...
            repmat(rmsRes, n, 1), 'VariableNames', {'Pulse', 'Dur_s', 'Tau1_s', 'Tau2_s', 'A1_fast_mV', ...
            'A2_slow_mV', 'RmsResidual_mV'});
        writetable(mt, fullfile(sesDir, [recName '_recovery_model.csv']));
    end

    %% Figure
    if isIti, key = [round(cfg.itis_s(:)); round(ItiAfter_s(end))]; keyName = 'ITI'; else, key = dur; keyName = 'Pulse'; end
    kLo = min(key(1:end - isIti)); kHi = max(key(1:end - isIti));
    colOf = @(x) colLo + (min(x, kHi) - kLo)/max(eps, kHi - kLo)*(colHi - colLo);
    f = newFigure(figWidth, 15);
    w = (figWidth - 3.4)/2;
    % a: overview
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 10.3 figWidth - 2.0 4.0]); hold(ax, 'on')
    yl = [floor(min(v)*5)/5 - 0.1, ceil(max(v)*10)/10 + 0.05];
    for k = 1:n
        patch(ax, [tOn(k) tEnd(k) tEnd(k) tOn(k)], yl([1 1 2 2]), stimShade, 'EdgeColor', 'none');
    end
    plot(ax, t, v, '.', 'Color', [0.45 0.45 0.45], 'MarkerSize', 4);
    for k = 1:n
        tt = linspace(tEnd(k), nextOn(k) - 1e-3, 200)';
        if k == n, tt = linspace(tEnd(k), t(end), 200)'; end
        plot(ax, tt, vBase - Dat(tt)/1000, '-', 'Color', modelColor, 'LineWidth', 1);
    end
    yline(ax, vBase, ':', 'Color', ink);
    if isIti
        itiNom = round(cfg.itis_s(:)); blk = [find([true; diff(itiNom) ~= 0]); numel(itiNom) + 1];
        for b = 1:numel(blk) - 1
            xm = (tOn(blk(b)) + tOn(blk(b + 1)))/2;
            text(ax, xm, yl(2), sprintf('ITI %d s', itiNom(blk(b))), 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink, 'Clipping', 'off');
        end
    else
        for k = 1:n
            text(ax, tOn(k), yl(2), sprintf('%g s', dur(k)), 'HorizontalAlignment', 'left', ...
                'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink, 'Clipping', 'off');
        end
    end
    hold(ax, 'off'); styleAxes(ax); ax.Layer = 'top';
    xlim(ax, [0 t(end)]); ylim(ax, yl);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Supply voltage (V)');
    text(ax, 0.995, 0.06, sprintf('shaded: pulse (%d%%, LED %d); red: recovery model', cfg.amplitude, cfg.stimLed), ...
        'Units', 'normalized', 'HorizontalAlignment', 'right', 'FontSize', 6.5, 'Color', ink);
    panelLetter(ax, 'a', -0.095);
    pos = {[1.5 5.5 w 3.6], [1.5 + w + 1.6 5.5 w 3.6], [1.5 1.1 w 3.4], [1.5 + w + 1.6 1.1 w 3.4]};
    tMax = max(ItiAfter_s(1:end - isIti)) + 0.5;
    % recovery traces (deficit, log scale)
    if isIti, axR = axes(f, 'Units', 'centimeters', 'Position', pos{1});
    else, axR = axes(f, 'Units', 'centimeters', 'Position', pos{2}); end
    hold(axR, 'on')
    for k = n:-1:1
        % this pulse's own deficit: the modelled share of earlier pulses removed
        m = find(t > tEnd(k) & t < nextOn(k));
        earlier = zeros(numel(m), 1);
        for j = 1:k - 1, earlier = earlier + h(t(m) - tEnd(j), A(group(j), :)); end
        plot(axR, t(m) - tEnd(k), max(1000*(vBase - v(m)) - earlier, 2), '.-', 'Color', colOf(key(k)), ...
            'MarkerSize', 5, 'LineWidth', 0.4);
    end
    tt = linspace(0, tMax, 300);
    if isIti
        plot(axR, tt, h(tt, A(1, :)), '--', 'Color', modelColor, 'LineWidth', 1.25);
        text(axR, 0.98, 0.95, sprintf('dashed: one pulse alone\nτ1 = %.2f s, τ2 = %.1f s', tau(1), tau(2)), ...
            'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 6.5, 'Color', ink);
    else
        for k = 1:n, plot(axR, tt, h(tt, A(k, :)), '-', 'Color', colOf(key(k)), 'LineWidth', 1); end
        text(axR, 0.98, 0.95, sprintf('lines: fits, τ1 = %.2f s, τ2 = %.1f s', tau(1), tau(2)), ...
            'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 6.5, 'Color', ink);
    end
    hold(axR, 'off'); styleAxes(axR); axR.YScale = 'log';
    xlim(axR, [0 tMax]); ylim(axR, [2 2000]);
    xlabel(axR, 'Time since the pulse ended (s)'); ylabel(axR, 'Deficit from this pulse (mV)');
    text(axR, 0.98, 0.02, 'earlier pulses'' modelled share removed; values ≤ 2 mV drawn at 2 mV', 'Units', 'normalized', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 6, 'Color', [0.5 0.5 0.5]);
    colourKey(axR, key(1:end - isIti), colOf, keyName, ink);
    if isIti
        panelLetter(axR, 'b', -0.17);
        % c: pre-pulse deficit, measured and modelled
        ax = axes(f, 'Units', 'centimeters', 'Position', pos{2}); hold(ax, 'on')
        plot(ax, Pulse, ModelPre_mV, '-', 'Color', modelColor, 'LineWidth', 1);
        prevIti = [NaN; key(1:end - 1)];
        for k = 1:n
            c = [0.6 0.6 0.6]; if k > 1, c = colOf(prevIti(k)); end
            plot(ax, k, PreDeficit_mV(k), 'o', 'MarkerFaceColor', c, 'MarkerEdgeColor', 'none', 'MarkerSize', 4.5);
        end
        hold(ax, 'off'); styleAxes(ax);
        xlim(ax, [0.5 n + 0.5]); ylim(ax, [min(0, min(PreDeficit_mV)) - 5, max(PreDeficit_mV) + 15]);
        xlabel(ax, 'Pulse'); ylabel(ax, 'Deficit before the pulse (mV)');
        text(ax, 0.98, 0.95, 'dots: measured (colour: preceding ITI); line: model', 'Units', 'normalized', ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 6.5, 'Color', ink);
        panelLetter(ax, 'c', -0.17);
        % d: train prediction against ITI
        ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.1 figWidth - 2.0 3.4]); hold(ax, 'on')
        h1 = plot(ax, itiGrid, Dss, '-', 'Color', modelColor, 'LineWidth', 1.5);
        h2 = plot(ax, itiGrid, Dsingle, '--', 'Color', modelColor, 'LineWidth', 1);
        h3 = plot(ax, BlockIti_s, BlockEndPre_mV, 'o', 'MarkerFaceColor', ink, 'MarkerEdgeColor', 'none', 'MarkerSize', 5);
        for b = 1:numel(BlockIti_s)
            text(ax, BlockIti_s(b), BlockEndPre_mV(b), sprintf('  %d × %d s', BlockN(b), BlockIti_s(b)), ...
                'FontSize', 6.5, 'Color', ink, 'VerticalAlignment', 'bottom');
        end
        hold(ax, 'off'); styleAxes(ax); ax.XScale = 'log';
        xlim(ax, itiGrid([1 end])); ylim(ax, [0 max(Dss)*1.1]);
        ax.XTick = [0.25 0.5 1 2 3 5 10 20 30];
        xlabel(ax, sprintf('ITI (s), %g s pulses at %d%%', dur(1), cfg.amplitude)); ylabel(ax, 'Deficit before a pulse (mV)');
        legend(ax, [h1 h2 h3], {'model: long train, steady state', 'model: single pulse, deficit left after the ITI', ...
            'measured: end of each ITI block'}, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6.5);
        panelLetter(ax, 'd', -0.095);
    else
        panelLetter(axR, 'c', -0.17);
        % b: sag during each pulse
        ax = axes(f, 'Units', 'centimeters', 'Position', pos{1}); hold(ax, 'on')
        for k = 1:n
            m = t >= tOn(k) - 0.3 & t <= tEnd(k) + 0.3;
            plot(ax, t(m) - tOn(k), v(m), '.-', 'Color', colOf(key(k)), 'MarkerSize', 5, 'LineWidth', 0.5);
        end
        hold(ax, 'off'); styleAxes(ax);
        xlim(ax, [-0.3 max(dur) + 0.5]); ylim(ax, [2.9 4.8]);
        xlabel(ax, 'Time since the trigger (s)'); ylabel(ax, 'Supply voltage (V)');
        colourKey(ax, key, colOf, keyName, ink);
        panelLetter(ax, 'b', -0.17);
        % d: amplitudes against duration
        ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.1 figWidth - 2.0 3.4]); hold(ax, 'on')
        h1 = plot(ax, dur, A(:, 1), 'o-', 'Color', colLo, 'MarkerFaceColor', colLo, 'MarkerSize', 4.5, 'LineWidth', 1);
        h2 = plot(ax, dur, A(:, 2), 'o-', 'Color', colHi, 'MarkerFaceColor', colHi, 'MarkerSize', 4.5, 'LineWidth', 1);
        h3 = plot(ax, dur, Probe_mV, 's', 'MarkerFaceColor', ink, 'MarkerEdgeColor', 'none', 'MarkerSize', 4.5);
        hold(ax, 'off'); styleAxes(ax);
        xlim(ax, [0 max(dur) + 0.25]); ylim(ax, [0 max([A(:); Probe_mV])*1.15]);
        xlabel(ax, 'Pulse duration (s)'); ylabel(ax, 'Deficit (mV)');
        legend(ax, [h1 h2 h3], {sprintf('fast part A1 (τ1 = %.2f s)', tau(1)), sprintf('slow part A2 (τ2 = %.1f s)', tau(2)), ...
            sprintf('measured %g s after the pulse', probe_s)}, 'Location', 'northwest', 'Box', 'off', 'FontSize', 6.5);
        panelLetter(ax, 'd', -0.095);
    end
    saveFigure(f, fullfile(sesDir, [recName '_recovery']));
    fprintf('Results saved to %s\n', sesDir);
end

%% Local functions
function [sse, A, X] = recoveryLS(tau, tf, tEnd, D, group)
% Least-squares amplitudes of the superposed two-exponential recovery for
% the time constants tau; columns 2g-1, 2g: fast and slow part of group g
X = zeros(numel(tf), 2*max(group));
for k = 1:numel(tEnd)
    dt = tf - tEnd(k); m = dt > 0; g = group(k);
    X(m, 2*g - 1) = X(m, 2*g - 1) + exp(-dt(m)/tau(1));
    X(m, 2*g)     = X(m, 2*g)     + exp(-dt(m)/tau(2));
end
A = X\D;
sse = sum((D - X*A).^2);
end

function colourKey(ax, key, colOf, name, ~)
% Colour legend in one row just above the axes: one swatch per distinct value
u = unique(key);
text(ax, 0, 1.02, [name ':'], 'Units', 'normalized', 'FontSize', 6.5, 'Color', [0.15 0.15 0.15], ...
    'VerticalAlignment', 'bottom');
for i = 1:numel(u)
    text(ax, 0.17 + 0.14*(i - 1)*6/max(6, numel(u)), 1.02, sprintf('■ %g s', u(i)), 'Units', 'normalized', ...
        'Color', colOf(u(i)), 'FontSize', 6.5, 'VerticalAlignment', 'bottom');
end
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
    'XColor', ink, 'YColor', ink, 'Layer', 'bottom');
ax.XLabel.Interpreter = 'none'; ax.YLabel.Interpreter = 'none';
ax.Toolbar.Visible = 'off';
end

function saveFigure(f, base)
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
close(f);
end
