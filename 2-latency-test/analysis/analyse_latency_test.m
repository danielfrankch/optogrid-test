% Analyse OptoGrid trigger-to-LED latency (test 2)
% Run from MATLAB (Run button, or `analyse_latency_test` from any folder).
% Input: WaveForms Scope "Record to File" binary with two interleaved
% int16 channels: CH1 = LED signal, CH2 = external trigger pulse from the
% function generator. CH1 is either an optical sensor looking at the LED
% (meta.yml ch1_type: optical) or the voltage across the shunt (ch1_type:
% current). By default the newest .bin in ../session-*/ (or
% ../session-*/data/) is analysed with that session's meta.yml, which
% supplies the sample rate, channel settings and ch1_type.
% The trigger pulse makes the setup send a Bluetooth trigger command to the
% device, so this is the end-to-end trigger-to-light latency:
% latency = first light (CH1 leaves its off level) - start of the trigger
% pulse (CH2 leaves its low level).
% Output: figure and CSV tables in results/<session>/.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);                   % 2-latency-test/
outDir  = fullfile(rootDir, 'results');
whichData = 'newest';   % 'newest' or 'all' (newest .bin of every session)

Rshunt = 10;            % shunt resistor (ohm)

% Detection
triggerFrac  = 0.5;     % trigger pulse found where CH2 crosses this fraction of its high level
startNoiseK  = 5;       % edge start: first departure above baseline + startNoiseK*noise sd ...
startMinFrac = 0.02;    % ... and at least this fraction of the step height
firstStep_V  = 0.05;    % optical: first light is the first step (at least this size) of the
firstLook    = 0.2e-3;  % rising staircase within this long before the main rise (s); background
                        %     light wanders up and down in smaller (~0.05 V) steps
ledOnFrac    = 0.5;     % optical: LED on when CH1 crosses this fraction between its off and on levels
ledOnThr_mA  = 4;       % current: LED on when the current stays above this (mA)
ledHoldTime  = 1e-3;    % ... for at least this long, so ticks, radio bursts and
                        %     ambient-light bumps (< 0.6 ms) are not taken as the LED (s)
maxTraces    = 300;     % trigger-aligned traces drawn in panel a (evenly spread)
searchWindow = 40e-3;   % look for the LED onset up to this long after each trigger (s)

% Figure
binWidth_ms = 0.1;      % histogram bin width (ms)
traceSpan   = [-2 20];  % trigger-aligned trace span (ms)
figWidth    = 18;       % cm
ledColor    = [0.267 0.467 0.667];   % #4477AA, as stimulation in test 1
trigColor   = [0.533 0.133 0.333];   % #882255
ink         = [0.15 0.15 0.15];

%% Find recordings
recs = findRecordings(testDir, whichData);
if isempty(recs)
    error('No .bin recordings found in %s', fullfile(testDir, 'session-*'));
end

