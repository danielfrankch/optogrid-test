% Analyse OptoGrid current consumption recorded during og_current_test.m (test 1)
% Run from MATLAB (Run button, or `analyse_current_test` from any folder).
% By default it analyses the newest .bin in the recording folders (../session-*/,
% ../device_*/, ...) with that
% session's meta.yml, which supplies the recording settings, the task
% schedule and the stimulation settings.
% Input: WaveForms Scope "Record to File" binary (raw int16 ADC samples, one
% channel, no header) of the voltage across a shunt resistor in series with
% the device, in ../session-N/. The recording starts before
% og_current_test.m runs and ends after it.
% Output: figures and CSV tables in results/<session>/.
%
% Based on pilot-consumption-test/analyse_og_test_1_v2.m:
%  - each LED window starts at that LED's turn-on transient and stops one slot
%    later, just before the next LED's transient (no overlap)
%  - radio events are masked out of every LED window before averaging
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 1-current-consumption-test/
outDir  = fullfile(rootDir, 'results');

% Which recordings to analyse: 'newest' = the most recently written .bin in
% any recording folder; 'all' = the newest .bin of every recording folder.
% Each session's meta.yml is the reference for its recording (file,
% sample_rate_Hz, channel_range_V, channel_offset_V), task schedule
% (schedule_s) and stimulation (period_ms, duration_ms, ramp_down_ms).
whichData = 'newest';

Rshunt = 10;  % shunt resistor (ohm)
nLed   = 64;  % uLEDs fired one after another in each sweep

% Detection / analysis parameters
levelBin      = 10e-3;   % bin for the median current level used to find task edges (s)
levelSmooth   = 0.2;     % moving median over level bins (s)
edgeThr_mA    = 1.0;     % rise above preceding baseline that marks a task start (mA)
imuFallDrop_mA = 1.0;    % IMU streaming ends where the mean level drops this far below its plateau (mA)
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
radioDetThr_mA = 7;      % radio burst detection: this far above the median sweep waveform (mA)
radioDetMinDur = 0.2e-3; % radio burst detection: at least this long (s); shorter = 1 kHz tick
radioPadStim  = 0.1e-3;  % margin either side of each predicted radio burst (s)
ledOnsetFrac  = 0.15;    % turn-on transient starts where it rises 15% of its height above the plateau
ledLead       = 0.02e-3; % LED window starts this long before the transient starts (s)
ledTail       = 0.1e-3;  % LED window ends this long before the next slot's window (s)
darkLedFrac   = 0.3;     % LED current below this fraction of the median LED is flagged as not lighting
ledHistBin_mA = 0.1;     % bin width of the per-LED current histogram (Figure 7)
nRefSweeps    = 10;      % full-amplitude sweeps shown before the ramp-down in Figure 6

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
%% Find recordings
recs = findRecordings(testDir, whichData);
if isempty(recs)
    error('No .bin recordings found in the folders of %s', testDir);
end

