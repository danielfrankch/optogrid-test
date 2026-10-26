% Analyse the OptoGrid WPT stimulation amplitude sweep (test 3.1c)
% Run from MATLAB (Run button, or `analyse_stim_sweep` from any folder).
% Input: <date_time>_stim-sweep*.mat written by ../og_wpt_stim_sweep.m, holding
% wpt_opto_df (sample, t_s, bat_mv, state, amplitude) and config. By default
% the newest .mat in the recording folders (../device_<name>/1c-stim-amplitude-sweep/) is used.
% Sequence: idle, then one continuous 5 s pulse on one LED at each
% amplitude (ITI between them), then idle. Every read carries its own PC
% time stamp (t_s). Epoch edges are placed halfway between the last read of
% one state and the first read of the next.
% Same power model as analyse_load_states.m (see there): the Rx chain is a DC
% source V = Voc - Rs*I feeding the supercapacitor bank and the 3.3 V LDO.
% This recording has no status or sham states to fit Rs, so Rs is taken from
% the full fits of the earlier recordings (RsFixed_ohm) and Voc from the
% settled baseline idle. Expected load during stimulation, from test 1: the
% sham LED task (the sham LED is on during stimulation, idle included) plus
% the LED's own current at full amplitude scaled by amplitude/100.
% From each measured voltage the model gives the current the Rx delivers,
% I_rx = (Voc - V)/Rs, and its power P_rx = V*I_rx, without assuming the
% load. The residual X = I_rx - I_load - I_self is the part the expected
% load does not explain.
% Figure 1: battery voltage over the session.
% Figure 2: per amplitude, at pulse onset (first onsetWin_s) and end (last
%           endWin_s): a) bank voltage, b) load current from the Rx model
%           against the expected load, c) Rx power, d) time constants of the
%           sag during the pulse and of the recovery after it.
% Figure 3: a) measured voltage against the model over the session (no
%           bank, and the nominal bank on the measured node); b) residual
%           power V*X (0 when the expected load explains the voltage).
% An optional <recording>.meta.yml next to the log can set rs_fixed_ohm
% (e.g. 46 ohm with the V_BANK capacitor fitted) and rx_current_limited:
% true. Each pulse is then classified from its trend over the last
% endSlopeWin_s: sustained (flat, in LDO regulation), bank-assisted (falling:
% the bank covers the shortfall, Rx share = expected load - C*|dV/dt|) or
% dropout plateau (flat below regulation: the device draws only what the Rx
% gives). With rx_current_limited the voltage-to-current conversion through
% the linear model is reported for sustained pulses only.
% Output: PNG figures and tables in results/device_<name>/<subTest>/, named after
% the recording: _epochs.csv, _amplitude.csv (one row per amplitude).
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 1-voltage-during-functions-on-wpt/
outDir  = fullfile(rootDir, 'results');
whichData = 'newest';   % 'newest' (newest .mat overall), 'all' (newest per device) or 'every'
subTest    = '1c-stim-amplitude-sweep';   % recordings in ../device_<name>/<subTest>/
recPattern = '*_stim-sweep*.mat';

% Figure style (as analyse_load_states.m)
figWidth      = 18;                  % cm
shadeStrength = 0.22;                % epoch shading (0 = white, 1 = full colour)
intervalColor = [0.93 0.93 0.93];    % ITIs
ink           = [0.15 0.15 0.15];
smoothWin_s   = 0.5;                 % Figure 1 running-mean window (s)
residWin_s    = 1;                   % Figure 3b running-mean window (s)
idleColor     = [51 34 136]/255;
ampLo         = [0.67 0.84 0.93];    % colour of the lowest amplitude
ampHi         = [0.13 0.27 0.53];    % colour of the highest amplitude
onsetColor    = [0.80 0.40 0.47];    % Figure 2 onset points
endColor      = [0.13 0.27 0.53];    % Figure 2 end points
bankColor     = [0.27 0.47 0.67];    % Figure 3 bank model

