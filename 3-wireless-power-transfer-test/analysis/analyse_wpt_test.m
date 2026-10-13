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
% Figure 2: WPT power versus load. Each battery sample gives a delivered
% power P = V x I, with V the sample's battery voltage and I the current
% the device draws in that state, taken from the test 1 current results
% (mean of the devices measured there; see "Load current per state").
% Output: figures and per-epoch / per-state tables in
% results/<recording folder>/, named after the recording.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 3-wireless-power-transfer-test/
outDir  = fullfile(rootDir, 'results');
whichData = 'newest';   % 'newest' (newest .mat overall) or 'all' (newest per folder)

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
xJitter  = 0.12;    % horizontal jitter of the sample points in Figure 2 (mA)

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
    I_mA = arrayfun(@(k) I_state(char(k)), stateKey(sampleRun(runStart, height(df))));
    P_mW = df.bat_mv .* I_mA / 1000;               % mV x mA = uW -> mW
    ok = ~isnan(P_mW);
    pfit = polyfit(I_mA(ok), P_mW(ok), 1);
    R2 = 1 - sum((P_mW(ok) - polyval(pfit, I_mA(ok))).^2) / sum((P_mW(ok) - mean(P_mW(ok))).^2);

    StateLabel = stateLabel(:); Load_mA = zeros(numel(stateName), 1);
    Power_mW = Load_mA; PowerSD_mW = Load_mA; Voltage_mV = Load_mA; N = Load_mA;
    for i = 1:numel(stateName)
        m = ok & (stateKey(sampleRun(runStart, height(df))) == stateName(i));
        Load_mA(i) = I_state(char(stateName(i)));
        Power_mW(i) = mean(P_mW(m)); PowerSD_mW(i) = std(P_mW(m));
        Voltage_mV(i) = mean(df.bat_mv(m)); N(i) = nnz(m);
    end
    powerTbl = table(StateLabel, Load_mA, Voltage_mV, Power_mW, PowerSD_mW, N);
    disp(powerTbl)
    writetable(powerTbl, fullfile(sesDir, [recName '_power_vs_load.csv']));
    fprintf('Fit: P = %.3f mW/mA x I %+.3f mW (R^2 = %.3f); LED duty %.2f\n', pfit(1), pfit(2), R2, ledDuty);

    %% Figure 2: WPT power versus load
    f = newFigure(figWidth/2, 7.5);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.1 figWidth/2 - 2.0 5.9]);
    hold(ax, 'on')
    rng(1);   % reproducible jitter
    xs = linspace(0, ceil(max(I_mA)) + 1, 50);
    plot(ax, xs, polyval(pfit, xs), '-', 'Color', ink, 'LineWidth', 1);
    for i = 1:numel(stateName)
        m = ok & (stateKey(sampleRun(runStart, height(df))) == stateName(i));
        scatter(ax, I_mA(m) + xJitter*(2*rand(nnz(m), 1) - 1), P_mW(m), 6, tc(i, :), 'filled', ...
            'MarkerFaceAlpha', 0.35, 'HandleVisibility', 'off');
    end
    h = gobjects(numel(stateName), 1);
    for i = 1:numel(stateName)
        errorbar(ax, Load_mA(i), Power_mW(i), PowerSD_mW(i), 'Color', ink, 'LineWidth', 0.75, ...
            'CapSize', 3, 'HandleVisibility', 'off');
        h(i) = plot(ax, Load_mA(i), Power_mW(i), 'o', 'MarkerSize', 6, 'MarkerFaceColor', tc(i, :), ...
            'MarkerEdgeColor', ink, 'LineWidth', 0.75);
    end
    hold(ax, 'off')
    styleAxes(ax);
    xlim(ax, [0 xs(end)]); ylim(ax, [0 ceil(max(P_mW)*1.1/5)*5]);
    xlabel(ax, 'Load current (mA)'); ylabel(ax, 'WPT power (mW)');
    legend(ax, h, cellstr(stateLabel), 'Location', 'northwest', 'Box', 'off', 'FontSize', 7);
    sgn = '+'; if pfit(2) < 0, sgn = '−'; end
    text(ax, 0.98, 0.04, {sprintf('P = %.2f·I %s %.2f  (mW, mA)', pfit(1), sgn, abs(pfit(2))), ...
        sprintf('R² = %.2f', R2)}, 'Units', 'normalized', 'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'bottom', 'FontSize', 8, 'Color', ink, 'Interpreter', 'none');
    saveFigure(f, fullfile(sesDir, [recName '_power_vs_load']));
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
    recs(end+1) = struct('folder', d(i).name, 'file', fullfile(b(k).folder, b(k).name), ...
        'datenum', b(k).datenum); %#ok<AGROW>
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
exportgraphics(f, [base '.pdf'], 'ContentType', 'vector', 'BackgroundColor', 'white');
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
close(f);
end

function c = hexColors(hex)
c = zeros(numel(hex), 3);
for k = 1:numel(hex)
    c(k, :) = sscanf(hex{k}(2:end), '%2x%2x%2x')' / 255;
end
end