for s = 1:numel(recs)
    cfg.name = recs(s).session;
    binFile  = recs(s).bin;
    [~, binName, binExt] = fileparts(binFile);
    cfg.file = [binName binExt];
    metaFile = fullfile(testDir, cfg.name, 'meta.yml');
    if ~isfile(metaFile)
        error('%s has no meta.yml; log the recording settings there first.', cfg.name);
    end
    meta = readMeta(metaFile);
    if isfield(meta, 'file') && ~strcmp(meta.file, cfg.file)
        warning('%s: meta.yml lists %s but the newest recording is %s. Check meta.yml is current.', ...
            cfg.name, meta.file, cfg.file);
    end
    cfg.fs          = metaNum(meta, 'sample_rate_Hz', metaFile);
    cfg.voltsPerDiv = metaNum(meta, 'channel_range_V_per_div', metaFile);
    cfg.rangeV      = metaNum(meta, 'channel_range_V', metaFile);
    cfg.offsetV     = metaNum(meta, 'channel_offset_V', metaFile);

    % Task schedule and stimulation from meta.yml (same as og_current_test.m)
    iti             = metaNum(meta, 'iti', metaFile);
    idleDur         = metaNum(meta, '1_idle', metaFile);
    programDur      = metaNum(meta, '4_program', metaFile);
    triggerDur      = metaNum(meta, '5_stimulation_hold', metaFile);
    nULedChecks     = metaNum(meta, '8_uled_checks', metaFile);
    endIdleDur      = metaNum(meta, '9_end_idle', metaFile);
    stimPeriod_ms   = metaNum(meta, 'period_ms', metaFile);
    stimDuration_ms = metaNum(meta, 'duration_ms', metaFile);
    stimRampDown_ms = metaNum(meta, 'ramp_down_ms', metaFile);

    fprintf('meta.yml: %.3f kHz, %g V/div (Range %.4f V), offset %g V; stimulation %g + %g ms; end idle %g s\n', ...
        cfg.fs/1e3, cfg.voltsPerDiv, cfg.rangeV, cfg.offsetV, stimDuration_ms, stimRampDown_ms, endIdleDur);
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
    % Idle after IMU streaming stays raised, so find the end of streaming from
    % the mean level (streaming bursts lift the mean well above the idle after it)
    [~, levMean] = binStat(i_mA, fs, levelBin, @mean);
    levMeanS = movmedian(levMean, round(levelSmooth/levelBin));
    imuOff = findFall(levT, levMeanS, imuOn, imuFallDrop_mA);

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
        'Pre-connection',      0,             task1Start - 0.5,  false
        'Idle',                task1Start,    task1Start + idleDur, true
        'Status LED',          statusOn,      statusOff,         true
        'Sham LED',            shamOn,        shamOff,           true
        'Program',             programOn,     programOn + programDur, false
        'Stimulation',         stimOn,        stimOff,           false
        'IMU streaming',       imuOn,         imuOff,            true
        'Battery reads',       batteryOn,     batteryOff,        false
        'µLED checks',         uLedOn,        uLedOff,           false
        'Idle (post-IMU)',     uLedOff + 0.5, min(N/fs, uLedOff + endIdleDur), true
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
    AboveIdle_mA = Mean_mA - Mean_mA(Task == "Idle");
    taskTbl = table(Task, tStart, tEnd, Mean_mA, Median_mA, SD_mA, Peak_mA, AboveIdle_mA);
    disp(taskTbl)
    writetable(taskTbl, fullfile(sesDir, 'task_summary.csv'));

    %% Idle: radio on vs off
    idleWin = {
        'Pre-connection',  W{1,2}, W{1,3}
        'Idle',            W{2,2} + edgeTrim, W{2,3} - edgeTrim
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
    nFull = round(stimDuration_ms / stimPeriod_ms);
    nRep  = min(round((stimOff - stimOn) / period), nFull + round(stimRampDown_ms / stimPeriod_ms));
    % Over many sweeps the device clock wanders, so measure where each sweep
    % actually starts against a template (sweepT); stimOn is the fitted start
    [period, stimOn, sweepT] = refineSweepTiming(i_mA, fs, stimOn, period, nRep, nFull, period/nLed);
    slotDur = period / nLed;

    % Refine where the first slot starts: average the full-amplitude sweeps
    % and pick the slot offset that best separates LEDs from each other
    % (median across sweeps, so radio bursts do not shift the result)
    perN = round(period*fs);
    F = zeros(perN, nFull);
    for r = 1:nFull
        k0 = round(sweepT(r)*fs) + 1;
        F(:, r) = double(i_mA(k0 : k0 + perN - 1));
    end
    fold = median(F, 2);
    % Radio bursts: departures well above the median sweep waveform. Used
    % only to find the radio period and phase, not to alter the signal.
    radioEv = detectRadioBursts(F - fold, sweepT(1:nFull), fs, radioDetThr_mA, radioDetMinDur);
    clear F
    radioGrid = fitRadioGrid(radioEv);
    fold = [fold(end-ceil(perN/2)+1:end); fold; fold];  % wrap so shifted slots stay in range
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
    sweepT = sweepT + offsets(o)/fs;
    shamRef = Mean_mA(Task == "Sham LED");  % idle + sham LED, no uLED
    % Locate the LED turn-on transient within the slot: average all slots of
    % the full-amplitude sweeps and find the rising half-height crossing of
    % the transient peak
    tmpN = round(slotDur*fs);
    A = zeros(tmpN, nFull*nLed);
    for r = 1:nFull
        for L = 1:nLed
            k0 = round((sweepT(r) + (L-1)*slotDur)*fs) + 1;
            A(:, (r-1)*nLed + L) = double(i_mA(k0 : k0 + tmpN - 1));
        end
    end
    slotAvg = median(A, 2);   % median across slots: robust to radio bursts
    clear A
    % The transient can straddle the slot boundary, so treat the slot as
    % circular: centre the peak, then walk back to where it starts rising
    [pk, kp] = max(slotAvg);
    sh = round(tmpN/2) - kp;
    c = circshift(slotAvg, sh);
    foot = median(slotAvg) + ledOnsetFrac*(pk - median(slotAvg));
    kOn = find(c(1:round(tmpN/2)) < foot, 1, 'last') + 1;
    if isempty(kOn), kOn = 1; end
    ledOffset = (kOn - 1 - sh)/fs - ledLead;   % LED window start relative to slot start (s)
    ledOffset = mod(ledOffset + slotDur/2, slotDur) - slotDur/2;   % keep within half a slot

    % LED windows: from this LED's transient to just before the next one.
    % A window that overlaps a predicted radio burst (from the radio period
    % and phase) is excluded as a whole; the rest are averaged unchanged.
    slotMean = nan(nLed, nRep);
    preN  = round(ledLead*fs);
    waveN = round((slotDur - ledTail)*fs);   % stop before the next LED's transient begins
    waveSum = zeros(waveN, nLed); waveCnt = zeros(1, nLed);
    contaminated = false(nLed, nRep);
    for r = 1:nRep
        for L = 1:nLed
            ws = sweepT(r) + (L-1)*slotDur + ledOffset;
            contaminated(L, r) = radioOverlaps(radioGrid, ws, ws + waveN/fs, radioPadStim);
            if contaminated(L, r), continue, end
            k0 = round(ws*fs) + 1;
            x = double(i_mA(k0 : k0 + waveN - 1));
            slotMean(L, r) = mean(x);
            if r <= nFull
                waveSum(:, L) = waveSum(:, L) + x;
                waveCnt(L) = waveCnt(L) + 1;
            end
        end
    end
    wave = waveSum ./ max(waveCnt, 1);
    if radioGrid.found
        fprintf(['Radio: %d bursts every %.3f ms (%.0f%% on the grid), %.2f ms long; ' ...
            '%d of %d LED pulses excluded, %d-%d clean sweeps per LED\n'], radioGrid.nEvents, ...
            radioGrid.period*1e3, 100*radioGrid.onGrid, radioGrid.dur*1e3, nnz(contaminated), numel(contaminated), ...
            min(waveCnt), max(waveCnt));
    else
        fprintf('Radio: no periodic bursts found during stimulation; no LED pulses excluded\n');
    end
    fprintf('LED windows start %.3f ms after slot start\n', ledOffset*1e3);
    ledCurrent = slotMean - shamRef;                 % uLED-only current per slot (NaN = excluded)
    LedMean_mA = mean(ledCurrent(:, 1:nFull), 2, 'omitnan');
    LedSD_mA   = std(ledCurrent(:, 1:nFull), 0, 2, 'omitnan');
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
    % Mean-current trace: one level per epoch, except the stimulation, which
    % has one level for the full-amplitude part and then follows the ramp-down
    % as a running mean over one sweep (so the LED-to-LED pattern averages out)
    px = []; py = [];
    tRamp = sweepT(nFull + 1);
    for e = 1:size(ep, 1)
        if ep(e, 4) == stimIdx
            tc1 = (tRamp + period/2 : 10e-3 : ep(e, 2) - period/2)';
            yc  = arrayfun(@(t) mean(double(seg(t - period/2, t + period/2))), tc1);
            fullMean = mean(double(seg(ep(e, 1), tRamp)));
            px = [px; ep(e, 1); tRamp; tc1; ep(e, 2)]; %#ok<AGROW>
            py = [py; fullMean; fullMean; yc; yc(end)]; %#ok<AGROW>
        else
            px = [px; ep(e, 1); ep(e, 2)]; %#ok<AGROW>
            py = [py; ep(e, 3); ep(e, 3)]; %#ok<AGROW>
        end
    end
    f = newFigure(figWidth, 7.5);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.4 1.0 figWidth - 1.9 4.9]);
    hold(ax, 'on')
    yTop = ceil(max(py)) + 1;
    for e = 1:size(ep, 1)
        if ep(e, 4) == 0
            c = intervalColor;
        else
            c = 1 - shadeStrength*(1 - tc(ep(e, 4), :));  % light tint of the task colour
        end
        patch(ax, ep(e, [1 2 2 1]), [0 0 yTop yTop], c, 'EdgeColor', 'none');
    end
    plot(ax, px, py, '-', 'Color', ink, 'LineWidth', 1.25);
    hold(ax, 'off')
    styleAxes(ax);
    ax.Layer = 'top';
    xlim(ax, [0 W{nW,3}]); ylim(ax, [0 yTop]);   % up to the end of the session
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Mean current (mA)');
    % Task names above their epoch, alternating between two rows
    for w = 1:nW
        yRow = 1.03 + 0.11*mod(w + 1, 2);
        if w == nW, xT = W{w,3}; ha = 'right'; else, xT = mean([W{w,2} W{w,3}]); ha = 'center'; end
        lbl = W{w,1};
        if strcmp(lbl, 'Idle (post-IMU)'), lbl = 'Idle'; end   % Figure 1: both idle epochs are 'Idle'
        text(ax, xT, yRow * yTop, lbl, 'HorizontalAlignment', ha, ...
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
    % a: mean +/- s.d. per function, in three groups. s.d. is over time:
    % 100 ms bin means (one-sweep bins for stimulation, which uses its
    % full-amplitude part); for radio events, the spread across events.
    taskWin = @(name) W(strcmp(W(:,1), name), 2:3);
    rowNames = {'Idle', 'Radio event', 'Programming', 'Battery reads', 'µLED checks', ...
        'IMU streaming', 'Status LED', 'Sham LED', 'Stimulation'};
    rowTask  = {'Idle', '', 'Program', 'Battery reads', 'µLED checks', ...
        'IMU streaming', 'Status LED', 'Sham LED', ''};
    rowMean = zeros(9, 1); rowSD = zeros(9, 1);
    for i = 1:9
        if strcmp(rowNames{i}, 'Radio event')
            ev = radio{2}.eventMeans;          % events during the idle period
            rowMean(i) = radio{2}.onMean; rowSD(i) = std(ev);
            continue
        elseif strcmp(rowNames{i}, 'Stimulation')
            t1 = W{stimIdx, 2}; t2 = sweepT(nFull + 1); bin = period;
        else
            tw = taskWin(rowTask{i}); t1 = tw{1} + edgeTrim; t2 = tw{2} - edgeTrim; bin = 0.1;
        end
        x = double(seg(t1, t2));
        n = round(bin*fs); nb = floor(numel(x)/n);
        rowMean(i) = mean(x);
        rowSD(i) = std(mean(reshape(x(1:nb*n), n, nb), 1));
    end
    shamMean = rowMean(strcmp(rowNames, 'Sham LED'));
    yPos = [1 2 3, 4.8 5.8 6.8, 8.6 9.6 10.6];
    barH = 0.7;
    greenSoft   = 1 - 0.45*(1 - tc(strcmp(Task, "IMU streaming"), :));   % IMU colour of Figure 1, lightened
    statusRed   = [0.898 0.549 0.541];
    shamBlue    = [0.600 0.749 0.902];
    trueBlue    = [0.129 0.400 0.675];
    ax1 = nexttile(tl); hold(ax1, 'on')
    for i = 1:9
        y = yPos(i) + [-1 -1 1 1]*barH/2;
        switch rowNames{i}
            case 'Status LED', c = statusRed;
            case 'Sham LED',   c = shamBlue;
            case 'Stimulation', c = trueBlue;
            otherwise,          c = greenSoft;
        end
        if strcmp(rowNames{i}, 'Stimulation')
            patch(ax1, [0 shamMean shamMean 0], y, shamBlue, 'EdgeColor', 'none');
            patch(ax1, [shamMean rowMean(i) rowMean(i) shamMean], y, c, 'EdgeColor', 'none');
        else
            patch(ax1, [0 rowMean(i) rowMean(i) 0], y, c, 'EdgeColor', 'none');
        end
    end
    errorbar(ax1, rowMean, yPos(:), [], [], rowSD, rowSD, 'LineStyle', 'none', ...
        'Color', ink, 'LineWidth', 0.6, 'CapSize', 3);
    xMax = ceil(max(rowMean + rowSD) * 1.2);
    for i = 1:9
        text(ax1, rowMean(i) + rowSD(i) + 0.02*xMax, yPos(i), sprintf('%.2f', rowMean(i)), ...
            'VerticalAlignment', 'middle', 'FontSize', 8, 'Color', ink);
    end
    for yd = [3.9 7.7]
        plot(ax1, [0 xMax], [yd yd], '-', 'Color', [0.8 0.8 0.8], 'LineWidth', 0.5);
    end
    hold(ax1, 'off')
    styleAxes(ax1);
    set(ax1, 'YDir', 'reverse', 'YTick', yPos, 'YTickLabel', rowNames, 'TickLength', [0 0], 'XGrid', 'off');
    xlim(ax1, [0 xMax]); ylim(ax1, [0.4 11.2]);
    xlabel(ax1, 'Current consumption (mA)');
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
    set(ax2, 'XTick', 1:nI, 'XTickLabel', Window, 'YGrid', 'off');
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
        set(ax, 'XTick', 0:1:2, 'YTick', ceil(yl(1)/5)*5 : 5 : yl(2), 'TickLength', [0.03 0.03]);
        xlim(ax, [0 2]); ylim(ax, yl);
        text(ax, 0.04, 0.97, sprintf('%d', L), 'Units', 'normalized', 'FontSize', 8, ...
            'FontWeight', 'bold', 'VerticalAlignment', 'top', 'Color', ink);
        text(ax, 0.96, 0.97, sprintf('%.1f', LedMean_mA(L)), 'Units', 'normalized', 'FontSize', 8, ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'Color', c);
        if mod(L-1, 8) ~= 0, ax.YTickLabel = []; end
        if L <= nLed - 8, ax.XTickLabel = []; end
    end
    sharedLabels(tl, 'Time from LED turn-on (ms)', 'Total current (mA)');
    title(tl, sprintf(['Mean of %d-%d radio-free sweeps per LED. Bold: LED; right: µLED current (mA); ' ...
        'dotted: idle + sham; grey: not lighting.'], min(waveCnt), max(waveCnt)), ...
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
    text(ax2, xl(1)/2, 0.04*yMax, {'Full', 'amplitude'}, 'FontSize', 8, 'Color', ink, ...
        'VerticalAlignment', 'bottom', 'HorizontalAlignment', 'center');
    text(ax2, 0.02*diff(xl), 0.04*yMax, 'Ramp-down', 'FontSize', 8, 'Color', ink, ...
        'VerticalAlignment', 'bottom');
    legend(ax2, [hs hm], {'Per LED slot', 'Sweep mean'}, 'Location', 'northeast', ...
        'Box', 'off', 'FontSize', 8);

    ax3 = nexttile(tl); hold(ax3, 'on')
    sweepNo = rs - nFull;  % <= 0: full amplitude, 1..: ramp sweeps
    patch(ax3, [sweepNo, fliplr(sweepNo)], [sweepMean + sweepSD, fliplr(sweepMean - sweepSD)], ...
        1 - 0.3*(1 - tc(stimIdx, :)), 'EdgeColor', 'none');          % mean ± s.d. band
    plot(ax3, sweepNo, sweepMean, '-', 'Color', tc(stimIdx, :), 'LineWidth', 1.25);
    labelStep = max(1, round(numel(find(sweepNo > 0)) / 5));   % about 5 labels along the ramp
    for k = find(sweepNo > 0 & (mod(sweepNo, labelStep) == 0 | sweepNo == max(sweepNo)))
        text(ax3, sweepNo(k) + 0.03*numel(sweepNo), sweepMean(k), sprintf('%.0f%%', 100*sweepMean(k)/refMean), ...
            'FontSize', 8, 'Color', ink, 'VerticalAlignment', 'bottom');
    end
    hold(ax3, 'off')
    styleAxes(ax3);
    ax3.YGrid = 'on';
    set(ax3, 'XTick', unique([0, labelStep:labelStep:max(sweepNo)]));
    xlim(ax3, [sweepNo(1) - 0.5, sweepNo(end) + 0.15*numel(sweepNo)]); ylim(ax3, [0 yMax]);
    xlabel(ax3, 'Sweep (0 = last full)'); ylabel(ax3, 'Mean µLED current (mA)');
    addPanelLabels([ax1 ax2 ax3]);
    saveFigure(f, fullfile(sesDir, '6_led_summary'));

    %% Figure 7: distribution of per-LED current
    f = newFigure(figWidth/2, 7);
    tl = tiledlayout(f, 1, 1, 'Padding', 'compact');
    ax = nexttile(tl); hold(ax, 'on')
    % Lit LEDs only, x-axis limited to where they are (one bin of margin);
    % LEDs that do not light are reported in the text, not drawn
    lit = LedMean_mA(~Dark);
    lo = (floor(min(lit)/ledHistBin_mA) - 1) * ledHistBin_mA;
    hi = (ceil(max(lit)/ledHistBin_mA) + 1) * ledHistBin_mA;
    edges = lo + (0 : round((hi - lo)/ledHistBin_mA)) * ledHistBin_mA;
    nLit = histcounts(lit, edges);
    bar(ax, edges(1:end-1) + ledHistBin_mA/2, nLit, 1, 'FaceColor', tc(stimIdx, :), ...
        'EdgeColor', 'w', 'LineWidth', 0.5);
    hold(ax, 'off')
    styleAxes(ax);
    ax.YGrid = 'on';
    xlim(ax, [lo hi]); ylim(ax, [0 ceil(max(nLit)*1.3)]);
    xlabel(ax, 'µLED current (mA)'); ylabel(ax, 'LEDs');
    txt = {sprintf('%d lit LEDs', numel(lit)), sprintf('%.2f ± %.2f mA', mean(lit), std(lit))};
    if any(Dark), txt{end+1} = sprintf('%d not lighting (not shown)', nnz(Dark)); end
    text(ax, 0.03, 0.97, txt, 'Units', 'normalized', 'VerticalAlignment', 'top', ...
        'FontSize', 8, 'Color', ink);
    saveFigure(f, fullfile(sesDir, '7_led_distribution'));

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

function tEdge = findFall(levT, levS, tOn, drop)
% First time after tOn that the level drops below halfway between the
% plateau and the level before tOn, or below plateau - drop if given
base = median(levS(levT >= tOn - 1 & levT < tOn - 0.1));
plateau = median(levS(levT >= tOn + 0.5 & levT < tOn + 1.5));
thr = (base + plateau)/2;
if nargin > 3, thr = plateau - drop; end
held = movmin(levS < thr, [0 round(0.5/(levT(2) - levT(1))) - 1]);  % held for 0.5 s
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
allX = []; allM = []; nEv = 0; evLen = []; evMeans = [];
for p = 1:numel(xs)
    m = radioMask(xs{p}, fs, floorLvl, thr, mergeGap, minDur, pad);
    [st, en] = runs(m);
    nEv = nEv + numel(st);
    evMeans = [evMeans; arrayfun(@(i) mean(xs{p}(st(i):en(i))), (1:numel(st))')]; %#ok<AGROW>
    evLen = [evLen; en - st + 1]; %#ok<AGROW>
    allX = [allX; xs{p}(:)]; %#ok<AGROW>
    allM = [allM; m]; %#ok<AGROW>
end
allM = logical(allM);
r.floor = floorLvl;
r.eventMeans = evMeans;            % mean current of each radio event (mA)
r.overallMean = mean(allX);
r.offMean = mean(allX(~allM));
r.onMean = mean(allX(allM));
r.duty = mean(allM);
r.eventRate = nEv / (numel(allX)/fs);
r.eventDur = mean(evLen)/fs;
r.eventCharge_uC = sum(allX(allM) - r.offMean)/fs / max(nEv, 1) * 1e3;  % mA*s = mC
end

function period = estimatePeriod(x, fs, nominal)
% Autocorrelation peak of 0.1 ms-binned current near the nominal period.
% Bins use the minimum, and values above the lit-LED plateau are clipped, so
% radio bursts (0.3-0.6 ms, longer than a bin) cannot dominate. The search
% stays within +/-1% of the programmed period: the device clock is far more
% accurate than that, and multiples of the 7.5 ms radio interval (127.5 and
% 135 ms for a 130 ms sweep) fall outside it.
n = round(1e-4*fs);
nb = floor(numel(x)/n);
y = min(reshape(x(1:nb*n), n, nb), [], 1)';
y = min(y, median(y) + 1);
y = y - mean(y);
binSec = n/fs;
lags = round(0.99*nominal/binSec) : round(1.01*nominal/binSec);
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

function ev = detectRadioBursts(R, t0s, fs, thr, minDur)
% Radio bursts in sweep residuals R (samples x sweeps, signal minus the
% median sweep): runs above thr, gaps < 0.15 ms merged, at least minDur.
% Returns [start time, duration] per burst, sorted by time.
ev = zeros(0, 2);
gapN = round(0.15e-3*fs);
for r = 1:size(R, 2)
    d = diff([false; R(:, r) > thr; false]);
    st = find(d == 1); en = find(d == -1) - 1;
    if isempty(st), continue, end
    keep = [true; st(2:end) - en(1:end-1) > gapN];
    g = cumsum(keep);
    st = st(keep); en = accumarray(g, en, [], @max);
    dur = (en - st + 1)/fs;
    ok = dur >= minDur;
    ev = [ev; t0s(r) + (st(ok) - 1)/fs, dur(ok)]; %#ok<AGROW>
end
ev = sortrows(ev);
end

function radio = fitRadioGrid(ev)
% Radio bursts recur at the connection interval. Find the interval from the
% autocorrelation of the burst train (shortest strong lag), then fit
% t_k = t0 + k*T to the bursts that sit on that grid.
radio = struct('found', false, 'period', NaN, 't0', NaN, 'dur', 0, 'nEvents', size(ev, 1), 'onGrid', 0);
if size(ev, 1) < 10, return, end
t = ev(:, 1);
bw = 0.05e-3;
y = zeros(ceil((t(end) - t(1))/bw) + 1, 1);
y(floor((t - t(1))/bw) + 1) = 1;
lags = round(1e-3/bw) : round(60e-3/bw);
c = zeros(size(lags));
for k = 1:numel(lags), c(k) = sum(y(1:end-lags(k)) .* y(1+lags(k):end)); end
T = lags(find(c >= 0.8*max(c), 1)) * bw;         % shortest lag near the maximum
k = round((t - t(1))/T);
ok = abs(t - t(1) - k*T) < 0.3e-3;
for it = 1:3
    p = polyfit(k(ok), t(ok), 1);
    ok = abs(t - polyval(p, k)) < 0.3e-3;
end
radio.found  = true;
radio.period = p(1);
radio.t0     = p(2);
radio.dur    = prctile(ev(ok, 2), 95);
radio.onGrid = mean(ok);
end

function hit = radioOverlaps(radio, ws, we, pad)
% True if [ws, we] overlaps any predicted radio burst (with margin pad)
hit = false;
if ~radio.found, return, end
k = ceil((ws - radio.dur - pad - radio.t0) / radio.period);   % first burst ending after ws
hit = radio.t0 + k*radio.period - pad < we;
end

function [period, t0, sweepT] = refineSweepTiming(x, fs, t0, period, nSweeps, nFit, slotDur)
% Cross-correlate each sweep with the median of the first sweeps, then fit
% sweep position vs index on the full-amplitude sweeps (nFit). Samples above
% the LED plateau are clipped first, so radio bursts cannot dominate the
% match. Each sweep is searched near the previous one, which stops weak
% (ramp) sweeps jumping by a whole slot.
b = 4;                                   % samples per bin
nb = floor(period*fs/b);
T = zeros(nb, 5);
for r = 1:5, T(:, r) = binMin(x, round((t0 + (r-1)*period)*fs) + 1, nb, b); end
cap = median(T(:)) + 1;                  % just above the lit-LED plateau
tmpl = median(min(T, cap), 2); tmpl = tmpl - mean(tmpl);
n = (0:nSweeps-1)';

% Pass 1: full-amplitude sweeps. The first is searched +/-2 ms; each later
% one around where the previous one was found (the device clock wanders, so
% no straight-line model). A sweep only counts as an outlier if it disagrees
% with its neighbours (running median of 7); outliers take that median.
shift = zeros(nSweeps, 1);
shift(1) = matchShifts(x, fs, t0, period, tmpl, cap, b, nb, 1, 0, 2e-3);
for r = 2:nFit
    centre = shift(r-1);
    sr = matchShifts(x, fs, t0, period, tmpl, cap, b, nb, r, centre, 0.45*slotDur);
    if abs(sr - centre) > 0.4*slotDur, sr = centre; end
    shift(r) = sr;
end
sm = movmedian(shift(1:nFit), 7);
bad = abs(shift(1:nFit) - sm) > 0.2e-3;
shift(bad) = sm(bad);
p = polyfit(n(1:nFit), shift(1:nFit), 1);         % overall period and start
step = median(diff(shift(max(1, nFit-10):nFit))); % recent drift per sweep
% Pass 2: ramp sweeps, tracked the same way. The first ramp sweeps are still
% bright, so they get a wide search: the sweep timing steps about one slot
% earlier when the ramp starts (test 1).
for r = nFit+1:nSweeps
    centre = shift(r-1) + step;
    if r <= nFit + 3, hw = 1.5*slotDur; lim = 1.4*slotDur; else, hw = 0.4*slotDur; lim = 0.35*slotDur; end
    sr = matchShifts(x, fs, t0, period, tmpl, cap, b, nb, r, centre, hw);
    if abs(sr - centre) > lim, sr = centre; end   % hit the search edge: keep tracking
    shift(r) = sr;
end
sweepT = t0 + n*period + shift;
period = period + p(1);
t0 = t0 + p(2);
end

function shift = matchShifts(x, fs, t0, period, tmpl, cap, b, nb, rs, centre, halfWidth)
maxLag = round(halfWidth*fs/b);
shift = zeros(numel(rs), 1);
for i = 1:numel(rs)
    r = rs(i);
    c0 = round(centre(i)*fs/b);
    y = min(binMin(x, round((t0 + (r-1)*period)*fs) + 1 + (c0 - maxLag)*b, nb + 2*maxLag, b), cap);
    c = zeros(2*maxLag + 1, 1);
    for k = 0:2*maxLag
        seg = y(k + (1:nb)); c(k + 1) = sum((seg - mean(seg)) .* tmpl);
    end
    [~, kk] = max(c);
    d = 0;
    if kk > 1 && kk < numel(c)
        d = 0.5*(c(kk-1) - c(kk+1)) / (c(kk-1) - 2*c(kk) + c(kk+1));
    end
    shift(i) = (c0 + kk - 1 - maxLag + d) * b / fs;
end
end

function y = binMin(x, k0, n, b)
y = min(reshape(double(x(k0 : k0 + n*b - 1)), b, n), [], 1)';
end

function meta = readMeta(file)
% Minimal reader for the flat "key: value  # comment" lines of meta.yml.
% Nested sections are flattened; values are returned as strings.
meta = struct();
lines = splitlines(fileread(file));
for i = 1:numel(lines)
    tok = regexp(lines{i}, '^\s*([A-Za-z0-9_]+):\s*(.*)$', 'tokens', 'once');
    if isempty(tok) || isempty(tok{2}), continue, end
    v = regexprep(tok{2}, '\s+#.*$', '');       % drop trailing comment
    v = strtrim(regexprep(v, '^"(.*)"$', '$1'));  % drop surrounding quotes
    meta.(matlab.lang.makeValidName(tok{1})) = v;
end
end

function recs = findRecordings(testDir, which)
% Newest .bin in each recording folder of the test (any subfolder except
% analysis/, e.g. session-1/ or device_<name>/, holding a .bin and meta.yml);
% 'newest' keeps only the overall newest
recs = struct('session', {}, 'bin', {}, 'datenum', {});
d = dir(testDir);
d = d([d.isdir] & ~startsWith({d.name}, '.') & ~strcmp({d.name}, 'analysis'));
for i = 1:numel(d)
    b = dir(fullfile(testDir, d(i).name, '*.bin'));
    if isempty(b), continue, end
    [~, k] = max([b.datenum]);
    recs(end+1) = struct('session', d(i).name, 'bin', fullfile(b(k).folder, b(k).name), ...
        'datenum', b(k).datenum); %#ok<AGROW>
end
if strcmp(which, 'newest') && ~isempty(recs)
    [~, k] = max([recs.datenum]);
    recs = recs(k);
end
end

function v = metaNum(meta, key, metaFile)
% Numeric value from meta.yml; keys starting with a digit get an x prefix
f = matlab.lang.makeValidName(key);
if ~isfield(meta, f) || isnan(str2double(meta.(f)))
    error('%s: numeric "%s" missing', metaFile, key);
end
v = str2double(meta.(f));
end
