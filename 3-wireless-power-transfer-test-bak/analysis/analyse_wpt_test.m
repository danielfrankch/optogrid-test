% Analyse the OptoGrid wireless power transfer test (test 3)
% Run from MATLAB (Run button, or `analyse_wpt_test` from any folder).
% Input: wpt_battery_<date_time>.mat written by ../og_wpt_test.m, holding
% wpt_battery_df (sample, fs, bat_mv, state) and config. By default the
% newest .mat in the recording folders (../device_<name>/) is used.
% The battery reads are Bluetooth round trips and can run well below fs,
% so sample/fs is not a reliable clock. Time is rebuilt from the test
% schedule instead: each run of identical states lasts a known time (task
% durations, ITI and stimulation duration from config), and its samples are
% spread evenly over it.
% Power model. The Tx coil is much larger than the Rx and is not detuned
% by it, so the Rx chain (parallel-tuned coil, full-bridge rectifier,
% Schottky diode) is modelled as a DC source V = Voc - Rs*I feeding the
% supercapacitor bank (nSer x nPar cells, balancing resistors, zener) and
% the 3.3 V LDO. The LDO passes its load current through, so the bank node
% draws the test 1 current of each state (mean of the devices measured
% there; see "Load current of each state"). Energy balance on the bank:
%   P_rx = V*(I_load + I_self(V)) + C*V*dV/dt,  I_self = V/Rbal + leakage
% Voc and Rs are fitted to the settled voltage of the states that stay in
% LDO regulation (dV/dt = 0). The fit gives the Rx power curve, its maximum
% (matched load), the largest load above LDO regulation and brown-out, and
% the time the bank holds the device above brown-out once WPT stops.
% Figure 1: battery voltage over the session.
% Figure 2: a) bank voltage vs load, b) Rx and VCC power vs load,
%           c) time to brown-out vs load (WPT off, or WPT on and overloaded).
% Figure 3: model check, the measured voltage against the model over the
%           session, without and with the nominal bank on the measured node.
% Output: figures and tables in results/<recording folder>/, named after
% the recording: _epochs.csv, _power_vs_load.csv (per state), _wpt_model.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 3-wireless-power-transfer-test/
outDir  = fullfile(rootDir, 'results');
whichData = 'newest';   % 'newest' (newest .mat overall), 'all' (newest per folder) or 'every'

% Figure style, as Figure 1 of test 1 (Paul Tol 'muted' palette)
figWidth      = 18;                  % cm
shadeStrength = 0.22;                % epoch shading (0 = white, 1 = full colour)
intervalColor = [0.93 0.93 0.93];    % ITIs
ink           = [0.15 0.15 0.15];
smoothWin_s   = 0.5;                 % Figure 1 running-mean window (s); dots show every sample
% state -> label and colour (idle, status, sham and opto as in test 1)
stateName  = ["idle", "status", "sham", "sham+status", "opto", "imu"];
stateLabel = ["Idle", "Status LED", "Sham LED", "Sham + status LED", "Stimulation", "IMU streaming"];
stateHex   = {'#332288', '#DDCC77', '#CC6677', '#88CCEE', '#4477AA', '#117733'};

% Load current per state, from test 1 (task_summary.csv and led_summary.csv
% of every device in ../../1-current-consumption-test/analysis/results/)
test1Dir = fullfile(fileparts(testDir), '1-current-consumption-test', 'analysis', 'results');

% Power circuit
Ccell_mF   = 11;     % supercapacitor cell capacitance (mF), rated 3.3 V
nPar       = 3;      % cells in parallel per group
nSer       = 2;      % groups in series (6.6 V rating)
Rbal_kOhm  = 200;    % balancing resistor across each group (kOhm)
leak_uA    = 0;      % extra constant self-consumption: cell + zener leakage (uA, datasheets)
vZener     = 5.6;    % overvoltage zener on the bank (V)
vLdo       = 3.3;    % LDO output (V)
ldoDropout = 0.1;    % LDO dropout at these loads (V); CHECK against the LDO datasheet
vReg       = vLdo + ldoDropout;   % lowest bank voltage with VCC in regulation (V)
vBrownOut  = 2.5;    % brown-out voltage (V)

