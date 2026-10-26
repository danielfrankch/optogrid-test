% Analyse OptoGrid current consumption recorded during og_test_1.m
% Input: WaveForms Scope "Record to File" binary (raw int16 ADC samples, one
% channel, no header) of the voltage across a shunt resistor in series with
% the device. The recording starts before og_test_1.m runs and ends after it.
% Output: figures and CSV tables in results/<session>/.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));
dataDir = fullfile(rootDir, 'data');
outDir  = fullfile(rootDir, 'results');

% Recording sessions. Scope settings are not stored in the .bin file.
sessions = struct( ...
    'name',        {'session1', 'session2'}, ...
    'file',        {'optogrid_individual_function_test_081026_1.bin', ...
                    'optogrid_individual_function_test_081026_2.bin'}, ...
    'fs',          {400e3, 299.401e3}, ...  % sample rate (Hz)
    'voltsPerDiv', {0.1, 0.1}, ...          % Scope channel range (V/div)
    'rangeV',      {5.49250862671, 5.49250862671}, ... % WaveForms Range (V); CHECK: Ch2 low-gain value
    'offsetV',     {-0.2, -0.2});           % Scope channel offset (V)
sessionsToRun = 1:numel(sessions);          % sessions whose file is missing are skipped

Rshunt = 10;  % shunt resistor (ohm)

% Test schedule: keep in sync with og_test_1.m
idleDur       = 5;   % Task 1
statusLedDur  = 5;   % Task 2
shamLedDur    = 5;   % Task 3
programDur    = 5;   % Task 4
triggerDur    = 5;   % Task 5
imuDur        = 15;  % Task 6
iti           = 3;
nULedChecks   = 10;  % Task 8

% Stimulation programmed by og_test_1.m (64 uLEDs fired one after another)
nLed            = 64;
stimPeriod_ms   = nLed*2 + 2;          % one sweep through all LEDs
stimDuration_ms = (nLed*2 + 2) * 20;   % full-amplitude part
stimRampDown_ms = (nLed*2 + 2) * 5;    % ramp-down after the full-amplitude part

% Detection / analysis parameters
levelBin      = 10e-3;   % bin for the median current level used to find task edges (s)
levelSmooth   = 0.2;     % moving median over level bins (s)
edgeThr_mA    = 1.0;     % rise above preceding baseline that marks a task start (mA)
edgeTrim      = 0.1;     % trimmed from both ends of each task window for stats (s)
stimFloorBin  = 0.5e-3;  % bin for the minimum current used to find stimulation on/off (s)
stimFloorThr_mA = 1.5;   % stimulation floor (sham LED on) above idle (mA)
uLedEventThr_mA = 5;     % 1 ms minimum current above idle that marks a uLED check (mA)
radioThr_mA   = 4;       % above idle floor counts as radio activity (mA); lower picks up
                         % the ~2 mA 100 Hz activity left after IMU streaming
radioMergeGap = 200e-6;  % merge activity separated by less than this (s)
radioMinDur   = 150e-6;  % shorter activity is the 1 kHz tick, not a radio event (s)
radioPad      = 50e-6;   % padding added around each radio event (s)
slotTrimStart = 0.25e-3; % excluded at the start of each LED slot (s)
slotTrimEnd   = 0.10e-3; % excluded at the end of each LED slot (s)
darkLedFrac   = 0.3;     % LED current below this fraction of the median LED is flagged as not lighting
nRefSweeps    = 2;       % full-amplitude sweeps shown before the ramp-down in Figure 6

% Figure style (Paul Tol 'muted' palette, colourblind-safe)
figWidth  = 18;      % figure width (cm), double-column
traceBin  = 10e-3;   % averaging bin for the traces in Figure 2 (s)
taskHex   = {'#999933', '#332288', '#DDCC77', '#CC6677', '#AA4499', ...  % one per task window,
             '#4477AA', '#117733', '#44AA99', '#882255', '#7570B3'};     % in window order
stimIdx   = 6;                                % task window holding the stimulation
radioHex  = {'#332288', '#BBBBBB', '#CC6677'}; % radio off, overall, radio on
intervalColor = [0.93 0.93 0.93];             % Figure 1 shading between tasks
shadeStrength = 0.22;                         % Figure 1 epoch shading (0 = white, 1 = full colour)
darkColor = [0.7 0.7 0.7];                    % LEDs not lighting