for s = 1:numel(recs)
    session = recs(s).session;
    binFile = recs(s).bin;
    metaFile = fullfile(testDir, session, 'meta.yml');
    if ~isfile(metaFile)
        error('%s has no meta.yml; log the recording settings there first.', session);
    end
    meta = readMeta(metaFile);
    [~, binName, binExt] = fileparts(binFile);
    if isfield(meta, 'file') && ~endsWith(meta.file, [binName binExt])
        warning('%s: meta.yml lists %s but the newest recording is %s. Check meta.yml is current.', ...
            session, meta.file, [binName binExt]);
    end
    fs       = metaNum(meta, 'sample_rate_Hz', metaFile);
    nCh      = metaNum(meta, 'channels', metaFile);
    ch1Range = metaNum(meta, 'ch1_range_V_per_div', metaFile);
    ch1Off   = metaNum(meta, 'ch1_offset_V', metaFile);
    ch2Range = metaNum(meta, 'ch2_range_V_per_div', metaFile);
    ch2Off   = metaNum(meta, 'ch2_offset_V', metaFile);
    ch1Type  = 'current';
    if isfield(meta, 'ch1_type'), ch1Type = lower(meta.ch1_type); end
    fprintf('=== %s: %s ===\n', session, [binName binExt]);
    fprintf('meta.yml: %.3f kHz, CH1 (%s) %g V/div offset %g V, CH2 %g V/div offset %g V\n', ...
        fs/1e3, ch1Type, ch1Range, ch1Off, ch2Range, ch2Off);
    sesDir = fullfile(outDir, session);
    if ~isfolder(sesDir), mkdir(sesDir); end

    %% Load
    % Samples are interleaved [C1 C2 ...]. Raw counts are relative to the
    % hardware input range: 5 V full scale up to 500 mV/div, 50 V above.
    fid = fopen(binFile, 'r');
    raw = fread(fid, [nCh inf], 'int16=>double');
    fclose(fid);
    v1   = raw(1, :)' * hwRange(ch1Range)/65536 - ch1Off;   % CH1 (V)
    v_tr = raw(2, :)' * hwRange(ch2Range)/65536 - ch2Off;   % CH2: trigger (V)
    clear raw
    switch ch1Type
        case 'optical'
            sig = v1;  sigUnit = 'V';  sigName = 'Optical sensor';
            mid = (min(sig) + max(sig))/2;
            sigOff = median(sig(sig < mid)); sigOn = median(sig(sig > mid));
            sigThr = sigOff + ledOnFrac*(sigOn - sigOff);
            fprintf('Optical: off %.2f V, on %.2f V, threshold %.2f V\n', sigOff, sigOn, sigThr);
        case 'current'
            sig = v1 / Rshunt * 1e3;  sigUnit = 'mA';  sigName = 'Device current';
            sigThr = ledOnThr_mA;
        otherwise
            error('%s: ch1_type must be optical or current', metaFile);
    end
    clear v1
    N = numel(sig);
    fprintf('%d samples per channel, %.2f s\n', N, N/fs);

    %% Trigger pulse start
    % Find each pulse at half height, then walk back to where CH2 first
    % leaves its low level (sub-sample, linear interpolation).
    vHigh = median(v_tr(v_tr > max(v_tr)/2));
    lowS  = v_tr(v_tr < max(v_tr)/2);
    vLow  = median(lowS);
    thrT  = vLow + triggerFrac*(vHigh - vLow);
    thrT0 = vLow + max(startNoiseK*std(lowS), startMinFrac*(vHigh - vLow));
    k = find(v_tr(1:end-1) < thrT & v_tr(2:end) >= thrT);
    tTrig = zeros(size(k));
    for j = 1:numel(k)
        tTrig(j) = edgeStart(v_tr, k(j) + 1, thrT0) / fs;
    end
    fprintf('%d trigger pulses, %.1f V high, period %.3f ms; start threshold %.3f V\n', ...
        numel(tTrig), vHigh, median(diff(tTrig))*1e3, thrT0);

    %% LED onset (and, for the optical signal, offset) after each trigger
    % The LED is on once CH1 stays above sigThr for ledHoldTime; the forward
    % minimum (min over the next ledHoldTime) crosses the threshold exactly
    % where that sustained level starts. Edges are interpolated between samples.
    % For the optical signal the onset is then moved back to the first light:
    % each flash starts with one or more small steps (~0.1 V, up to ~0.2 ms)
    % before the main rise; first light is the start of the first of them.
    held = movmin(sig, [0 round(ledHoldTime*fs)]);
    tLed = nan(size(tTrig)); tOff = nan(size(tTrig)); tHalf = nan(size(tTrig));
    for j = 1:numel(tTrig)
        k0 = floor(tTrig(j)*fs) + 1;
        k1 = min(N - 1, k0 + round(searchWindow*fs));
        kk = find(held(k0:k1) > sigThr, 1) + k0 - 1;
        if isempty(kk) || kk < 2, continue, end
        kb = kk - 1;
        tHalf(j) = (kb - 1 + (sigThr - sig(kb)) / (sig(kk) - sig(kb))) / fs;   % main rise
        tLed(j) = tHalf(j);
        if strcmp(ch1Type, 'optical')
            lowLevel = sigOff + 0.3*(sigOn - sigOff);
            tLed(j) = firstLight(sig, kk, lowLevel, firstStep_V, round(firstLook*fs)) / fs;
            ke = find(sig(kk:k1) < sigThr, 1) + kk - 1;   % first sample back below
            if ~isempty(ke)
                tOff(j) = (ke - 2 + (sig(ke-1) - sigThr) / (sig(ke-1) - sig(ke))) / fs;
            end
        end
    end
    latency_ms = (tLed - tTrig) * 1e3;
    latencyHalf_ms = (tHalf - tTrig) * 1e3;   % to the main (half-height) rise, for comparison
    flash_ms   = (tOff - tLed) * 1e3;
    ok = ~isnan(latency_ms);
    fprintf('LED onset found for %d of %d triggers\n', nnz(ok), numel(tTrig));
    L = latency_ms(ok);
    stats = struct('n', numel(L), 'mean', mean(L), 'sd', std(L), 'median', median(L), ...
        'min', min(L), 'max', max(L), 'p25', prctile(L, 25), 'p75', prctile(L, 75));
    fprintf('Latency: median %.3f ms, mean %.3f +/- %.3f ms, range %.3f-%.3f ms\n', ...
        stats.median, stats.mean, stats.sd, stats.min, stats.max);
    if any(~isnan(flash_ms))
        fprintf('First light leads the main rise by %.1f us (median); flash duration median %.3f ms\n', ...
            median(latencyHalf_ms - latency_ms, 'omitnan')*1e3, median(flash_ms, 'omitnan'));
    end

    Trigger = (1:numel(tTrig))';
    TriggerStart_s = tTrig; FirstLight_s = tLed; Latency_ms = latency_ms;
    LatencyHalfHeight_ms = latencyHalf_ms; FlashDuration_ms = flash_ms;
    writetable(table(Trigger, TriggerStart_s, FirstLight_s, Latency_ms, LatencyHalfHeight_ms, ...
        FlashDuration_ms), fullfile(sesDir, 'latencies.csv'));
    writetable(struct2table(stats), fullfile(sesDir, 'latency_summary.csv'));

    %% Figure: trigger-aligned traces, latency histogram, latency per trigger
    f = newFigure(figWidth, 14);
    tl = tiledlayout(f, 2, 3, 'TileSpacing', 'loose', 'Padding', 'compact');

    ax1 = nexttile(tl, [1 3]); hold(ax1, 'on')
    w = round(traceSpan(1)*1e-3*fs) : round(traceSpan(2)*1e-3*fs);
    tw = w/fs*1e3;
    show = unique(round(linspace(1, numel(tTrig), min(maxTraces, numel(tTrig)))));
    for j = show
        k0 = round(tTrig(j)*fs) + 1;
        if k0 + w(1) < 1 || k0 + w(end) > N, continue, end
        plot(ax1, tw, sig(k0 + w), '-', 'Color', [ledColor 0.08], 'LineWidth', 0.4);
    end
    if strcmp(sigUnit, 'mA'), yl = [0 ceil(max(sig)/5)*5]; else, yl = [min(0, floor(min(sig))) ceil(max(sig)*2)/2]; end
    plot(ax1, [0 0], yl, '-', 'Color', trigColor, 'LineWidth', 1);
    hold(ax1, 'off')
    styleAxes(ax1);
    xlim(ax1, traceSpan); ylim(ax1, yl);
    xlabel(ax1, 'Time from trigger (ms)'); ylabel(ax1, sprintf('%s (%s)', sigName, sigUnit));
    title(ax1, sprintf('%s, %d of %d trigger-aligned trials (line: trigger start)', sigName, ...
        numel(show), numel(tTrig)), 'FontWeight', 'normal');

    ax2 = nexttile(tl, [1 2]);
    edges = floor(min(L)/binWidth_ms)*binWidth_ms : binWidth_ms : ceil(max(L)/binWidth_ms + 1)*binWidth_ms;
    h = histogram(ax2, L, edges, 'FaceColor', ledColor, 'EdgeColor', 'none', 'FaceAlpha', 1);
    styleAxes(ax2);
    ax2.YGrid = 'on';
    ylim(ax2, [0 ceil(max(h.Values)*1.5)]);   % room for the summary above the bars
    xlabel(ax2, 'Latency (ms)'); ylabel(ax2, 'Trials');
    text(ax2, 0.98, 0.95, {sprintf('n = %d', stats.n), sprintf('median %.2f ms', stats.median), ...
        sprintf('mean %.2f ± %.2f ms', stats.mean, stats.sd), sprintf('range %.2f–%.2f ms', stats.min, stats.max)}, ...
        'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', ...
        'FontSize', 8, 'Color', ink);
    title(ax2, 'Trigger start to first light', 'FontWeight', 'normal');

    ax3 = nexttile(tl);
    plot(ax3, find(ok), L, '.', 'Color', ledColor, 'MarkerSize', 6);
    styleAxes(ax3);
    ax3.YGrid = 'on';
    xlim(ax3, [0 numel(tTrig) + 1]);
    xlabel(ax3, 'Trigger'); ylabel(ax3, 'Latency (ms)');
    title(ax3, 'Latency per trigger', 'FontWeight', 'normal');

    addPanelLabels([ax1 ax2 ax3]);
    saveFigure(f, fullfile(sesDir, 'latency'));
    fprintf('Results saved to %s\n\n', sesDir);
