% Plot WaveForms scope recordings of the capacitor bank voltage after the
% DC supply is unplugged (test 3). The device and bank run from a DC
% supply; the supply pins are pulled by hand mid-recording.
% Input: raw WaveForms "Record to File" .bin (little-endian int16, one
% channel, no header) in ../device_<name>/, with its settings in
% <recording>.meta.yml (sample_rate_Hz, channel_range_V, channel_offset_V).
% Volts = Range*Sample/65536 - Offset, with Range and Offset the exact
% channel values WaveForms reports. The manual writes + Offset, but then the
% powered level of DC_5.0V_CapBank_Test_1 reads 1.00 V on a 5.0 V supply;
% with the offset subtracted it reads 5.00 V (see CLAUDE.md).
% Figure: a) the whole recording (1 ms min-max envelope and 10 ms mean);
% b) the unplug and c) the final drop (or the end of the recording if the
% device is still running), at full rate.
% The powered level is checked against supply_V in the meta file; a large
% mismatch usually means a wrong Range or Offset there.
% Output: results/<recording folder>/<recording>.png
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
recFolder = 'device_LRV-O-0001';
recFiles  = {};       % recordings to plot; {} = every *CapBank*.bin in recFolder
envWin_s  = 1e-3;     % envelope bin (s)
meanWin_s = 10e-3;    % running mean (s)
zoomPre_s = 0.02;     % zoom panels: time before the event (s)
zoomPost_s = 0.1;     % zoom panels: time after the event (s)
unplugDrop_V = 0.05;  % unplug: 1 ms mean this far below the powered level
collapseDrop_V = 0.3; % final drop: the top of the trace (1 ms max, ignoring the radio dips)
                      % falls this much below the preceding 0.1 s and stays down for collapseHold_s
supplyTol    = 0.05;  % warn if the powered level is off supply_V by more than this fraction
collapseHold_s = 1;

figWidth = 18;                       % cm
ink      = [0.15 0.15 0.15];
envColor = [0.75 0.75 0.75];
lineColor = [0.27 0.47 0.67];

%% Recordings
if isempty(recFiles)
    d = dir(fullfile(testDir, recFolder, '*CapBank*.bin'));
    recFiles = {d.name};
