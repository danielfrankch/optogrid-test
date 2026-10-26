% Compare the device's own battery reads (BLE) with the oscilloscope trace
% of the same node, recorded at the same time (test 3.2c, DC hold-up).
% The bank and device run from a DC supply; the supply pins are pulled
% by hand. The scope records the voltage continuously (WaveForms .bin,
% settings in <recording>.meta.yml, converted as in plot_dc_cut_scope.m:
% Volts = Range*Sample/65536 - Offset). og_holdup_ble_log.m logs the device's
% battery reads over Bluetooth (<date_time>_dc-cut_ble*.mat, t_s = time the
% read was sent, PC clock). Recordings: ../device_<name>/2c-dc-cut-scope-and-ble/;
% each <date_time>_dc-cut_*_scope.bin names its BLE log in its .meta.yml
% (ble_log).
% Alignment: the supply cut-off in both. Scope: the first 1 ms mean more than
% unplugDrop_V below the powered level. BLE: halfway between the last
% powered read and the first read more than offDrop_V below it. The BLE
% times are shifted onto the scope clock by the difference. The scope
% collapse against the last good BLE read checks the alignment at the end.
% Each read is a round trip, so the device samples its ADC somewhere between
% sending (t_s) and the next read; per read the scope is summarised over that
% window (mean, minimum) and at its middle (running mean over runWin_s).
% Figure 1: a) both over the whole recording; b) the first second after the
%           cut-off at full scope rate, with each BLE read drawn across its
%           window; c) BLE minus the scope (running mean, window mean,
%           window minimum).
% Figure 2: BLE against the scope window mean and window minimum, and the
%           calibration curve.
% Calibration: during the hold-up (bank only, device idling, reads at the
% og_holdup_ble_log.m rate) each BLE read is mapped to the scope running mean
% over runWin_s at the read: the reads are binned by BLE value (calBin_V)
% and the median running mean of each bin is saved, with the bin count, in
% calibration_readbattery_wpt.csv next to this script (only with
% saveCalibration = true, from the calSource pair). It applies to BLE reads taken with no external
% supply (WPT off) only; with WPT or DC on the radio dips are shallower and
% the reads need no or a different correction. The saved calibration came
% from 20261013_190812_dc-cut_5.0V_scope.bin + 20261013_190715_dc-cut_5.0V_ble.mat (no added
% capacitor); Figure 2 always draws the saved file for comparison.
% Output: PNG figures and a per-read table in results/device_<name>/2c-dc-cut-scope-and-ble/,
% named after the scope recording: _ble_vs_scope.png, _ble_vs_scope_scatter.png,
% _ble_vs_scope.csv; calibration_readbattery_wpt.csv in analysis/ (if saved).
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
recFolder = 'device_LRV-O-0001';
subTest   = '2c-dc-cut-scope-and-ble';   % recordings in ../<recFolder>/<subTest>/
whichData = 'newest';   % 'newest' or 'every' scope recording (*_scope.bin) in subTest
calSource = '20261013_190812_dc-cut_5.0V_scope.bin';   % pair the saved calibration comes from (no added capacitor)
saveCalibration = false;  % true: overwrite calFile from the calSource pair

envWin_s     = 1e-3;   % scope envelope bin (s)
meanWin_s    = 10e-3;  % scope short running mean (s)
runWin_s     = 1;      % scope running average compared with the BLE reads (s)
maxReadWin_s = 0.2;    % longest read window (s): to the next read, at most this
baseline_s   = 1;      % powered level: first baseline_s of each recording
unplugDrop_V = 0.05;   % scope: 1 ms mean this far below powered marks the cut-off
offDrop_V    = 0.5;    % BLE: reads this far below powered count as unpowered
collapseFrac = 0.5;    % scope collapse: below this fraction of powered for collapseHold_s
collapseHold_s = 0.05;
zoom_s       = [-0.1 1];   % Figure 1b window around the cut-off (s)
calBin_V     = 0.05;   % calibration: BLE bin width (V)
calMinN      = 3;      % calibration: bins with fewer reads are left out
calFile      = 'calibration_readbattery_wpt.csv';   % written next to this script

figWidth  = 18;                      % cm
ink       = [0.15 0.15 0.15];
envColor  = [0.78 0.78 0.78];
scopeColor = [0.27 0.47 0.67];
runColor  = [0.13 0.27 0.53];
bleColor  = [0.80 0.40 0.47];

%% Find the recordings
recDir = fullfile(testDir, recFolder, subTest);
d = dir(fullfile(recDir, '*_scope.bin'));
scopeFiles = sort({d.name});
if isempty(scopeFiles), error('No *_scope.bin in %s', recDir); end
if strcmp(whichData, 'newest'), scopeFiles = scopeFiles(end); end
outDir = fullfile(rootDir, 'results', recFolder, subTest);
if ~isfolder(outDir), mkdir(outDir); end