end

%% Local functions
function r = hwRange(voltsPerDiv)
% Hardware full-scale range behind a Scope range setting (10 divisions)
if 10*voltsPerDiv <= 5, r = 5; else, r = 50; end
end

function recs = findRecordings(testDir, which)
% Newest .bin per session-* folder (in the folder or its data/ subfolder);
% 'newest' keeps only the overall newest
recs = struct('session', {}, 'bin', {}, 'datenum', {});
d = dir(fullfile(testDir, 'session-*'));
d = d([d.isdir]);
for i = 1:numel(d)
    b = [dir(fullfile(testDir, d(i).name, '*.bin')); dir(fullfile(testDir, d(i).name, 'data', '*.bin'))];
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

function meta = readMeta(file)
% Minimal reader for the flat "key: value  # comment" lines of meta.yml.
% Nested sections are flattened; values are returned as strings.
meta = struct();
lines = splitlines(fileread(file));
for i = 1:numel(lines)
    tok = regexp(lines{i}, '^\s*([A-Za-z0-9_]+):\s*(.*)$', 'tokens', 'once');
    if isempty(tok) || isempty(tok{2}), continue, end
    v = regexprep(tok{2}, '\s+#.*$', '');
    v = strtrim(regexprep(v, '^"(.*)"$', '$1'));
    meta.(matlab.lang.makeValidName(tok{1})) = v;