end
for r = 1:numel(recFiles)
    recFile = recFiles{r};
    %% Load
    [~, base] = fileparts(recFile);
    metaFile = fullfile(testDir, recFolder, [base '.meta.yml']);
    meta = readMeta(metaFile);
    fs = metaNum(meta, 'sample_rate_Hz', metaFile);
    range_V = metaNum(meta, 'channel_range_V', metaFile);
    offset_V = metaNum(meta, 'channel_offset_V', metaFile);
    fid = fopen(fullfile(testDir, recFolder, recFile), 'r', 'ieee-le');
    raw = fread(fid, inf, 'int16=>double');
    fclose(fid);
    v = range_V*raw/65536 - offset_V;
    n = numel(v); t = (0:n-1)'/fs;
    fprintf('%s: %d samples, %.2f s at %g kHz, %.3f to %.3f V\n', recFile, n, n/fs, fs/1e3, min(v), max(v));

    %% Events
    nb = floor(envWin_s*fs); nB = floor(n/nb);
    vb = reshape(v(1:nB*nb), nb, nB);
    bMean = mean(vb)'; bMin = min(vb)'; bMax = max(vb)'; tb = ((0:nB-1)' + 0.5)*envWin_s;
    vPow = median(bMean(1:round(0.5/envWin_s)));              % powered level, first 0.5 s
    iUn  = find(bMean < vPow - unplugDrop_V, 1);
    tUn  = tb(iUn) - envWin_s/2;
    nHold = round(collapseHold_s/envWin_s); nPre = round(0.1/envWin_s);
    topPre = movmax(bMax, [nPre 0]); topNext = movmax(bMax, [1 nHold]);
    iCol = find(topNext < [topPre(1); topPre(1:end-1)] - collapseDrop_V & tb > tUn + 0.1, 1);
    hasCol = ~isempty(iCol);
    tCol = NaN; if hasCol, tCol = tb(iCol) - envWin_s/2; end
    vMean = movmean(v, round(meanWin_s*fs));
    after = @(t0, dt) median(v(t >= t0 + dt - 0.005 & t < t0 + dt + 0.005));
    fprintf('Powered %.3f V; unplugged at %.3f s; %.3f V 50 ms later\n', vPow, tUn, after(tUn, 0.05));
    if isfield(meta, 'supply_V')
        sup = str2double(meta.supply_V);
        fprintf('Powered level is %.1f%% of the %.2f V supply\n', 100*vPow/sup, sup);
        if abs(vPow/sup - 1) > supplyTol
            warning('%s: powered level %.3f V vs supply %.2f V; check channel_range_V and channel_offset_V.', ...
                recFile, vPow, sup);
        end
    end
    % ripple after the unplug: spacing of the dips in the first 2 s
    seg = v(t >= tUn + 0.1 & t < min([tCol, tUn + 2.1], [], 'omitnan'));
    segT = (0:numel(seg)-1)'/fs;
    thr = median(seg) - 0.1;
    dipT = segT([false; seg(2:end) < thr & seg(1:end-1) >= thr]);
    if ~isempty(dipT), dipT = dipT([true; diff(dipT) > 0.3e-3]); end
    deepThr = median(seg) - 0.8;
    deep = segT([false; seg(2:end) < deepThr & seg(1:end-1) >= deepThr]);
    if ~isempty(deep), deep = deep([true; diff(deep) > 0.01]); end
    fprintf('Ripple dips every %.2f ms (%d); deep dips (0.8 V below the median) every %.0f ms (%d)\n', ...
        1000*median(diff(dipT)), numel(dipT), 1000*median(diff(deep)), numel(deep));
    if hasCol
        fprintf('Collapse at %.3f s (%.2f s after unplugging), from %.3f V to %.3f V\n', tCol, tCol - tUn, ...
            after(tCol, -0.05), after(tCol, 0.5));
    else
        fprintf('No collapse: still running at the end, %.3f V (10 ms mean) %.2f s after unplugging\n', ...
            mean(v(end - round(0.01*fs):end)), t(end) - tUn);
    end

    %% Figure
    f = figure('Units', 'centimeters', 'Position', [2 2 figWidth 12], 'Color', 'w');
    try theme(f, 'light'); catch, end
    set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
        'DefaultTextInterpreter', 'none', 'DefaultAxesTickLabelInterpreter', 'none');
    yl = [0 ceil(max(v)*2)/2 + 0.5];
    % a: whole recording
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 6.9 figWidth - 2.1 4.4]); hold(ax, 'on')
    patch(ax, [tb; flipud(tb)], [bMin; flipud(bMax)], envColor, 'EdgeColor', 'none');
    k = 1:round(meanWin_s*fs/4):n;
    plot(ax, t(k), vMean(k), '-', 'Color', lineColor, 'LineWidth', 1);
    xline(ax, tUn, ':', 'Color', ink);
    text(ax, tUn, yl(2), ' unplugged', 'VerticalAlignment', 'top', 'FontSize', 7, 'Color', ink);
    if hasCol
        xline(ax, tCol, ':', 'Color', ink);
        text(ax, tCol, yl(2), sprintf(' collapse (+%.2f s)', tCol - tUn), 'VerticalAlignment', 'top', ...
            'FontSize', 7, 'Color', ink);
    else
        text(ax, t(end), yl(2), sprintf('still running %.1f s after unplugging ', t(end) - tUn), ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 7, 'Color', ink);
    end
    hold(ax, 'off'); styleAx(ax, ink);
    xlim(ax, [0 t(end)]); ylim(ax, yl);
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Voltage (V)');
    text(ax, -0.07, 1.06, 'a', 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', ink);
    % b, c: zooms at full rate
    ev = [tUn tCol]; lab = {'b', 'c'}; ttl = {'Unplug', 'Collapse'};
    win = repmat([-zoomPre_s zoomPost_s], 2, 1);
    if ~hasCol, ev(2) = t(end); ttl{2} = 'End of recording'; win(2, :) = [-(zoomPre_s + zoomPost_s) 0]; end
    w = (figWidth - 4.2)/2;
    for j = 1:2
        ax = axes(f, 'Units', 'centimeters', 'Position', [1.6 + (j - 1)*(w + 2.1) 1.1 w 4.0]); hold(ax, 'on')
        m = t >= ev(j) + win(j, 1) & t <= ev(j) + win(j, 2);
        plot(ax, 1000*(t(m) - ev(j)), v(m), '-', 'Color', lineColor, 'LineWidth', 0.5);
        hold(ax, 'off'); styleAx(ax, ink);
        xlim(ax, 1000*win(j, :)); ylim(ax, yl);
        xlabel(ax, sprintf('Time from %s (ms)', lower(ttl{j}))); ylabel(ax, 'Voltage (V)');
        title(ax, ttl{j}, 'FontWeight', 'normal');
        text(ax, -0.18, 1.06, lab{j}, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', ink);
    end
    outDir = fullfile(rootDir, 'results', recFolder);
    if ~isfolder(outDir), mkdir(outDir); end
    exportgraphics(f, fullfile(outDir, [base '.png']), 'Resolution', 300, 'BackgroundColor', 'white');
    fprintf('Saved %s\n', fullfile(outDir, [base '.png']));
    close(f);
end

function styleAx(ax, ink)
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, ...
    'TitleFontSizeMultiplier', 9/8, 'LineWidth', 0.5, 'TickDir', 'out', 'TickLength', [0.01 0.01], ...
    'Box', 'off', 'Color', 'w', 'XColor', ink, 'YColor', ink);
ax.Toolbar.Visible = 'off';
end

function meta = readMeta(file)
% Minimal reader for the flat "key: value  # comment" lines of meta.yml
meta = struct();
lines = splitlines(fileread(file));
for i = 1:numel(lines)
    tok = regexp(lines{i}, '^\s*([A-Za-z0-9_]+):\s*(.*)$', 'tokens', 'once');
    if isempty(tok) || isempty(tok{2}), continue, end
    v = regexprep(tok{2}, '\s+#.*$', '');
    meta.(matlab.lang.makeValidName(tok{1})) = strtrim(regexprep(v, '^"(.*)"$', '$1'));
end
end

function v = metaNum(meta, key, metaFile)
f = matlab.lang.makeValidName(key);
if ~isfield(meta, f) || isnan(str2double(meta.(f))), error('%s: numeric "%s" missing', metaFile, key); end
v = str2double(meta.(f));
end