for r = 1:numel(scopeFiles)
    scopeFile = scopeFiles{r};
    %% Load the scope recording
    [~, base] = fileparts(scopeFile);
    metaFile = fullfile(recDir, [base '.meta.yml']);
    meta = readMeta(metaFile);
    fs = metaNum(meta, 'sample_rate_Hz', metaFile);
    range_V = metaNum(meta, 'channel_range_V', metaFile);
    offset_V = metaNum(meta, 'channel_offset_V', metaFile);
    fid = fopen(fullfile(recDir, scopeFile), 'r', 'ieee-le');
    raw = fread(fid, inf, 'int16=>double');
    fclose(fid);
    v = range_V*raw/65536 - offset_V; clear raw
    n = numel(v); t = (0:n-1)'/fs;
    fprintf('=== Scope %s: %.2f s at %g kHz\n', scopeFile, n/fs, fs/1e3);
    if ~isfield(meta, 'ble_log'), error('%s: no ble_log', metaFile); end
    bleFile = meta.ble_log;

    nb = floor(envWin_s*fs); nB = floor(n/nb);
    vb = reshape(v(1:nB*nb), nb, nB);
    bMean = mean(vb)'; bMin = min(vb)'; bMax = max(vb)'; tb = ((0:nB-1)' + 0.5)*envWin_s;
    vPowS = median(bMean(tb <= baseline_s));
    iUn = find(bMean < vPowS - unplugDrop_V, 1);
    tUnS = tb(iUn) - envWin_s/2;
    nHold = round(collapseHold_s/envWin_s);
    iCol = find(movmax(bMean, [0 nHold - 1]) < collapseFrac*vPowS & tb > tUnS, 1);
    tColS = NaN; if ~isempty(iCol), tColS = tb(iCol) - envWin_s/2; end
    vShort = movmean(v, round(meanWin_s*fs));
    vRun = movmean(v, round(runWin_s*fs));
    fprintf('Scope: powered %.3f V, cut-off at %.3f s, collapse at %.3f s (%.2f s later)\n', ...
        vPowS, tUnS, tColS, tColS - tUnS);

    %% Load the BLE reads and align them
    L = load(fullfile(recDir, bleFile), 'wpt_holdup_df');
    df = L.wpt_holdup_df;
    tB = df.t_s; vB = df.bat_mv/1000; okB = df.ok;
    vPowB = median(vB(okB & tB <= tB(1) + baseline_s));
    low = okB & vB < vPowB - offDrop_V;
    iLastB = find(okB, 1, 'last');
    iPowB = find(okB & ~low & (1:numel(vB))' < find(low, 1), 1, 'last');
    iOffB = find(low, 1);
    tOffB = (tB(iPowB) + tB(iOffB))/2;
    shift = tUnS - tOffB;                            % BLE time + shift = scope time
    tBs = tB + shift;
    fprintf('BLE: powered %.3f V, cut-off at %.3f s (reads %.2f s apart there); shift %+.3f s\n', ...
        vPowB, tOffB, tB(iOffB) - tB(iPowB), shift);
    fprintf('Check at the end: last good BLE read %.3f s, first failed %.3f s, scope collapse %.3f s\n', ...
        tBs(iLastB), tBs(find(~okB & tB > tB(iLastB), 1)), tColS);

    %% Scope around each BLE read
    nR = numel(tB);
    winEnd = [tBs(2:end); tBs(end) + maxReadWin_s];
    winEnd = min(winEnd, tBs + maxReadWin_s);
    ScopeRun_V = nan(nR, 1); ScopeMean_V = ScopeRun_V; ScopeMin_V = ScopeRun_V; ScopeMax_V = ScopeRun_V;
    for i = 1:nR
        a = max(1, round(tBs(i)*fs) + 1); b = min(n, round(winEnd(i)*fs));
        if b <= a, continue, end
        w = v(a:b);
        ScopeMean_V(i) = mean(w); ScopeMin_V(i) = min(w); ScopeMax_V(i) = max(w);
        ScopeRun_V(i) = vRun(round((a + b)/2));
    end
    phase = repmat("powered", nR, 1);
    phase(tBs >= tUnS) = "hold-up";
    if ~isnan(tColS), phase(tBs >= tColS) = "collapsed"; end
    phase(~okB) = "failed";
    Read = (1:nR)'; Time_s = tBs; BLE_V = vB; BLE_V(~okB) = NaN; Phase = phase;
    tbl = table(Read, Time_s, Phase, BLE_V, ScopeRun_V, ScopeMean_V, ScopeMin_V, ScopeMax_V);
    [~, sBase] = fileparts(scopeFile);
    writetable(tbl, fullfile(outDir, [sBase '_ble_vs_scope.csv']));

    %% Calibration: BLE read (bank only) -> running-mean bank voltage
    if saveCalibration && strcmp(scopeFile, calSource)
        m = phase == "hold-up" & okB & ~isnan(ScopeRun_V);
        edges = (floor(min(vB(m))/calBin_V):ceil(max(vB(m))/calBin_V))*calBin_V;
        bin = discretize(vB(m), edges);
        cBLE = (edges(1:end-1) + calBin_V/2)';
        cActual = accumarray(bin, ScopeRun_V(m), [numel(cBLE) 1], @median, NaN);
        cBLEmed = accumarray(bin, vB(m), [numel(cBLE) 1], @median, NaN);
        cN = accumarray(bin, 1, [numel(cBLE) 1]);
        keep = cN >= calMinN;
        calTbl = table(cBLEmed(keep), cActual(keep), cN(keep), 'VariableNames', {'BLE_V', 'Actual_V', 'N'});
        writetable(calTbl, fullfile(rootDir, calFile));
        pLin = polyfit(vB(m), ScopeRun_V(m), 1);
        resid = ScopeRun_V(m) - interp1(calTbl.BLE_V, calTbl.Actual_V, vB(m), 'linear', 'extrap');
        fprintf('Calibration (%d bins, %d reads, BLE %.2f-%.2f V): rms error %.3f V; linear fit Actual = %.4f*BLE %+.4f\n', ...
            height(calTbl), nnz(m), min(calTbl.BLE_V), max(calTbl.BLE_V), rms(resid), pLin(1), pLin(2));
        fprintf('Saved %s\n', fullfile(rootDir, calFile));
    end
    calTbl = readtable(fullfile(rootDir, calFile));   % saved calibration, drawn in Figure 2
    for ph = ["powered", "hold-up"]
        m = phase == ph;
        fprintf('%-8s (%3d reads) BLE - scope: running mean %+.3f V, window mean %+.3f V, window min %+.3f V (median)\n', ...
            ph, nnz(m), median(BLE_V(m) - ScopeRun_V(m), 'omitnan'), median(BLE_V(m) - ScopeMean_V(m), 'omitnan'), ...
            median(BLE_V(m) - ScopeMin_V(m), 'omitnan'));
    end

    %% Figure 1: aligned traces
    f = newFigure(figWidth, 15);
    yl = [0 ceil(max(v)*2)/2 + 0.5];
    tEnd = max(t(end), tBs(end));
    % a: whole recording
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 10.3 figWidth - 2.1 4.0]); hold(ax, 'on')
    patch(ax, [tb; flipud(tb)], [bMin; flipud(bMax)], envColor, 'EdgeColor', 'none', 'DisplayName', 'Scope, 1 ms min-max');
    k = 1:round(meanWin_s*fs/4):n;
    plot(ax, t(k), vShort(k), '-', 'Color', scopeColor, 'LineWidth', 0.75, 'DisplayName', ...
        sprintf('Scope, %g ms mean', meanWin_s*1e3));
    plot(ax, t(k), vRun(k), '-', 'Color', runColor, 'LineWidth', 1.5, 'DisplayName', ...
        sprintf('Scope, %g s running mean', runWin_s));
    plot(ax, tBs(okB), vB(okB), '.', 'Color', bleColor, 'MarkerSize', 6, 'DisplayName', 'BLE battery read');
    xline(ax, tUnS, ':', 'Color', ink, 'HandleVisibility', 'off');
    if ~isnan(tColS), xline(ax, tColS, ':', 'Color', ink, 'HandleVisibility', 'off'); end
    for i = find(~okB)'
        xline(ax, tBs(i), '-', 'Color', bleColor, 'LineWidth', 0.5, 'HandleVisibility', 'off');
    end
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, [0 tEnd]); ylim(ax, yl);
    xlabel(ax, 'Time (s, scope clock)'); ylabel(ax, 'Voltage (V)');
    legend(ax, 'Location', 'southwest', 'Box', 'off', 'FontSize', 6, 'NumColumns', 2);
    panelLetter(ax, 'a');
    % b: first second after the cut-off at full rate
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 5.6 figWidth - 2.1 3.6]); hold(ax, 'on')
    m = t >= tUnS + zoom_s(1) & t <= tUnS + zoom_s(2);
    plot(ax, 1000*(t(m) - tUnS), v(m), '-', 'Color', scopeColor, 'LineWidth', 0.4);
    plot(ax, 1000*(t(m) - tUnS), vRun(m), '-', 'Color', runColor, 'LineWidth', 1.5);
    for i = find(okB & tBs >= tUnS + zoom_s(1) & tBs <= tUnS + zoom_s(2))'
        plot(ax, 1000*([tBs(i) winEnd(i)] - tUnS), vB(i)*[1 1], '-', 'Color', bleColor, 'LineWidth', 2);
    end
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, 1000*zoom_s); ylim(ax, yl);
    xlabel(ax, 'Time from the supply cut-off (ms)'); ylabel(ax, 'Voltage (V)');
    text(ax, 0.99, 0.95, 'red bars: BLE reads across their read window', 'Units', 'normalized', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 6, 'Color', ink);
    panelLetter(ax, 'b');
    % c: BLE minus scope
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 1.0 figWidth - 2.1 3.6]); hold(ax, 'on')
    okP = okB & phase ~= "failed";
    plot(ax, tBs(okP), vB(okP) - ScopeRun_V(okP), '.', 'Color', runColor, 'MarkerSize', 6, ...
        'DisplayName', sprintf('vs %g s running mean', runWin_s));
    plot(ax, tBs(okP), vB(okP) - ScopeMean_V(okP), '.', 'Color', scopeColor, 'MarkerSize', 6, ...
        'DisplayName', 'vs read-window mean');
    plot(ax, tBs(okP), vB(okP) - ScopeMin_V(okP), '.', 'Color', bleColor, 'MarkerSize', 6, ...
        'DisplayName', 'vs read-window minimum');
    yline(ax, 0, '-', 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    xline(ax, tUnS, ':', 'Color', ink, 'HandleVisibility', 'off');
    if ~isnan(tColS), xline(ax, tColS, ':', 'Color', ink, 'HandleVisibility', 'off'); end
    hold(ax, 'off'); styleAxes(ax);
    xlim(ax, [0 tEnd]);
    xlabel(ax, 'Time (s, scope clock)'); ylabel(ax, 'BLE - scope (V)');
    legend(ax, 'Location', 'east', 'Box', 'off', 'FontSize', 6);
    panelLetter(ax, 'c');
    saveFigure(f, fullfile(outDir, [sBase '_ble_vs_scope']));

    %% Figure 2: BLE against the scope during the hold-up
    f = newFigure(figWidth/2, 8);
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.2 figWidth/2 - 2.0 6.2]); hold(ax, 'on')
    m = phase == "hold-up" | phase == "powered";
    lims = [floor(min([vB(m); ScopeMin_V(m)])*2)/2, ceil(max([vB(m); ScopeMax_V(m)])*2)/2];
    plot(ax, lims, lims, '-', 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    plot(ax, ScopeMean_V(m), vB(m), '.', 'Color', scopeColor, 'MarkerSize', 7, 'DisplayName', 'vs read-window mean');
    plot(ax, ScopeMin_V(m), vB(m), '.', 'Color', bleColor, 'MarkerSize', 7, 'DisplayName', 'vs read-window minimum');
    plot(ax, calTbl.Actual_V, calTbl.BLE_V, '-', 'Color', ink, 'LineWidth', 1, ...
        'DisplayName', sprintf('Calibration, %s (vs %g s running mean)', calFile, runWin_s));
    hold(ax, 'off'); styleAxes(ax); axis(ax, 'equal');
    xlim(ax, lims); ylim(ax, lims);
    xlabel(ax, 'Scope (V)'); ylabel(ax, 'BLE battery read (V)');
    legend(ax, 'Location', 'northwest', 'Box', 'off', 'FontSize', 6);
    saveFigure(f, fullfile(outDir, [sBase '_ble_vs_scope_scatter']));
    fprintf('Results saved to %s\n', outDir);
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

function x = metaNum(meta, key, metaFile)
fn = matlab.lang.makeValidName(key);
if ~isfield(meta, fn) || isnan(str2double(meta.(fn))), error('%s: numeric "%s" missing', metaFile, key); end
x = str2double(meta.(fn));
end

function panelLetter(ax, s)
text(ax, -0.07, 1.08, s, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', ...
    'Color', [0.15 0.15 0.15]);
end

function f = newFigure(wCm, hCm)
f = figure('Units', 'centimeters', 'Position', [2 2 wCm hCm], 'Color', 'w');
try theme(f, 'light'); catch, end
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
    'DefaultTextInterpreter', 'none', 'DefaultAxesTickLabelInterpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, ...
    'TitleFontSizeMultiplier', 9/8, 'TitleFontWeight', 'normal', 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', ...
    'XColor', ink, 'YColor', ink);
ax.Toolbar.Visible = 'off';
end

function saveFigure(f, base)
exportgraphics(f, [base '.png'], 'Resolution', 300, 'BackgroundColor', 'white');
close(f);
end