end
end

function v = metaNum(meta, key, metaFile)
f = matlab.lang.makeValidName(key);
if ~isfield(meta, f) || isnan(str2double(meta.(f)))
    error('%s: numeric "%s" missing', metaFile, key);
end
v = str2double(meta.(f));
end

function f = newFigure(wCm, hCm)
f = figure('Units', 'centimeters', 'Position', [2 2 wCm hCm], 'Color', 'w');
try theme(f, 'light'); catch, end
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
    'DefaultLegendFontName', 'Arial', 'DefaultTextInterpreter', 'none', ...
    'DefaultLegendInterpreter', 'none', 'DefaultAxesTickLabelInterpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, ...
    'TitleFontSizeMultiplier', 9/8, 'TitleFontWeight', 'normal', 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', ...
    'XColor', ink, 'YColor', ink, 'GridColor', [0.88 0.88 0.88], 'GridAlpha', 1, 'Layer', 'bottom');
ax.Title.Color = ink;
ax.Title.Interpreter = 'none'; ax.XLabel.Interpreter = 'none'; ax.YLabel.Interpreter = 'none';
ax.Toolbar.Visible = 'off';
end

function addPanelLabels(axs)
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
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
try
    exportgraphics(f, [base '.pdf'], 'ContentType', 'vector', 'BackgroundColor', 'white');
catch
    % very many traces can be too much for a vector PDF; embed them as an image
    exportgraphics(f, [base '.pdf'], 'ContentType', 'image', 'Resolution', 300, 'BackgroundColor', 'white');
end
if isvalid(f), close(f); end
end

function t = edgeStart(x, kUp, thr)
% Walk back from sample kUp (on the rising edge) to the last sample at or
% below thr, then interpolate the crossing. Returns the time in samples
% from the start of x (0-based), so divide by fs for seconds.
k = kUp;
while k > 1 && x(k-1) > thr
    k = k - 1;
end
if k == 1, t = 0; return, end
t = (k - 2) + (thr - x(k-1)) / (x(k) - x(k-1));
end

function t = firstLight(x, kUp, lowLevel, stepV, look)
% First light before the main rise at kUp, as a 0-based sample time. Walk
% back from the main rise through the rising staircase: every upward step
% (>= stepV) onto a level that holds for at least 4 samples is part of the
% flash; stop at a downward step (background light) or after `look` samples.
% First light is the start of the earliest step found.
kMain = kUp;
while kMain > 1 && x(kMain) > lowLevel, kMain = kMain - 1; end
ks = [];
k = kMain - 3;
while k >= max(6, kMain - look)
    flat = max(x(k:k+3)) - min(x(k:k+3)) < stepV/2;     % a level, not part of a rise
    dx = x(k) - median(x(k-4:k-2));
    if flat && dx >= stepV
        ks = k; k = k - 4;                              % step up: keep walking back
    elseif dx <= -stepV
        break                                           % step down: background, stop
    else
        k = k - 1;
    end
end
if isempty(ks)                      % no pre-step: use the start of the main rise
    t = edgeStart(x, kMain + 1, x(kMain) + stepV/2);
    return
end
lower = median(x(ks-5:ks-2));
upper = median(x(ks:min(ks+3, kMain)));
t = edgeStart(x, ks, lower + 0.2*(upper - lower));
end