% Settled voltage per state
settleFrac  = 0.5;   % use the last half of each epoch
minSettle_s = 0.9;   % epochs shorter than this (short stimulations) never settle
settleSlope_Vps = 0.01;   % and the voltage trend over the tail must be flatter than this (V/s)
shortEpoch_s = 3;         % epochs shorter than this have only a few reads in their tail:
shortSettleSlope_Vps = 0.05;   % their trend limit (V/s)
minFitStates = 3;    % settled states in regulation needed to fit Voc and Rs
RsFixed_ohm  = 172;  % Rs used with fewer fit states (fit to idle only): mean of the full
                     % fits of wpt_battery_20261012_203308 (174), _203854 (168) and
                     % wpt_drain_20261013_161505 (175). Rs is set by the Rx coil and
                     % rectifier; coupling changes Voc only

%% Find recordings
recs = findRecordings(testDir, whichData);
if isempty(recs), error('No wpt_battery_*.mat found in the folders of %s', testDir); end
tc = hexColors(stateHex);
loadI = test1Currents(test1Dir);   % struct: idle, status, sham, imu, ledPerLed (mA)

for s = 1:numel(recs)
    [~, recName] = fileparts(recs(s).file);
    fprintf('=== %s: %s ===\n', recs(s).folder, recName);
    L = load(recs(s).file, 'wpt_battery_df', 'config');
    df = L.wpt_battery_df; cfg = L.config;
    sesDir = fullfile(outDir, recs(s).folder);
    if ~isfolder(sesDir), mkdir(sesDir); end

    %% Rebuild the timeline from the schedule
    optoState = df.state(startsWith(df.state, "opto"));
    optoState = optoState(1);
    imuState  = df.state(startsWith(df.state, "imu"));
    imuState  = imuState(1);
    d = cfg.durations_s; iti = cfg.iti; stimDur = cfg.optoSetting.duration/1000;
    sched = {"idle", d.idle; "idle", iti; "status", d.status; "idle", iti; "sham", d.sham; ...
        "idle", iti; "sham+status", d.shamStatus; "idle", iti};
    for k = 1:cfg.nTriggers
        sched(end+1, :) = {optoState, stimDur}; %#ok<AGROW>
        sched(end+1, :) = {"idle", iti};        %#ok<AGROW>
    end
    sched(end+1, :) = {imuState, d.imu};
    % merge consecutive identical states (the first idle and its ITI, ...)
    schedState = string(sched(:, 1)); schedDur = cell2mat(sched(:, 2));
    keep = [true; schedState(2:end) ~= schedState(1:end-1)];
    grp = cumsum(keep);
    schedDur = accumarray(grp, schedDur); schedState = schedState(keep);

    % observed runs of identical states
    st = df.state;
    runStart = find([true; st(2:end) ~= st(1:end-1)]);
    runEnd   = [runStart(2:end) - 1; height(df)];
    if numel(runStart) ~= numel(schedState) || any(st(runStart) ~= schedState)
        error('%s: state sequence does not match the test schedule; cannot rebuild time.', recName);
    end
    tEdge = [0; cumsum(schedDur)];
    t = zeros(height(df), 1);
    for r = 1:numel(runStart)
        n = runEnd(r) - runStart(r) + 1;
        t(runStart(r):runEnd(r)) = tEdge(r) + ((1:n)' - 0.5) / n * schedDur(r);
    end
    achieved = height(df) / tEdge(end);
    fprintf('%d samples over %.1f s: %.1f Hz achieved (fs = %g Hz)\n', height(df), tEdge(end), achieved, df.fs(1));

    %% Epoch means
    nR = numel(runStart);
    Epoch = (1:nR)'; State = schedState; Start_s = tEdge(1:end-1); End_s = tEdge(2:end);
    Samples = runEnd - runStart + 1;
    Mean_mV = arrayfun(@(r) mean(df.bat_mv(runStart(r):runEnd(r)), 'omitnan'), (1:nR)');
    SD_mV   = arrayfun(@(r) std(df.bat_mv(runStart(r):runEnd(r)), 'omitnan'), (1:nR)');
    epochTbl = table(Epoch, State, Start_s, End_s, Samples, Mean_mV, SD_mV);
    writetable(epochTbl, fullfile(sesDir, [recName '_epochs.csv']));
    stateKey = strings(nR, 1);
    for r = 1:nR
        hit = arrayfun(@(n) startsWith(State(r), n), stateName);
        stateKey(r) = stateName(find(hit, 1, 'last'));   % 'sham+status' wins over 'sham'
    end
    fprintf('%-18s %8s %8s %8s\n', 'state', 'samples', 'mean mV', 'sd mV');
    for i = 1:numel(stateName)
        v = df.bat_mv(ismember(df.state, State(stateKey == stateName(i))));
        if ~isempty(v), fprintf('%-18s %8d %8.0f %8.0f\n', stateLabel(i), numel(v), mean(v, 'omitnan'), std(v, 'omitnan')); end
    end

    %% Figure: mean battery voltage per epoch over the session
    f = newFigure(figWidth, 7.5);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.0 figWidth - 2.1 4.9]);
    hold(ax, 'on')
    yLo = floor(min(df.bat_mv)/500)*500; yHi = ceil(max(df.bat_mv)/500)*500;
    % task regions: the first idle task (before its ITI) and every non-idle epoch
    isTask = stateKey ~= "idle";
    for r = 1:nR
        if isTask(r)
            c = 1 - shadeStrength*(1 - tc(stateName == stateKey(r), :));
            patch(ax, [Start_s(r) End_s(r) End_s(r) Start_s(r)], [yLo yLo yHi yHi], c, 'EdgeColor', 'none');
        end
    end
    idleTask = [0 d.idle];                          % Task 1 (the rest of idle is ITI)
    patch(ax, idleTask([1 2 2 1]), [yLo yLo yHi yHi], 1 - shadeStrength*(1 - tc(1, :)), 'EdgeColor', 'none');
    for r = 1:nR                                    % ITIs in grey
        if ~isTask(r)
            a = Start_s(r); if r == 1, a = d.idle; end
            patch(ax, [a End_s(r) End_s(r) a], [yLo yLo yHi yHi], intervalColor, 'EdgeColor', 'none');
        end
    end
    % every sample, and a running mean over smoothWin_s that restarts at each
    % state change (so transitions are not smeared across epochs)
    sm = nan(height(df), 1);
    for r = 1:nR
        k = runStart(r):runEnd(r);
        sm(k) = movmean(df.bat_mv(k), smoothWin_s, 'omitnan', 'SamplePoints', t(k));
    end
    scatter(ax, t, df.bat_mv, 4, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.5);
    for r = 1:nR
        k = runStart(r):runEnd(r);
        plot(ax, t(k), sm(k), '-', 'Color', ink, 'LineWidth', 1.25);
    end
    hold(ax, 'off')
    styleAxes(ax);
    ax.Layer = 'top';
    xlim(ax, [0 tEdge(end)]); ylim(ax, [yLo yHi]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Battery voltage (mV)');
    % task names above their epochs, alternating between two rows
    spans = {"idle", idleTask};
    for i = 2:numel(stateName)
        rr = find(stateKey == stateName(i));
        if ~isempty(rr), spans(end+1, :) = {stateName(i), [Start_s(rr(1)) End_s(rr(end))]}; end %#ok<AGROW>
    end
    for i = 1:size(spans, 1)
        k = find(stateName == spans{i, 1});
        sp = spans{i, 2};
        yRow = 1.03 + 0.11*mod(i + 1, 2);
        ha = 'center'; xT = mean(sp);
        if i == size(spans, 1), ha = 'right'; xT = sp(2); end
        text(ax, xT, yLo + yRow*(yHi - yLo), stateLabel(k), 'HorizontalAlignment', ha, ...
            'VerticalAlignment', 'bottom', 'FontSize', 8, 'Color', ink, 'Clipping', 'off');
        line(ax, sp, [1 1]*(yLo + (yRow - 0.01)*(yHi - yLo)), 'Color', tc(k, :), 'LineWidth', 1.5, ...
            'Clipping', 'off');
    end
    saveFigure(f, fullfile(sesDir, [recName '_battery_overview']));

    %% Load current of each state (from test 1)
    % sham + status was not measured in test 1: idle plus both increments.
    % Stimulation: test 1 shows the sham LED on during stimulation, plus one
    % uLED at a time (LEDs fire in turn, pulse_width each, within period).
    os = cfg.optoSetting;
    ledDuty = min(1, numel(cfg.stimLeds)*os.pulse_width/os.period);
    I_state = containers.Map(cellstr(stateName), { ...
        loadI.idle, loadI.status, loadI.sham, ...
        loadI.status + loadI.sham - loadI.idle, ...
        loadI.sham + ledDuty*mean(loadI.led(cfg.stimLeds)), ...
        loadI.imu});
    sampleKey = stateKey(sampleRun(runStart, height(df)));
    I_mA = arrayfun(@(k) I_state(char(k)), sampleKey);

    %% Settled voltage of each state
    % Median of the last settleFrac of each epoch. An epoch counts as settled
    % if it lasts at least minSettle_s, the epoch before it stayed in LDO
    % regulation (after a sag below vReg the voltage recovers over seconds),
    % and the tail is flat (|trend| < settleSlope_Vps). A falling tail means
    % the Rx cannot supply the load and the bank makes up the difference.
    tailMed = zeros(nR, 1); tailSlope = nan(nR, 1); slopeTol = nan(nR, 1); inTail = false(height(df), 1);
    for r = 1:nR
        n = runEnd(r) - runStart(r) + 1;
        k = runEnd(r) - max(1, round(n*settleFrac)) + 1 : runEnd(r);
        inTail(k) = true;
        tailMed(r) = median(df.bat_mv(k), 'omitnan') / 1000;     % V
        okk = k(~isnan(df.bat_mv(k)));
        if numel(okk) >= 4
            q = polyfit(t(okk), df.bat_mv(okk)/1000, 1); tailSlope(r) = q(1);
            slopeTol(r) = settleSlope_Vps;
            if End_s(r) - Start_s(r) < shortEpoch_s, slopeTol(r) = shortSettleSlope_Vps; end
        end
    end
    settled = (End_s - Start_s) >= minSettle_s & [true; tailMed(1:end-1) >= vReg] & ...
        abs(tailSlope) < slopeTol;
    for r = find((End_s - Start_s) >= minSettle_s & tailSlope <= -slopeTol)'
        deficit = nPar*Ccell_mF/nSer * -tailSlope(r);   % mA at the nominal bank (mF x V/s)
        fprintf('%s (%.0f-%.0f s) not settled: falling %.3f V/s -> bank supplies about %.2f mA at %.1f mF\n', ...
            State(r), Start_s(r), End_s(r), tailSlope(r), deficit, nPar*Ccell_mF/nSer);
    end
    nS = numel(stateName);
    Load_mA = zeros(nS, 1); V_set = nan(nS, 1); V_q1 = V_set; V_q3 = V_set;
    isSettled = false(nS, 1); present = false(nS, 1);
    for i = 1:nS
        Load_mA(i) = I_state(char(stateName(i)));
        rr = find(stateKey == stateName(i));
        if isempty(rr), continue, end
        present(i) = true;
        isSettled(i) = any(settled(rr));
        if isSettled(i), rr = rr(settled(rr)); end
        v = df.bat_mv(ismember(sampleRun(runStart, height(df)), rr) & inTail) / 1000;
        V_set(i) = median(v, 'omitnan');
        q = quantile(v, [0.25 0.75]); V_q1(i) = q(1); V_q3(i) = q(2);
    end
    inFit = present & isSettled & V_set >= vReg;
    fixedRs = nnz(inFit) < minFitStates;
    if fixedRs
        inFit = present & stateName(:) == "idle";
        warning('%s: %d settled states above %.2f V (need %d); Rs fixed at %g ohm, Voc fitted to idle.', ...
            recName, nnz(present & isSettled & V_set >= vReg), vReg, minFitStates, RsFixed_ohm);
    end

    %% Rx source model
    % The Tx coil is much larger than the Rx and is not detuned by it, so the
    % Rx (parallel-tuned coil, bridge, Schottky) acts as a fixed DC source with
    % a source resistance: V = Voc - Rs*I_rx, fitted to the settled states in
    % LDO regulation. The LDO passes its load current through, so the bank
    % node sees the test 1 current. Energy balance on the bank node:
    %   P_rx = V*(I_load + I_self(V)) + C*V*dV/dt,  I_self = V/Rbal + leakage
    % (Rbal = the two 200 kOhm balancing resistors in series; the zener
    % conducts only near vZener). In steady state the last term is 0.
    Rb = nSer*Rbal_kOhm;                         % kOhm, balancing resistors in series
    C  = nPar*Ccell_mF/nSer;                     % mF, bank capacitance
    Iself = @(V) V/Rb + leak_uA/1000;            % mA
    Ifit = Load_mA(inFit) + Iself(V_set(inFit)); % current out of the Rx
    if fixedRs
        Rs = RsFixed_ohm/1000; Voc = mean(V_set(inFit) + Rs*Ifit); R2 = NaN;
    else
        p = polyfit(Ifit, V_set(inFit), 1);
        Rs = -p(1); Voc = p(2);                  % kOhm, V
        R2 = 1 - sum((V_set(inFit) - polyval(p, Ifit)).^2) / sum((V_set(inFit) - mean(V_set(inFit))).^2);
    end
    leakI = leak_uA/1000;
    Vss = @(I) min(vZener, (Voc - Rs*(I + leakI)) / (1 + Rs/Rb));   % steady state, load I (mA)
    Ild = @(V) (Voc - V*(1 + Rs/Rb))/Rs - leakI;                     % load current at bank voltage V
    Prx = @(I) Vss(I) .* (I + Iself(Vss(I)));                       % mW out of the Rx
    Pvcc = @(I) I .* max(0, min(vLdo, Vss(I) - ldoDropout));         % mW delivered at VCC

    Igrid = linspace(0, Ild(0), 2000);
    [Pmax, k] = max(Prx(Igrid)); Imp = Igrid(k); Vmp = Vss(Imp);
    Ibo = Ild(vBrownOut); IregMax = Ild(vReg);
    % time to brown-out: WPT off, bank discharges into load I and Rbal
    tOff = @(V0, I) Rb*C*log((V0 + (I + leakI)*Rb) ./ (vBrownOut + (I + leakI)*Rb));
    % WPT on but load above Ibo: bank relaxes to Vss(I) < vBrownOut
    Rp = Rs*Rb/(Rs + Rb);
    Vinf = @(I) (Voc - Rs*(I + leakI)) / (1 + Rs/Rb);
    tOn = @(V0, I) Rp*C*log((V0 - Vinf(I)) ./ (vBrownOut - Vinf(I)));
    Vidle = Vss(Load_mA(stateName == "idle"));

    fprintf('Rx model: Voc = %.2f V, Rs = %.0f ohm (R^2 = %.3f, %d states); bank %.1f mF, Rbal %.0f kohm\n', ...
        Voc, Rs*1000, R2, nnz(inFit), C, Rb);
    fprintf('Self-consumption at idle (%.2f V): %.1f uA = %.3f mW (%.1f%% of idle load)\n', Vidle, ...
        Iself(Vidle)*1000, Vidle*Iself(Vidle), 100*Iself(Vidle)/Load_mA(1));
    fprintf('Max Rx power %.1f mW at %.1f mA, %.2f V (matched load %.0f ohm)\n', Pmax, Imp, Vmp, Vmp/Imp*1000);
    fprintf('Max load in LDO regulation (V >= %.2f V): %.1f mA, %.1f mW at VCC\n', vReg, IregMax, Pvcc(IregMax));
    fprintf('Max load above brown-out (V >= %.2f V): %.1f mA, %.1f mW from the Rx\n', vBrownOut, Ibo, Prx(Ibo));
    % states the Rx could not sustain although the linear model says it should
    falling = (End_s - Start_s) >= minSettle_s & tailSlope <= -slopeTol & stateKey ~= "idle";
    if any(falling)
        Ifall = arrayfun(@(r) I_state(char(stateKey(r))), find(falling));
        Ilim = Ifall - nPar*Ccell_mF/nSer*(-tailSlope(falling));    % Rx share, nominal bank
        if min(Ifall) < IregMax
            warning(['%s: the Rx could not sustain %s (%.1f mA load; Rx share about %.1f mA at the nominal bank), ' ...
                'below the linear model limit of %.1f mA. The Rx limits its current; the max-power and load limits ' ...
                'above are extrapolations of the linear fit.'], recName, strjoin(unique(stateKey(falling)), ', '), ...
                min(Ifall), min(Ilim), IregMax);
        end
    end

    %% Per-state table
    StateLabel = stateLabel(:);
    Power_mW = V_set .* (Load_mA + Iself(V_set));
    ModelV = Vss(Load_mA); ModelPower_mW = Prx(Load_mA);
    HoldUp_s = tOff(V_set, Load_mA);             % WPT cut while running this state
    HoldUpFromIdle_s = tOff(Vidle, Load_mA);     % WPT cut at idle, then this state
    HoldUp_s(V_set <= vBrownOut) = 0;
    Settled_V = V_set; Q1_V = V_q1; Q3_V = V_q3; Settled = isSettled; InFit = inFit;
    powerTbl = table(StateLabel, Load_mA, Settled_V, Q1_V, Q3_V, Settled, InFit, ModelV, ...
        Power_mW, ModelPower_mW, HoldUp_s, HoldUpFromIdle_s);
    powerTbl = powerTbl(present, :);
    disp(powerTbl)
    writetable(powerTbl, fullfile(sesDir, [recName '_power_vs_load.csv']));
    modelTbl = table(Voc, Rs*1000, R2, nnz(inFit), C, Rb, Iself(Vidle)*1000, Pmax, Imp, Vmp, ...
        Vmp/Imp*1000, IregMax, Pvcc(IregMax), Ibo, Prx(Ibo), ...
        'VariableNames', {'Voc_V', 'Rs_ohm', 'R2', 'FitStates', 'C_mF', 'Rbal_kohm', 'IselfIdle_uA', ...
        'Pmax_mW', 'I_Pmax_mA', 'V_Pmax_V', 'MatchedLoad_ohm', 'Ireg_mA', 'Pvcc_Ireg_mW', ...
        'Ibrownout_mA', 'P_Ibrownout_mW'});
    writetable(modelTbl, fullfile(sesDir, [recName '_wpt_model.csv']));

    %% Figure 2: WPT model (a: Rx V-I, b: power, c: time to brown-out)
    f = newFigure(figWidth, 7);
    w = (figWidth - 4.4)/3; x0 = [1.3, 1.3 + w + 1.5, 1.3 + 2*(w + 1.5)];
    xMax = ceil(max(Imp, Ibo)*1.15);
    Ix = linspace(0, xMax, 400);
    shown = find(present);
    % a: bank voltage versus load
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0(1) 1.1 w 5.0]); hold(ax, 'on')
    plot(ax, Ix, Vss(Ix), '-', 'Color', ink, 'LineWidth', 1);
    refLine(ax, [0 xMax], vReg, sprintf('LDO regulation %.1f V', vReg), ink);
    refLine(ax, [0 xMax], vBrownOut, sprintf('Brown-out %.1f V', vBrownOut), ink);
    h = gobjects(0);
    for i = shown'
        errorbar(ax, Load_mA(i), V_set(i), V_set(i) - V_q1(i), V_q3(i) - V_set(i), 'Color', ink, ...
            'LineWidth', 0.5, 'CapSize', 2, 'HandleVisibility', 'off');
        h(end+1) = stateMarker(ax, Load_mA(i), V_set(i), tc(i, :), inFit(i), ink); %#ok<AGROW>
    end
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, [0 xMax]); ylim(ax, [0 ceil((Voc + 0.4)*2)/2]);
    xlabel(ax, 'Load current (mA)'); ylabel(ax, 'Bank voltage (V)');
    text(ax, 0.97, 0.97, {sprintf('Voc = %.2f V', Voc), sprintf('Rs = %.0f Ω', Rs*1000), ...
        fitNote(R2)}, 'Units', 'normalized', 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'top', 'FontSize', 7, 'Color', ink);
    legend(ax, h, cellstr(stateLabel(shown)), 'Location', 'southeast', 'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'a');
    % b: power out of the Rx and power at VCC
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0(2) 1.1 w 5.0]); hold(ax, 'on')
    yMax = ceil(Pmax*1.25/5)*5;
    patch(ax, [Ibo xMax xMax Ibo], [0 0 yMax yMax], intervalColor, 'EdgeColor', 'none');
    hRx = plot(ax, Ix, Prx(Ix), '-', 'Color', ink, 'LineWidth', 1);
    hVcc = plot(ax, Ix, Pvcc(Ix), '--', 'Color', ink, 'LineWidth', 0.75);
    plot(ax, Imp, Pmax, 'v', 'MarkerSize', 4, 'MarkerFaceColor', ink, 'MarkerEdgeColor', 'none');
    text(ax, Imp, Pmax, sprintf('  %.1f mW', Pmax), 'VerticalAlignment', 'bottom', ...
        'HorizontalAlignment', 'center', 'FontSize', 7, 'Color', ink);
    for i = shown'
        stateMarker(ax, Load_mA(i), Power_mW(i), tc(i, :), inFit(i), ink);
    end
    text(ax, (Ibo + xMax)/2, yMax*0.03, {'below', 'brown-out'}, 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink);
    hold(ax, 'off'); styleAxes(ax); ax.Layer = 'top';
    xlim(ax, [0 xMax]); ylim(ax, [0 yMax]);
    xlabel(ax, 'Load current (mA)'); ylabel(ax, 'Power (mW)');
    legend(ax, [hRx hVcc], {'Rx output', 'At VCC (after LDO)'}, 'Location', 'northwest', ...
        'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'b');
    % c: time from WPT cut-off (or overload) to brown-out
    ax = axes(f, 'Units', 'centimeters', 'Position', [x0(3) 1.1 w 5.0]); hold(ax, 'on')
    Ic = linspace(0.2, xMax, 400);
    t1 = tOff(Vss(Ic), Ic); t1(Vss(Ic) <= vBrownOut) = NaN;
    t2 = tOff(Vidle, Ic);
    t3 = nan(size(Ic)); over = Ic > Ibo; t3(over) = tOn(Vidle, Ic(over));
    h1 = plot(ax, Ic, t1, '-', 'Color', ink, 'LineWidth', 1);
    h2 = plot(ax, Ic, t2, '--', 'Color', ink, 'LineWidth', 0.75);
    h3 = plot(ax, Ic, t3, ':', 'Color', ink, 'LineWidth', 1);
    xline(ax, Ibo, '-', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.5, 'HandleVisibility', 'off');
    for i = shown'
        if HoldUp_s(i) > 0, stateMarker(ax, Load_mA(i), HoldUp_s(i), tc(i, :), inFit(i), ink); end
    end
    hold(ax, 'off'); styleAxes(ax); set(ax, 'YScale', 'log');
    xlim(ax, [0 xMax]); ylim(ax, [0.1 1000]);
    xlabel(ax, 'Load current (mA)'); ylabel(ax, sprintf('Time to %.1f V (s)', vBrownOut));
    legend(ax, [h1 h2 h3], {'WPT off, from load level', 'WPT off, from idle level', ...
        'WPT on, overload'}, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6);
    text(ax, 0.03, 0.03, sprintf('C = %.1f mF', C), 'Units', 'normalized', 'FontSize', 7, ...
        'Color', ink, 'VerticalAlignment', 'bottom');
    panelLetter(ax, 'c');
    saveFigure(f, fullfile(sesDir, [recName '_wpt_model']));

    %% Figure 3: model check over the session
    % The model is run over the test schedule twice: without the bank
    % (voltage follows the load at once) and with the nominal bank on the
    % measured node (voltage relaxes with tau = (Rs||Rbal)*C).
    tau = Rp*C;
    runI = arrayfun(@(r) I_state(char(stateKey(r))), (1:nR)');
    tf = []; vQs = []; vDyn = []; v0 = Vidle;
    for r = 1:nR
        tt = linspace(tEdge(r), tEdge(r+1), max(20, ceil((tEdge(r+1) - tEdge(r))*50)))';
        vi = Vinf(runI(r));
        vd = vi + (v0 - vi)*exp(-(tt - tEdge(r))/tau);
        v0 = vd(end);
        tf = [tf; tt]; vQs = [vQs; repmat(vi, numel(tt), 1)]; vDyn = [vDyn; vd]; %#ok<AGROW>
    end
    [tu, iu] = unique(tf, 'last');
    vMeas = df.bat_mv/1000;
    eQs = vMeas - interp1(tu, vQs(iu), t, 'previous');
    eDyn = vMeas - interp1(tu, vDyn(iu), t);
    fprintf('Model check: bank tau = %.1f s; RMS error %.0f mV without bank, %.0f mV with bank\n', ...
        tau, 1000*rms(eQs, 'omitnan'), 1000*rms(eDyn, 'omitnan'));
    f = newFigure(figWidth, 6.5);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.0 figWidth - 2.1 5.0]); hold(ax, 'on')
    scatter(ax, t, vMeas, 4, [0.55 0.55 0.55], 'filled', 'MarkerFaceAlpha', 0.5, 'DisplayName', 'Measured');
    plot(ax, tf, vQs, '-', 'Color', ink, 'LineWidth', 1, 'DisplayName', 'Model, no bank');
    plot(ax, tf, vDyn, '-', 'Color', tc(5, :), 'LineWidth', 1, ...
        'DisplayName', sprintf('Model, %.1f mF bank (τ = %.1f s)', C, tau));
    yline(ax, vReg, ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
    yline(ax, vBrownOut, ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, [0 tEdge(end)]); ylim(ax, [2 ceil(Voc*2)/2]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Bank voltage (V)');
    legend(ax, 'Location', 'southwest', 'Box', 'off', 'FontSize', 7, 'NumColumns', 3);
    saveFigure(f, fullfile(sesDir, [recName '_model_check']));
    fprintf('Results saved to %s\n\n', sesDir);
end

%% Local functions
function recs = findRecordings(testDir, which)
% Newest wpt_battery_*.mat in each recording folder (any subfolder except
% analysis/); 'newest' keeps only the overall newest
recs = struct('folder', {}, 'file', {}, 'datenum', {});
d = dir(testDir);
d = d([d.isdir] & ~startsWith({d.name}, '.') & ~strcmp({d.name}, 'analysis'));
for i = 1:numel(d)
    b = dir(fullfile(testDir, d(i).name, 'wpt_battery_*.mat'));
    if isempty(b), continue, end
    [~, k] = max([b.datenum]);
    if strcmp(which, 'every'), k = 1:numel(b); end
    for j = k
        recs(end+1) = struct('folder', d(i).name, 'file', fullfile(b(j).folder, b(j).name), ...
            'datenum', b(j).datenum); %#ok<AGROW>
    end
end
if strcmp(which, 'newest') && ~isempty(recs)
    [~, k] = max([recs.datenum]);
    recs = recs(k);
end
end

function r = sampleRun(runStart, n)
% Run index of every sample
r = zeros(n, 1); r(runStart) = 1; r = cumsum(r);
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

function h = stateMarker(ax, x, y, c, filled, ink)
% State point: filled if used in the model fit, open otherwise
if filled, fc = c; else, fc = 'w'; end
h = plot(ax, x, y, 'o', 'MarkerSize', 5, 'MarkerFaceColor', fc, 'MarkerEdgeColor', c*0.8, ...
    'LineWidth', 1);
if filled, h.MarkerEdgeColor = ink; h.LineWidth = 0.5; end
end

function refLine(ax, xr, y, label, ink)
% Dotted horizontal reference line, labelled at its left end
plot(ax, xr, [y y], ':', 'Color', ink, 'LineWidth', 0.75, 'HandleVisibility', 'off');
text(ax, xr(1) + 0.02*diff(xr), y, label, 'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
    'FontSize', 6, 'Color', ink);
end

function s = fitNote(R2)
if isnan(R2), s = 'Rs fixed, Voc from idle'; else, s = sprintf('R² = %.3f', R2); end
end

function panelLetter(ax, s)
text(ax, -0.2, 1.06, s, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', ...
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

function c = hexColors(hex)
c = zeros(numel(hex), 3);
for k = 1:numel(hex)
    c(k, :) = sscanf(hex{k}(2:end), '%2x%2x%2x')' / 255;
end
end