% Load current, from test 1 (task_summary.csv and led_summary.csv of every
% device in ../../1-current-consumption-test/analysis/results/)
test1Dir = fullfile(fileparts(fileparts(testDir)), '1-current-consumption-test', 'analysis', 'results');

% Power circuit (as analyse_load_states.m)
RsFixed_ohm = 172;   % Rx source resistance: mean of the full fits of 20261012_203308_load-states_stim-pw12ms
                     % (174), _203854 (168) and 20261013_161505_drain-by-sham-status (175)
Ccell_mF   = 11;     % supercapacitor cell capacitance (mF), rated 3.3 V
nPar       = 3;      % cells in parallel per group
nSer       = 2;      % groups in series (6.6 V rating)
Rbal_kOhm  = 200;    % balancing resistor across each group (kOhm)
leak_uA    = 0;      % extra constant self-consumption: cell + zener leakage (uA, datasheets)
vLdo       = 3.3;    % LDO output (V)
ldoDropout = 0.1;    % LDO dropout at these loads (V); CHECK against the LDO datasheet
vReg       = vLdo + ldoDropout;   % lowest bank voltage with VCC in regulation (V)
vBrownOut  = 2.5;    % brown-out voltage (V)

% Per-pulse measures
onsetWin_s  = 0.5;   % pulse onset: reads in the first onsetWin_s
endWin_s    = 1;     % pulse / ITI end: reads in the last endWin_s
minFitAmp_V = 0.05;  % exponential fits with a smaller change report no time constant
recSkip_s   = 0.3;   % recovery fit starts this long after the pulse (skips the fast step)
endSlopeWin_s = 2;   % pulse classification: trend over the last endSlopeWin_s of each pulse
flatSlope_Vps = 0.03;   % flatter than this counts as settled (V/s)

%% Find recordings
recs = findRecordings(testDir, subTest, recPattern, whichData);
if isempty(recs), error('No %s found in %s', recPattern, fullfile(testDir, 'device_*', subTest)); end
loadI = test1Currents(test1Dir);