%% Run
for s = sessionsToRun
    cfg = sessions(s);
    binFile = fullfile(dataDir, cfg.file);
    if ~isfile(binFile)
        fprintf('Skipping %s: %s not found\n', cfg.name, cfg.file);
        continue
    end
    fprintf('=== %s: %s ===\n', cfg.name, cfg.file);
    sesDir = fullfile(outDir, cfg.name);
    if ~isfolder(sesDir), mkdir(sesDir); end

    %% Load and convert to current
    % WaveForms: Volts = Range*Sample/65536 - Offset, with Range and Offset
    % the channel values WaveForms reports for the recording (the manual
    % writes + Offset, but the offset is applied in hardware and has to be
    % subtracted back out; see CLAUDE.md)
    fid = fopen(binFile, 'r');
    raw = fread(fid, inf, 'int16=>single');
    fclose(fid);
    fs = cfg.fs;
    i_mA = (raw * (cfg.rangeV/65536) - cfg.offsetV) / Rshunt * 1e3;
    clear raw
    N = numel(i_mA);
    fprintf('%d samples, %.2f s at %.3f kHz\n', N, N/fs, fs/1e3);
    seg = @(t1, t2) i_mA(max(1, round(t1*fs)+1) : min(N, round(t2*fs)+1));

    %% Find task edges
    % Median current in 10 ms bins follows the steady level and ignores
    % radio and tick spikes
    [levT, lev] = binStat(i_mA, fs, levelBin, @median);
    levS = movmedian(lev, round(levelSmooth/levelBin));
    idleLevel = prctile(levS, 2);

    % Task 2 (status LED) is the first clear step up from idle
    tLow   = levT(find(levS < idleLevel + 0.5, 1));
    statusOn  = findRise(levT, levS, tLow + 0.2, edgeThr_mA);
    statusOff = findFall(levT, levS, statusOn);
    shamOn    = findRise(levT, levS, statusOff + 0.5, edgeThr_mA);
    shamOff   = findFall(levT, levS, shamOn);

    % Stimulation: sham LED stays on throughout, so the minimum current
    % stays above idle from start to end
    [flT, fl] = binStat(i_mA, fs, stimFloorBin, @(X, d) min(X, [], d));
    stimSearch = [shamOff + 2*iti + programDur - 1, shamOff + 2*iti + programDur + triggerDur + 2];
    k = find(flT >= stimSearch(1) & flT <= stimSearch(2));
    above = movmin(fl(k) > idleLevel + stimFloorThr_mA, [0 19]);  % held for 10 ms
    stimOn  = flT(k(find(above, 1))) - stimFloorBin/2;
    stimOff = flT(k(find(fl(k) > idleLevel + stimFloorThr_mA, 1, 'last'))) + stimFloorBin/2;

    imuOn  = findRise(levT, levS, stimOff + 0.5, edgeThr_mA);
    imuOff = findFall(levT, levS, imuOn);

    % uLED checks: short events where the 1 ms minimum current jumps up
    [evT, evMin] = binStat(i_mA, fs, 1e-3, @(X, d) min(X, [], d));
    postIdle = median(seg(imuOff + 0.5, imuOff + iti - 0.2));
    cand = evT(evT > imuOff + iti & evMin > postIdle + uLedEventThr_mA);
    evStarts = cand([true; diff(cand) > 0.2]);
    if numel(evStarts) < nULedChecks
        warning('Found %d uLED check events, expected %d', numel(evStarts), nULedChecks);
    end
    evStarts = evStarts(1:min(end, nULedChecks));
    uLedOn  = evStarts(1) - 0.05;
    uLedOff = evStarts(end) + 0.3;

    task1Start = statusOn - iti - idleDur;
    programOn  = shamOff + iti;
    batteryOn  = imuOff + iti;
    batteryOff = uLedOn - iti;

    % Windows: name, start, end, trim edges for stats
    W = {
        'Pre-script',          0,             task1Start - 0.5,  false
        'Idle (pre-IMU)',      task1Start,    task1Start + idleDur, true
        'Status LED',          statusOn,      statusOff,         true
        'Sham LED',            shamOn,        shamOff,           true
        'Program',             programOn,     programOn + programDur, false
        'Stimulation',         stimOn,        stimOff,           false
        'IMU streaming',       imuOn,         imuOff,            true
        'Battery reads',       batteryOn,     batteryOff,        false
        'µLED checks',         uLedOn,        uLedOff,           false
        'Idle (post-IMU)',     uLedOff + 1,   N/fs,              true
        };
    nW = size(W, 1);
    fprintf('\nTask windows (s):\n');
    for w = 1:nW, fprintf('  %-18s %7.3f - %7.3f\n', W{w,1}, W{w,2}, W{w,3}); end

    %% Task summary
    Task = strings(nW,1); tStart = zeros(nW,1); tEnd = zeros(nW,1);
    Mean_mA = zeros(nW,1); Median_mA = zeros(nW,1); SD_mA = zeros(nW,1); Peak_mA = zeros(nW,1);
    for w = 1:nW
        t1 = W{w,2}; t2 = W{w,3};
        if W{w,4}, t1 = t1 + edgeTrim; t2 = t2 - edgeTrim; end
        x = double(seg(t1, t2));
        Task(w) = W{w,1}; tStart(w) = W{w,2}; tEnd(w) = W{w,3};
        Mean_mA(w) = mean(x); Median_mA(w) = median(x); SD_mA(w) = std(x); Peak_mA(w) = max(x);
    end
    AboveIdle_mA = Mean_mA - Mean_mA(Task == "Idle (pre-IMU)");
    taskTbl = table(Task, tStart, tEnd, Mean_mA, Median_mA, SD_mA, Peak_mA, AboveIdle_mA);
    disp(taskTbl)
    writetable(taskTbl, fullfile(sesDir, 'task_summary.csv'));

    %% Idle: radio on vs off
    idleWin = {
        'Pre-script',      W{1,2}, W{1,3}
        'Idle (pre-IMU)',  W{2,2} + edgeTrim, W{2,3} - edgeTrim
        'Idle (post-IMU)', [imuOff + 0.3, W{10,2} + edgeTrim], [imuOff + iti - 0.2, W{10,3} - edgeTrim]
        };
    nI = size(idleWin, 1);
    radio = cell(nI, 1);
    for w = 1:nI
        xs = {};
        for p = 1:numel(idleWin{w,2})
            xs{end+1} = double(seg(idleWin{w,2}(p), idleWin{w,3}(p))); %#ok<AGROW>
        end
        radio{w} = radioStats(xs, fs, radioThr_mA, radioMergeGap, radioMinDur, radioPad);
    end
    Window = string(idleWin(:,1));
    Overall_mA    = cellfun(@(r) r.overallMean, radio);
    RadioOff_mA   = cellfun(@(r) r.offMean, radio);
    RadioOn_mA    = cellfun(@(r) r.onMean, radio);
    Floor_mA      = cellfun(@(r) r.floor, radio);
    RadioDuty_pct = cellfun(@(r) 100*r.duty, radio);
    EventRate_Hz  = cellfun(@(r) r.eventRate, radio);
    EventDur_ms   = cellfun(@(r) 1e3*r.eventDur, radio);
    EventCharge_uC = cellfun(@(r) r.eventCharge_uC, radio);
    radioTbl = table(Window, Overall_mA, RadioOff_mA, RadioOn_mA, Floor_mA, ...
        RadioDuty_pct, EventRate_Hz, EventDur_ms, EventCharge_uC);
    disp(radioTbl)
    writetable(radioTbl, fullfile(sesDir, 'idle_radio_summary.csv'));

    %% Stimulation: per-LED current
    % LEDs fire one after another, each for 1/nLed of the sweep period.
    % Estimate the real period from the data (device clock differs slightly
    % from the scope clock), then cut each sweep into LED slots.
    stimX = double(seg(stimOn, stimOff));
    period = estimatePeriod(stimX, fs, stimPeriod_ms*1e-3);
    slotDur = period / nLed;
    nFull = round(stimDuration_ms / stimPeriod_ms);
    nRep  = min(round((stimOff - stimOn) / period), nFull + round(stimRampDown_ms / stimPeriod_ms));

    % Refine where the first slot starts: average the full-amplitude sweeps
    % and pick the slot offset that best separates LEDs from each other
    perN = round(period*fs);
    fold = zeros(perN, 1);
    for r = 1:nFull
        k0 = round((stimOn + (r-1)*period)*fs) + 1;
        fold = fold + double(i_mA(k0 : k0 + perN - 1));
    end
    fold = [fold(end-ceil(perN/2)+1:end); fold; fold] / nFull;  % wrap so shifted slots stay in range
    offsets = round(-slotDur/2*fs) : round(slotDur/2*fs);
    contrast = zeros(size(offsets));
    for o = 1:numel(offsets)
        sm = zeros(nLed, 1);
        for L = 1:nLed
            a = round(((L-1)*slotDur + slotTrimStart)*fs) + offsets(o) + ceil(perN/2);
            b = round((L*slotDur - slotTrimEnd)*fs) + offsets(o) + ceil(perN/2);
            sm(L) = mean(fold(round(a):round(b)));
        end
        contrast(o) = var(sm);
    end
    [~, o] = max(contrast);
    stimOn = stimOn + offsets(o)/fs;
    shamRef = Mean_mA(Task == "Sham LED");  % idle + sham LED, no uLED
    slotMean = nan(nLed, nRep);
    preN  = round(0.5e-3*fs);
    waveN = round(slotDur*fs) + 2*preN;
    wave  = zeros(waveN, nLed);
    for r = 1:nRep
        for L = 1:nLed
            st = stimOn + ((r-1)*nLed + (L-1)) * slotDur;
            slotMean(L, r) = mean(double(seg(st + slotTrimStart, st + slotDur - slotTrimEnd)));
            if r <= nFull
                k0 = round(st*fs) + 1 - preN;
                wave(:, L) = wave(:, L) + double(i_mA(k0 : k0 + waveN - 1));
            end
        end
    end
    wave = wave / nFull;
    ledCurrent = slotMean - shamRef;                 % uLED-only current per slot
    LedMean_mA = mean(ledCurrent(:, 1:nFull), 2);
    LedSD_mA   = std(ledCurrent(:, 1:nFull), 0, 2);
    Dark = LedMean_mA < darkLedFrac * median(LedMean_mA);
    LED = (1:nLed)';
    ledTbl = table(LED, LedMean_mA, LedSD_mA, Dark);
    writetable(ledTbl, fullfile(sesDir, 'led_summary.csv'));
    fprintf('Stim sweep period %.3f ms (slot %.4f ms), %d full + %d ramp sweeps\n', ...
        period*1e3, slotDur*1e3, nFull, nRep - nFull);
    fprintf('uLED current (lit LEDs): mean %.2f mA, range %.2f - %.2f mA\n', ...
        mean(LedMean_mA(~Dark)), min(LedMean_mA(~Dark)), max(LedMean_mA(~Dark)));
    fprintf('Slot start shifted by %.3f ms\n', offsets(o)/fs*1e3);
    fprintf('LEDs not lighting (< %.0f%% of median): %s\n', 100*darkLedFrac, mat2str(find(Dark)'));

    %% Figures
    % Publication style: Arial, 8 pt ticks, 9 pt labels, 11 pt bold panel
    % letters, sized for an 18 cm double-column width; saved as vector PDF
    % and 300 dpi PNG
    tc = hexColors(taskHex);
    rc = hexColors(radioHex);
    ink = [0.15 0.15 0.15];
    [mT, mMean] = binStat(i_mA, fs, traceBin, @mean);

    %% Figure 1: mean current in each epoch
    % Epochs are the task windows plus the intervals between them
    ep = zeros(0, 4);  % start, end, mean, task index (0 = interval)
    tPrev = 0;
    for w = 1:nW
        if W{w,2} > tPrev + 1e-3
            ep(end+1, :) = [tPrev, W{w,2}, mean(double(seg(tPrev, W{w,2}))), 0]; %#ok<AGROW>
        end
        ep(end+1, :) = [W{w,2}, W{w,3}, Mean_mA(w), w]; %#ok<AGROW>
        tPrev = W{w,3};
    end
    f = newFigure(figWidth, 7.5);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.4 1.0 figWidth - 1.9 4.9]);
    hold(ax, 'on')
    yTop = ceil(max(ep(:, 3))) + 1;
    for e = 1:size(ep, 1)
        if ep(e, 4) == 0
            c = intervalColor;
        else
            c = 1 - shadeStrength*(1 - tc(ep(e, 4), :));  % light tint of the task colour
        end
        patch(ax, ep(e, [1 2 2 1]), [0 0 yTop yTop], c, 'EdgeColor', 'none');
    end
    stairs(ax, [ep(:, 1); ep(end, 2)], [ep(:, 3); ep(end, 3)], '-', 'Color', ink, 'LineWidth', 1.25);
    hold(ax, 'off')
    styleAxes(ax);
    ax.Layer = 'top';
    xlim(ax, [0 N/fs]); ylim(ax, [0 yTop]);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Mean current (mA)');
    % Task names above their epoch, alternating between two rows
    for w = 1:nW
        yRow = 1.03 + 0.11*mod(w + 1, 2);
        if w == nW, xT = W{w,3}; ha = 'right'; else, xT = mean([W{w,2} W{w,3}]); ha = 'center'; end
        text(ax, xT, yRow * yTop, W{w,1}, 'HorizontalAlignment', ha, ...
            'VerticalAlignment', 'bottom', 'FontSize', 8, 'Color', ink, 'Clipping', 'off');
        line(ax, [W{w,2} W{w,3}], [1 1]*(yRow - 0.01)*yTop, 'Color', tc(w, :), 'LineWidth', 1.5, ...
            'Clipping', 'off');
    end
    saveFigure(f, fullfile(sesDir, '1_overview'));

    %% Figure 2: individual functions
    f = newFigure(figWidth, 22);
    tl = tiledlayout(f, 5, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
    axs = gobjects(nW, 1);
    for w = 1:nW
        ax = nexttile(tl); axs(w) = ax; hold(ax, 'on')
        t1 = max(0, W{w,2} - 0.5); t2 = min(N/fs, W{w,3} + 0.5);
        k = mT >= t1 & mT <= t2;
        yTop = max(mMean(k)) * 1.25;
        patch(ax, [W{w,2} W{w,3} W{w,3} W{w,2}], [0 0 yTop yTop], [0.95 0.95 0.95], ...
            'EdgeColor', 'none');
        plot(ax, mT(k), mMean(k), '-', 'Color', tc(w, :), 'LineWidth', 0.75);
        plot(ax, [W{w,2} W{w,3}], Mean_mA([w w]), '--', 'Color', ink, 'LineWidth', 0.75);
        hold(ax, 'off')
        styleAxes(ax);
        xlim(ax, [t1 t2]); ylim(ax, [0 yTop]);
        title(ax, W{w,1}, 'FontWeight', 'normal');
        text(ax, 0.02, 0.96, sprintf('Mean %.2f mA', Mean_mA(w)), 'Units', 'normalized', ...
            'VerticalAlignment', 'top', 'FontSize', 8, 'Color', ink);
    end
    sharedLabels(tl, 'Time (s)', sprintf('Current, %g ms mean (mA)', traceBin*1e3));
    addPanelLabels(axs);
    saveFigure(f, fullfile(sesDir, '2_functions'));

    %% Figure 3: summary
    f = newFigure(figWidth, 8);
    tl = tiledlayout(f, 1, 2, 'TileSpacing', 'loose', 'Padding', 'compact');
    ax1 = nexttile(tl);
    b = barh(ax1, 1:nW, Mean_mA, 0.7, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = tc;
    for w = 1:nW
        text(ax1, Mean_mA(w) + 0.2, w, sprintf('%.2f', Mean_mA(w)), ...
            'VerticalAlignment', 'middle', 'FontSize', 8, 'Color', ink);
    end
    styleAxes(ax1);
    set(ax1, 'YDir', 'reverse', 'YTick', 1:nW, 'YTickLabel', Task, 'TickLength', [0 0], 'XGrid', 'on');
    xlim(ax1, [0 ceil(max(Mean_mA)*1.15)]); ylim(ax1, [0.4 nW + 0.6]);
    xlabel(ax1, 'Mean current (mA)');
    ax2 = nexttile(tl);
    b = bar(ax2, 1:nI, [RadioOff_mA Overall_mA RadioOn_mA], 0.8, 'EdgeColor', 'none');
    for j = 1:3, b(j).FaceColor = rc(j, :); end
    yMax = ceil(max(RadioOn_mA) * 1.3);
    for w = 1:nI
        text(ax2, w, RadioOn_mA(w) + 0.04*yMax, ...
            {sprintf('%.1f%% on', RadioDuty_pct(w)), sprintf('%.0f events/s', EventRate_Hz(w))}, ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontSize', 8, 'Color', ink);
    end
    styleAxes(ax2);
    set(ax2, 'XTick', 1:nI, 'XTickLabel', Window, 'YGrid', 'on');
    ylim(ax2, [0 yMax]);
    ylabel(ax2, 'Mean current (mA)');
    legend(ax2, {'Radio off', 'Overall', 'Radio on'}, 'Location', 'northoutside', 'Box', 'off', ...
        'FontSize', 8, 'Orientation', 'horizontal');
    addPanelLabels([ax1 ax2]);
    saveFigure(f, fullfile(sesDir, '3_summary'));

    %% Figure 4: idle radio detection examples
    f = newFigure(figWidth, 12);
    tl = tiledlayout(f, nI, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    axs = gobjects(nI, 1);
    for w = 1:nI
        ax = nexttile(tl); axs(w) = ax; hold(ax, 'on')
        t1 = idleWin{w,2}(end) + 0.5;
        x = double(seg(t1, t1 + 0.1));
        m = radioMask(x, fs, radio{w}.floor, radioThr_mA, radioMergeGap, radioMinDur, radioPad);
        tt = (0:numel(x)-1)'/fs*1e3;
        yTop = 25;
        [st, en] = runs(m);
        for e = 1:numel(st)
            patch(ax, tt([st(e) en(e) en(e) st(e)]), [0 0 yTop yTop], rc(3, :), ...
                'FaceAlpha', 0.25, 'EdgeColor', 'none', 'HandleVisibility', 'off');
        end
        plot(ax, tt, x, '-', 'Color', ink, 'LineWidth', 0.4);
        hold(ax, 'off')
        styleAxes(ax);
        xlim(ax, [0 100]); ylim(ax, [0 yTop]);
        if w < nI, ax.XTickLabel = []; end
        title(ax, sprintf('%s, from t = %.1f s', idleWin{w,1}, t1), 'FontWeight', 'normal');
    end
    hp = patch(axs(1), NaN, NaN, rc(3, :), 'FaceAlpha', 0.25, 'EdgeColor', 'none');
    legend(axs(1), hp, 'Radio event', 'Location', 'northeast', 'Box', 'off', 'FontSize', 8);
    sharedLabels(tl, 'Time (ms)', 'Current (mA)');
    addPanelLabels(axs);
    saveFigure(f, fullfile(sesDir, '4_idle_radio'));

    %% Figure 5: per-LED current waveforms
    tw = ((0:waveN-1)' - preN)/fs*1e3;
    f = newFigure(figWidth, 19);
    tl = tiledlayout(f, 8, 8, 'TileSpacing', 'compact', 'Padding', 'compact');
    yl = [floor(min(wave(:))) ceil(max(wave(:))) + 3];
    for L = 1:nLed
        ax = nexttile(tl); hold(ax, 'on')
        if Dark(L), c = darkColor; else, c = tc(stimIdx, :); end
        plot(ax, tw, repmat(shamRef, size(tw)), ':', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.5);
        plot(ax, tw, wave(:, L), '-', 'Color', c, 'LineWidth', 0.6);
        hold(ax, 'off')
        styleAxes(ax);
        set(ax, 'XTick', 0:1:2, 'YTick', 5:5:20, 'TickLength', [0.03 0.03]);
        xlim(ax, tw([1 end])); ylim(ax, yl);
        text(ax, 0.04, 0.97, sprintf('%d', L), 'Units', 'normalized', 'FontSize', 8, ...
            'FontWeight', 'bold', 'VerticalAlignment', 'top', 'Color', ink);
        text(ax, 0.96, 0.97, sprintf('%.1f', LedMean_mA(L)), 'Units', 'normalized', 'FontSize', 8, ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'Color', c);
        if mod(L-1, 8) ~= 0, ax.YTickLabel = []; end
        if L <= nLed - 8, ax.XTickLabel = []; end
    end
    sharedLabels(tl, 'Time from slot start (ms)', 'Total current (mA)');
    title(tl, sprintf(['Mean of %d full-amplitude sweeps. Bold: LED (firing order); ' ...
        'right: mean µLED current (mA); dotted: idle + sham LED; grey: not lighting.'], nFull), ...
        'FontName', 'Arial', 'FontSize', 8, 'FontWeight', 'normal', 'Color', ink, 'Interpreter', 'none');
    saveFigure(f, fullfile(sesDir, '5_led_waveforms'));

    %% Figure 6: per-LED summary
    f = newFigure(figWidth, 14);
    tl = tiledlayout(f, 2, 3, 'TileSpacing', 'loose', 'Padding', 'compact');
    ax1 = nexttile(tl, [1 3]); hold(ax1, 'on')
    b = bar(ax1, LED, LedMean_mA, 0.75, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = repmat(tc(stimIdx, :), nLed, 1);
    b.CData(Dark, :) = repmat(darkColor, nnz(Dark), 1);
    errorbar(ax1, LED, LedMean_mA, LedSD_mA, 'LineStyle', 'none', 'Color', ink, ...
        'LineWidth', 0.5, 'CapSize', 0);
    patch(ax1, NaN, NaN, tc(stimIdx, :), 'EdgeColor', 'none');
    patch(ax1, NaN, NaN, darkColor, 'EdgeColor', 'none');
    hold(ax1, 'off')
    styleAxes(ax1);
    ax1.YGrid = 'on';
    xlim(ax1, [0.3 nLed + 0.7]); ylim(ax1, [0 ceil(max(LedMean_mA + LedSD_mA)) + 1]);
    set(ax1, 'XTick', [1 8:8:nLed]);
    xlabel(ax1, 'LED (firing order)'); ylabel(ax1, 'µLED current (mA)');
    title(ax1, sprintf('Mean ± s.d. over %d full-amplitude sweeps', nFull), 'FontWeight', 'normal');
    ch = ax1.Children;
    legend(ax1, ch(2:-1:1), {'Lit', 'Not lighting'}, 'Location', 'northeast', 'Box', 'off', ...
        'FontSize', 8, 'Orientation', 'horizontal');
    % Ramp-down: the last nRefSweeps full-amplitude sweeps for comparison,
    % then every ramp sweep. Slots of LEDs that do not light are left out.
    rs = max(1, nFull - nRefSweeps + 1) : nRep;
    lc = ledCurrent(:, rs);
    lc(Dark, :) = NaN;
    tSlot = (((rs - 1) * nLed + (0:nLed-1)') + 0.5) * slotDur - nFull*period;  % ms after ramp start
    tSlot = tSlot * 1e3;
    tSweep = ((rs - 0.5) * period - nFull*period) * 1e3;
    sweepMean = mean(lc, 1, 'omitnan');
    sweepSD   = std(lc, 0, 1, 'omitnan');
    refMean   = mean(sweepMean(rs <= nFull));
    xl = [tSweep(1) - period*1e3/2, tSweep(end) + period*1e3/2];
    yMax = ceil(max(lc(:)) + 0.5);

    ax2 = nexttile(tl, [1 2]); hold(ax2, 'on')
    patch(ax2, [xl(1) 0 0 xl(1)], [0 0 yMax yMax], [0.93 0.93 0.93], 'EdgeColor', 'none');
    hs = plot(ax2, tSlot(:), lc(:), '-', 'Color', 1 - 0.45*(1 - tc(stimIdx, :)), 'LineWidth', 0.5);
    hm = plot(ax2, tSweep, sweepMean, 'o-', 'Color', ink, 'MarkerFaceColor', ink, ...
        'MarkerSize', 3, 'LineWidth', 1);
    hold(ax2, 'off')
    styleAxes(ax2);
    ax2.YGrid = 'on';
    xlim(ax2, xl); ylim(ax2, [0 yMax]);
    xlabel(ax2, 'Time from ramp-down start (ms)'); ylabel(ax2, 'µLED current (mA)');
    text(ax2, xl(1) + 0.02*diff(xl), 0.04*yMax, 'Full amplitude', 'FontSize', 8, 'Color', ink, ...
        'VerticalAlignment', 'bottom');
    text(ax2, 0.02*diff(xl), 0.04*yMax, 'Ramp-down', 'FontSize', 8, 'Color', ink, ...
        'VerticalAlignment', 'bottom');
    legend(ax2, [hs hm], {'Per LED slot', 'Sweep mean'}, 'Location', 'northeast', ...
        'Box', 'off', 'FontSize', 8);

    ax3 = nexttile(tl); hold(ax3, 'on')
    sweepNo = rs - nFull;  % <= 0: full amplitude, 1..: ramp sweeps
    errorbar(ax3, sweepNo, sweepMean, sweepSD, 'o-', 'Color', tc(stimIdx, :), ...
        'MarkerFaceColor', tc(stimIdx, :), 'MarkerSize', 3, 'LineWidth', 1, 'CapSize', 0);
    for k = find(sweepNo > 0)
        text(ax3, sweepNo(k) + 0.15, sweepMean(k), sprintf('%.0f%%', 100*sweepMean(k)/refMean), ...
            'FontSize', 8, 'Color', ink, 'VerticalAlignment', 'bottom');
    end
    hold(ax3, 'off')
    styleAxes(ax3);
    ax3.YGrid = 'on';
    set(ax3, 'XTick', sweepNo);
    xlim(ax3, [sweepNo(1) - 0.5, sweepNo(end) + 1.2]); ylim(ax3, [0 yMax]);
    xlabel(ax3, 'Sweep (0 = last full)'); ylabel(ax3, 'Mean µLED current (mA)');
    addPanelLabels([ax1 ax2 ax3]);
    saveFigure(f, fullfile(sesDir, '6_led_summary'));

    fprintf('Results saved to %s\n\n', sesDir);
    clear i_mA
end

%% Local functions
function [tc, y] = binStat(x, fs, binSec, fn)
% Statistic of consecutive bins; tc = bin centre times (s)
n = round(binSec*fs);
nb = floor(numel(x)/n);
y = double(fn(reshape(x(1:nb*n), n, nb), 1))';
tc = ((0:nb-1)' + 0.5) * n / fs;
end

function tEdge = findRise(levT, levS, tFrom, thr)
% First time after tFrom that the level rises thr above the level at tFrom
base = median(levS(levT >= tFrom & levT < tFrom + 0.5));
held = movmin(levS > base + thr, [0 round(0.5/(levT(2) - levT(1))) - 1]);  % held for 0.5 s
k = find(levT >= tFrom & held, 1);
if isempty(k), error('No rising edge found after %.2f s', tFrom); end
tEdge = levT(k);
end

function tEdge = findFall(levT, levS, tOn)
% First time after tOn that the level drops below halfway between the
% plateau and the level before tOn
base = median(levS(levT >= tOn - 1 & levT < tOn - 0.1));
plateau = median(levS(levT >= tOn + 0.5 & levT < tOn + 1.5));
held = movmin(levS < (base + plateau)/2, [0 round(0.5/(levT(2) - levT(1))) - 1]);  % held for 0.5 s
k = find(levT >= tOn + 0.5 & held, 1);
if isempty(k), error('No falling edge found after %.2f s', tOn); end
tEdge = levT(k);
end

function [st, en] = runs(m)
d = diff([false; m(:); false]);
st = find(d == 1);
en = find(d == -1) - 1;
end

function m = radioMask(x, fs, floorLvl, thr, mergeGap, minDur, pad)
% Radio events: activity above the idle floor lasting at least minDur once
% gaps shorter than mergeGap are bridged. Shorter blips (1 kHz tick) are
% left out.
m = x(:) > floorLvl + thr;
[gs, ge] = runs(~m);
for k = 1:numel(gs)
    if gs(k) > 1 && ge(k) < numel(m) && ge(k) - gs(k) + 1 <= round(mergeGap*fs)
        m(gs(k):ge(k)) = true;
    end
end
[st, en] = runs(m);
keep = (en - st + 1) >= round(minDur*fs);
m(:) = false;
p = round(pad*fs);
for k = find(keep)'
    m(max(1, st(k)-p) : min(numel(m), en(k)+p)) = true;
end
end

function r = radioStats(xs, fs, thr, mergeGap, minDur, pad)
% Radio on/off statistics over one or more idle segments (cell array)
floorLvl = median(vertcat(xs{:}));
allX = []; allM = []; nEv = 0; evLen = [];
for p = 1:numel(xs)
    m = radioMask(xs{p}, fs, floorLvl, thr, mergeGap, minDur, pad);
    [st, en] = runs(m);
    nEv = nEv + numel(st);
    evLen = [evLen; en - st + 1]; %#ok<AGROW>
    allX = [allX; xs{p}(:)]; %#ok<AGROW>
    allM = [allM; m]; %#ok<AGROW>
end
allM = logical(allM);
r.floor = floorLvl;
r.overallMean = mean(allX);
r.offMean = mean(allX(~allM));
r.onMean = mean(allX(allM));
r.duty = mean(allM);
r.eventRate = nEv / (numel(allX)/fs);
r.eventDur = mean(evLen)/fs;
r.eventCharge_uC = sum(allX(allM) - r.offMean)/fs / max(nEv, 1) * 1e3;  % mA*s = mC
end

function period = estimatePeriod(x, fs, nominal)
% Autocorrelation peak of 0.1 ms-binned current near the nominal period
n = round(1e-4*fs);
nb = floor(numel(x)/n);
y = mean(reshape(x(1:nb*n), n, nb), 1)';
y = y - mean(y);
binSec = n/fs;
lags = round(0.95*nominal/binSec) : round(1.05*nominal/binSec);
c = zeros(size(lags));
for k = 1:numel(lags)
    c(k) = sum(y(1:end-lags(k)) .* y(1+lags(k):end)) / (nb - lags(k));
end
[~, k] = max(c);
d = 0;
if k > 1 && k < numel(c)
    d = 0.5*(c(k-1) - c(k+1)) / (c(k-1) - 2*c(k) + c(k+1));  % parabolic refinement
end
period = (lags(k) + d) * binSec;
end

function f = newFigure(wCm, hCm)
f = figure('Units', 'centimeters', 'Position', [2 2 wCm hCm], 'Color', 'w');
try theme(f, 'light'); catch, end  % R2025a+ may default to dark
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
    'DefaultLegendFontName', 'Arial', 'DefaultColorbarFontName', 'Arial', ...
    'DefaultTextInterpreter', 'none', 'DefaultLegendInterpreter', 'none', ...
    'DefaultAxesTickLabelInterpreter', 'none', 'DefaultColorbarTickLabelInterpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, ...
    'TitleFontSizeMultiplier', 9/8, 'TitleFontWeight', 'normal', 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', ...
    'XColor', ink, 'YColor', ink, 'GridColor', [0.88 0.88 0.88], 'GridAlpha', 1, ...
    'Layer', 'bottom');
ax.Title.Color = ink;
ax.Title.Interpreter = 'none'; ax.XLabel.Interpreter = 'none'; ax.YLabel.Interpreter = 'none';
ax.Toolbar.Visible = 'off';
end

function sharedLabels(tl, xl, yl)
ink = [0.15 0.15 0.15];
xlabel(tl, xl, 'FontName', 'Arial', 'FontSize', 9, 'Color', ink, 'Interpreter', 'none');
ylabel(tl, yl, 'FontName', 'Arial', 'FontSize', 9, 'Color', ink, 'Interpreter', 'none');
end

function addPanelLabels(axs)
% Bold lower-case letters at the top-left corner of each axes' tight box
drawnow
for k = 1:numel(axs)
    ax = axs(k);
    u = ax.Units; ax.Units = 'centimeters';
    p = ax.Position; ti = ax.TightInset;
    ax.Units = u;
    text(ax, -(ti(1) + 0.1)/p(3), 1 + (ti(4) + 0.1)/p(4), char('a' + k - 1), 'Units', 'normalized', ...
        'FontName', 'Arial', 'FontSize', 11, 'FontWeight', 'bold', 'Color', [0 0 0], ...
        'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', 'Clipping', 'off');
end
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

function cmap = viridis(n)
anchors = [0.267 0.005 0.329; 0.283 0.141 0.458; 0.254 0.265 0.530; 0.207 0.372 0.553; ...
           0.164 0.471 0.558; 0.128 0.567 0.551; 0.135 0.659 0.518; 0.267 0.749 0.441; ...
           0.478 0.821 0.318; 0.741 0.873 0.150; 0.993 0.906 0.144];
cmap = interp1(linspace(0, 1, size(anchors, 1)), anchors, linspace(0, 1, n));
end