for s = 1:numel(recs)
    [~, recName] = fileparts(recs(s).file);
    fprintf('=== %s: %s ===\n', recs(s).folder, recName);
    L = load(recs(s).file, 'wpt_opto_df', 'config');
    df = L.wpt_opto_df; cfg = L.config;
    [recDir, recBase] = fileparts(recs(s).file);
    recMeta = struct();
    if isfile(fullfile(recDir, [recBase '.meta.yml'])), recMeta = readMeta(fullfile(recDir, [recBase '.meta.yml'])); end
    RsUse_ohm = RsFixed_ohm;
    if isfield(recMeta, 'rs_fixed_ohm'), RsUse_ohm = str2double(recMeta.rs_fixed_ohm); end
    rxLimited = isfield(recMeta, 'rx_current_limited') && strcmpi(recMeta.rx_current_limited, 'true');
    sesDir = fullfile(outDir, recs(s).folder);
    if ~isfolder(sesDir), mkdir(sesDir); end

    % Reads labelled as stimulation after the pulse ended belong to the ITI
    % (the PC phase runs slightly past trigger + duration)
    stimEnd = cfg.trigger_s(:) + cfg.optoSetting.duration/1000;
    for k = 1:numel(stimEnd)
        late = df.amplitude == cfg.amplitudes(k) & df.t_s > stimEnd(k);
        df.state(late) = "idle"; df.amplitude(late) = 0;
        if any(late), fprintf('%d read(s) after the %d%% pulse moved to the ITI\n', nnz(late), cfg.amplitudes(k)); end
    end

    %% Timeline from the read time stamps
    t = df.t_s; v = df.bat_mv/1000;                 % s, V
    st = df.state;
    runStart = find([true; st(2:end) ~= st(1:end-1)]);
    runEnd   = [runStart(2:end) - 1; height(df)];
    nR = numel(runStart);
    tEdge = [0; (t(runEnd(1:end-1)) + t(runStart(2:end)))/2; t(end) + median(diff(t))/2];
    Start_s = tEdge(1:end-1); End_s = tEdge(2:end);
    runAmp = df.amplitude(runStart);
    isStim = runAmp > 0;
    fprintf('%d samples over %.1f s: %.1f Hz achieved (fs = %g Hz); LED %d, %s\n', height(df), ...
        tEdge(end), height(df)/tEdge(end), cfg.fs, cfg.stimLed, cfg.stopReason);

    %% Epochs
    Epoch = (1:nR)'; State = st(runStart); Amplitude = runAmp;
    Samples = runEnd - runStart + 1;
    Onset_V = zeros(nR, 1); End_V = Onset_V; Median_V = Onset_V;
    for r = 1:nR
        k = runStart(r):runEnd(r);
        Onset_V(r) = median(v(k(t(k) <= t(k(1)) + onsetWin_s)), 'omitnan');
        End_V(r)   = median(v(k(t(k) >= t(k(end)) - endWin_s)), 'omitnan');
        Median_V(r) = median(v(k), 'omitnan');
    end
    epochTbl = table(Epoch, State, Amplitude, Start_s, End_s, Samples, Onset_V, End_V, Median_V);
    writetable(epochTbl, fullfile(sesDir, [recName '_epochs.csv']));

    %% Rx source model and expected load
    % Voc from the settled baseline idle (last half of the first epoch), Rs fixed
    Rs = RsUse_ohm/1000;                         % kOhm
    Rb = nSer*Rbal_kOhm;                         % kOhm, balancing resistors in series
    C  = nPar*Ccell_mF/nSer;                     % mF, bank capacitance
    leakI = leak_uA/1000;
    Iself = @(V) V/Rb + leakI;                   % mA
    k = runStart(1):runEnd(1); k = k(ceil(end/2):end);
    Vidle = median(v(k), 'omitnan');
    Voc = Vidle + Rs*(loadI.idle + Iself(Vidle));
    Vss  = @(I) (Voc - Rs*(I + leakI)) / (1 + Rs/Rb);   % steady state, load I (mA)
    Irx  = @(V) (Voc - V)/Rs;                    % current out of the Rx (mA)
    Iimp = @(V) Irx(V) - Iself(V);               % load current that explains V (mA)
    Iled = loadI.led(cfg.stimLed);               % LED alone at full amplitude (mA)
    Iexp = @(a) loadI.sham + a/100*Iled;         % expected stimulation load (mA)
    Pmax = max(Vss(linspace(0, Voc/Rs, 2000)) .* linspace(0, Voc/Rs, 2000));
    fprintf('Rx model: baseline %.3f V, Rs fixed %.0f ohm -> Voc %.2f V; max Rx power %.1f mW\n', ...
        Vidle, Rs*1000, Voc, Pmax);
    fprintf('Expected load: sham %.2f mA + amplitude/100 x LED %d %.2f mA (test 1)\n', ...
        loadI.sham, cfg.stimLed, Iled);
    I_run = repmat(loadI.idle, nR, 1); I_run(isStim) = Iexp(runAmp(isStim));

    %% Per amplitude
    rs = find(isStim);
    nA = numel(rs);
    Amp = runAmp(rs);
    Expected_mA = Iexp(Amp); Model_V = Vss(Expected_mA);
    Onset = Onset_V(rs); EndV = End_V(rs);
    ImpOnset_mA = Iimp(Onset); ImpEnd_mA = Iimp(EndV);
    ProxOnset_mW = Onset .* Irx(Onset); ProxEnd_mW = EndV .* Irx(EndV);
    XEnd_mA = ImpEnd_mA - Expected_mA;
    RsImplied_ohm = 1000*(Vidle - Onset) ./ (Expected_mA - loadI.idle);  % if the expected load held at onset
    TauSag_s = nan(nA, 1); TauRec_s = TauSag_s; ItiEnd_V = TauSag_s;
    EndSlope_Vps = nan(nA, 1); RxShare_mA = nan(nA, 1); Class = strings(nA, 1);
    for j = 1:nA
        k = runStart(rs(j)):runEnd(rs(j));
        ke = k(t(k) >= t(k(end)) - endSlopeWin_s);
        q = polyfit(t(ke), v(ke), 1); EndSlope_Vps(j) = q(1);
        if EndSlope_Vps(j) <= -flatSlope_Vps
            Class(j) = "bank-assisted";
            RxShare_mA(j) = Expected_mA(j) - C*(-EndSlope_Vps(j));   % mA (mF x V/s)
        elseif EndV(j) >= vReg
            Class(j) = "sustained"; RxShare_mA(j) = Expected_mA(j);
        else
            Class(j) = "dropout plateau";
        end
        p = expFit(t(k) - t(k(1)), v(k));
        if abs(v(k(1)) - EndV(j)) >= minFitAmp_V, TauSag_s(j) = p(3); end
        if rs(j) < nR
            k = runStart(rs(j) + 1):runEnd(rs(j) + 1);
            k = k(t(k) >= stimEnd(cfg.amplitudes == Amp(j)) + recSkip_s);
            p = expFit(t(k) - t(k(1)), v(k));
            if abs(End_V(rs(j) + 1) - v(k(1))) >= minFitAmp_V, TauRec_s(j) = p(3); end
            ItiEnd_V(j) = End_V(rs(j) + 1);
        end
    end
    if rxLimited                                 % linear model only below the Rx current limit
        bad = Class ~= "sustained";
        ImpOnset_mA(bad) = NaN; ImpEnd_mA(bad) = NaN; XEnd_mA(bad) = NaN;
        ProxOnset_mW(bad) = NaN; ProxEnd_mW(bad) = NaN;
    end
    for j = 1:nA
        fprintf('%3d%%: %-15s end %.2f V, trend %+.3f V/s, Rx share %s mA\n', Amp(j), Class(j), EndV(j), ...
            EndSlope_Vps(j), num2str(RxShare_mA(j), '%.1f'));
    end
    ampTbl = table(Amp, Expected_mA, Model_V, Onset, EndV, ItiEnd_V, Class, EndSlope_Vps, RxShare_mA, ...
        ImpOnset_mA, ImpEnd_mA, XEnd_mA, ProxOnset_mW, ProxEnd_mW, RsImplied_ohm, TauSag_s, TauRec_s, ...
        'VariableNames', {'Amplitude', 'Expected_mA', 'Model_V', 'Onset_V', 'End_V', 'ItiEnd_V', 'Class', ...
        'EndTrend_Vps', 'RxShare_mA', 'LoadOnset_mA', 'LoadEnd_mA', 'XEnd_mA', 'PrxOnset_mW', 'PrxEnd_mW', ...
        'RsImplied_ohm', 'TauSag_s', 'TauRecovery_s'});
    disp(ampTbl)
    writetable(ampTbl, fullfile(sesDir, [recName '_amplitude.csv']));

    ampCol = @(a) ampLo + (a - min(Amp))/max(1, max(Amp) - min(Amp)) * (ampHi - ampLo);

    %% Figure 1: battery voltage over the session
    f = newFigure(figWidth, 7);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.0 figWidth - 2.1 5.0]); hold(ax, 'on')
    yLo = floor(min(v)*2)/2; yHi = ceil(max(v)*2)/2;
    for r = 1:nR
        if isStim(r)
            c = 1 - shadeStrength*(1 - ampCol(runAmp(r)));
        elseif r == 1 || r == nR
            c = 1 - shadeStrength*(1 - idleColor);
        else
            c = intervalColor;
        end
        patch(ax, [Start_s(r) End_s(r) End_s(r) Start_s(r)], [yLo yLo yHi yHi], c, 'EdgeColor', 'none');
        if isStim(r)
            text(ax, (Start_s(r) + End_s(r))/2, yHi, sprintf('%d%%', runAmp(r)), ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontSize', 8, ...
                'Color', ink, 'Clipping', 'off');
        end
    end
    plot(ax, [0 tEdge(end)], vReg*[1 1], ':', 'Color', ink, 'LineWidth', 0.75);
    plot(ax, [0 tEdge(end)], vBrownOut*[1 1], ':', 'Color', ink, 'LineWidth', 0.75);
    scatter(ax, t, v, 4, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.5);
    for r = 1:nR
        k = runStart(r):runEnd(r);
        plot(ax, t(k), movmean(v(k), smoothWin_s, 'omitnan', 'SamplePoints', t(k)), '-', ...
            'Color', ink, 'LineWidth', 1.25);
    end
    text(ax, tEdge(end), vReg, sprintf('LDO regulation %.1f V ', vReg), 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'bottom', 'FontSize', 6, 'Color', ink);
    text(ax, tEdge(end), vBrownOut, sprintf('brown-out %.1f V ', vBrownOut), 'HorizontalAlignment', ...
        'right', 'VerticalAlignment', 'bottom', 'FontSize', 6, 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); ax.Layer = 'top';
    xlim(ax, [0 tEdge(end)]); ylim(ax, [min(yLo, 2.5) yHi]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Bank voltage (V)');
    saveFigure(f, fullfile(sesDir, [recName '_battery_overview']));

    %% Figure 2: response per amplitude
    f = newFigure(figWidth, 12.5);
    w = (figWidth - 3.4)/2; hA = 4.3;
    pos = {[1.4 7.4 w hA], [1.4 + w + 1.8 7.4 w hA], [1.4 1.1 w hA], [1.4 + w + 1.8 1.1 w hA]};
    aGrid = linspace(0, 100, 101);
    xl = [0 105];
    % a: voltage
    ax = axes(f, 'Units', 'centimeters', 'Position', pos{1}); hold(ax, 'on')
    hM = plot(ax, aGrid, Vss(Iexp(aGrid)), '-', 'Color', ink, 'LineWidth', 1);
    refLine(ax, xl, vReg, sprintf('LDO regulation %.1f V', vReg), ink);
    refLine(ax, xl, vBrownOut, sprintf('Brown-out %.1f V', vBrownOut), ink);
    hO = plot(ax, Amp, Onset, 'o-', 'Color', onsetColor, 'MarkerFaceColor', onsetColor, 'MarkerSize', 4);
    hE = plot(ax, Amp, EndV, 's-', 'Color', endColor, 'MarkerFaceColor', endColor, 'MarkerSize', 4);
    hI = plot(ax, Amp, ItiEnd_V, '^:', 'Color', [0.5 0.5 0.5], 'MarkerFaceColor', [0.5 0.5 0.5], 'MarkerSize', 3);
    plot(ax, 0, Vidle, 'o', 'Color', idleColor, 'MarkerFaceColor', idleColor, 'MarkerSize', 4);
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, xl); ylim(ax, [1 ceil((Voc + 0.2)*2)/2]);
    xlabel(ax, 'Amplitude (%)'); ylabel(ax, 'Bank voltage (V)');
    legend(ax, [hM hO hE hI], {'Model, expected load', sprintf('Pulse onset (%.1f s)', onsetWin_s), ...
        sprintf('Pulse end (last %g s)', endWin_s), 'End of next ITI'}, 'Location', 'southeast', ...
        'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'a', -0.18);
    % b: load current
    ax = axes(f, 'Units', 'centimeters', 'Position', pos{2}); hold(ax, 'on')
    hX = plot(ax, aGrid, Iexp(aGrid), '-', 'Color', ink, 'LineWidth', 1);
    hO = plot(ax, Amp, ImpOnset_mA, 'o-', 'Color', onsetColor, 'MarkerFaceColor', onsetColor, 'MarkerSize', 4);
    hE = plot(ax, Amp, ImpEnd_mA, 's-', 'Color', endColor, 'MarkerFaceColor', endColor, 'MarkerSize', 4);
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, xl); ylim(ax, [0 ceil(max([ImpEnd_mA; Iexp(100)])/2)*2 + 1]);
    xlabel(ax, 'Amplitude (%)'); ylabel(ax, 'Load current (mA)');
    hold(ax, 'on');
    hS = plot(ax, Amp, RxShare_mA, 'd', 'Color', ink, 'MarkerFaceColor', [0.85 0.85 0.85], 'MarkerSize', 5);
    hold(ax, 'off');
    legend(ax, [hX hO hE hS], {'Expected (test 1)', 'From voltage, onset', 'From voltage, end', ...
        'Rx share (expected - bank)'}, ...
        'Location', 'northwest', 'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'b', -0.18);
    % c: Rx power
    ax = axes(f, 'Units', 'centimeters', 'Position', pos{3}); hold(ax, 'on')
    hX = plot(ax, aGrid, Vss(Iexp(aGrid)) .* Irx(Vss(Iexp(aGrid))), '-', 'Color', ink, 'LineWidth', 1);
    PmaxShow = Pmax; pLabel = sprintf('Rx maximum %.1f mW', Pmax);
    if rxLimited && any(Class == "bank-assisted")      % measured limit instead of the linear model's
        Ilim = median(RxShare_mA(Class == "bank-assisted"));
        PmaxShow = Ilim*median(EndV(Class == "bank-assisted"));
        pLabel = sprintf('Rx limit %.1f mA (about %.0f mW)', Ilim, PmaxShow);
    end
    hP = plot(ax, xl, PmaxShow*[1 1], '--', 'Color', ink, 'LineWidth', 0.75);
    hO = plot(ax, Amp, ProxOnset_mW, 'o-', 'Color', onsetColor, 'MarkerFaceColor', onsetColor, 'MarkerSize', 4);
    hE = plot(ax, Amp, ProxEnd_mW, 's-', 'Color', endColor, 'MarkerFaceColor', endColor, 'MarkerSize', 4);
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, xl); ylim(ax, [0 ceil(max([PmaxShow; ProxOnset_mW; ProxEnd_mW])*1.4/5)*5]);
    xlabel(ax, 'Amplitude (%)'); ylabel(ax, 'Rx power (mW)');
    legend(ax, [hX hP hO hE], {'Model, expected load', pLabel, ...
        'From voltage, onset', 'From voltage, end'}, 'Location', 'southeast', 'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'c', -0.18);
    % d: time constants
    ax = axes(f, 'Units', 'centimeters', 'Position', pos{4}); hold(ax, 'on')
    hS = plot(ax, Amp, TauSag_s, 'o-', 'Color', endColor, 'MarkerFaceColor', endColor, 'MarkerSize', 4);
    hR = plot(ax, Amp, TauRec_s, 's-', 'Color', onsetColor, 'MarkerFaceColor', onsetColor, 'MarkerSize', 4);
    hold(ax, 'off'); styleAxes(ax); set(ax, 'YScale', 'log');
    xlim(ax, xl); ylim(ax, [0.1 100]);
    xlabel(ax, 'Amplitude (%)'); ylabel(ax, 'Time constant (s)');
    legend(ax, [hS hR], {'Sag during pulse', 'Recovery in next ITI'}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'd', -0.18);
    saveFigure(f, fullfile(sesDir, [recName '_amplitude']));

    %% Figure 3: model check and residual over the session
    tau = (Rs*Rb/(Rs + Rb))*C;
    tf = []; vQs = []; vDyn = []; v0 = Vidle;
    for r = 1:nR
        tt = linspace(tEdge(r), tEdge(r+1), max(20, ceil((tEdge(r+1) - tEdge(r))*50)))';
        vi = Vss(I_run(r));
        vd = vi + (v0 - vi)*exp(-(tt - tEdge(r))/tau);
        v0 = vd(end);
        tf = [tf; tt]; vQs = [vQs; repmat(vi, numel(tt), 1)]; vDyn = [vDyn; vd]; %#ok<AGROW>
    end
    [tu, iu] = unique(tf, 'last');
    eQs = v - interp1(tu, vQs(iu), t, 'previous');
    eDyn = v - interp1(tu, vDyn(iu), t);
    fprintf('Model check: bank tau = %.1f s; RMS error %.0f mV without bank, %.0f mV with bank\n', ...
        tau, 1000*rms(eQs, 'omitnan'), 1000*rms(eDyn, 'omitnan'));
    I_samp = I_run(sampleRun(runStart, height(df)));
    pX = v .* (Iimp(v) - I_samp);                % mW
    f = newFigure(figWidth, 11);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 6.6 figWidth - 2.1 4.0]); hold(ax, 'on')
    scatter(ax, t, v, 4, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.5, 'DisplayName', 'Measured');
    plot(ax, tf, vQs, '-', 'Color', ink, 'LineWidth', 1, 'DisplayName', 'Model, no bank');
    plot(ax, tf, vDyn, '-', 'Color', bankColor, 'LineWidth', 1, ...
        'DisplayName', sprintf('Model, %.1f mF bank (τ = %.1f s)', C, tau));
    plot(ax, [0 tEdge(end)], vReg*[1 1], ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
    plot(ax, [0 tEdge(end)], vBrownOut*[1 1], ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, [0 tEdge(end)]); ylim(ax, [2 ceil((Voc + 0.2)*2)/2]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Bank voltage (V)');
    legend(ax, 'Location', 'southwest', 'Box', 'off', 'FontSize', 7, 'NumColumns', 3);
    panelLetter(ax, 'a', -0.07);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.0 figWidth - 2.1 4.2]); hold(ax, 'on')
    smX = nan(size(pX));
    for r = 1:nR
        k = runStart(r):runEnd(r);
        smX(k) = movmean(pX(k), residWin_s, 'omitnan', 'SamplePoints', t(k));
    end
    yB = [floor(min(smX)/2)*2 - 1, ceil(max(smX)/2)*2 + 1];
    for r = find(isStim)'
        patch(ax, [Start_s(r) End_s(r) End_s(r) Start_s(r)], yB([1 1 2 2]), ...
            1 - shadeStrength*(1 - ampCol(runAmp(r))), 'EdgeColor', 'none');
        text(ax, (Start_s(r) + End_s(r))/2, yB(2), sprintf('%d%%', runAmp(r)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink);
    end
    yline(ax, 0, '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.5);
    scatter(ax, t, pX, 4, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.4);
    for r = 1:nR
        k = runStart(r):runEnd(r);
        plot(ax, t(k), smX(k), '-', 'Color', ink, 'LineWidth', 1.25);
    end
    hold(ax, 'off'); styleAxes(ax); ax.Layer = 'top';
    xlim(ax, [0 tEdge(end)]); ylim(ax, yB);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Unexplained power V·X (mW)');
    panelLetter(ax, 'b', -0.07);
    saveFigure(f, fullfile(sesDir, [recName '_model_check']));
    fprintf('Results saved to %s\n\n', sesDir);
end

%% Local functions
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

function r = sampleRun(runStart, n)
% Run index of every sample
r = zeros(n, 1); r(runStart) = 1; r = cumsum(r);
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

function refLine(ax, xr, y, label, ink)
% Dotted horizontal reference line, labelled at its left end
plot(ax, xr, [y y], ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
text(ax, xr(1) + 0.02*diff(xr), y, label, 'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
    'FontSize', 6, 'Color', ink);
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
