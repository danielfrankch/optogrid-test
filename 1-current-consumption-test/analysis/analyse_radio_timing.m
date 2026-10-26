% Radio event timing of the OptoGrid BLE connection (test 1 shunt recordings)
% Run from MATLAB (Run button, or `analyse_radio_timing` from any folder).
% Input: the test 1 WaveForms recording of each device (../device_<name>/,
% settings in its meta.yml: sample rate, Range, Offset; 10 ohm shunt).
% Each connection event has two current peaks:
%   small peak: about 8 mA for about 0.25 ms, then a 0.3 mA plateau, about
%               1.55 ms before the large peak (most likely the wake-up before
%               the event: CPU and high-frequency crystal start-up)
%   large peak: two about 12.5 mA humps and a 7-8 mA tail, about 0.37 ms in
%               all (most likely the radio exchange, receive then transmit,
%               then the stack's post-processing)
% The narrow 10 mA spikes every 0.975 ms are the 1 kHz firmware tick.
% Large peaks: 50 us mean more than largeThr_mA above the 10 ms floor for at
% least largeMin_s (gaps under 300 us merged); timed where that mean crosses
% the threshold (interpolated between samples); panel b is aligned on the
% first sample more than onsetThr_mA above the floor. The connection grid is followed
% from peak to peak: a peak within gridTol_s of last + k*T continues it
% (k - 1 events without a detected exchange); a new grid starts where four
% peaks in a row are T apart again. T is fitted on the longest unbroken run.
% Figure (8_radio_timing): a) 25 ms of connected idle; b) one connection
% event, nOverlay events overlaid on their large-peak onset; c) consecutive
% intervals between large peaks against 7.5 ms; d) phase of every large peak
% against the first grid over the whole recording (phase shifts show as steps).
% Output: results/device_<name>/8_radio_timing.png and radio_grid_epochs.csv
% (one row per stretch of unchanged phase).
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
devices  = {'device_FKY-O-0024', 'device_OLI-O-0001'};
shunt_ohm   = 10;
T0          = 7.5e-3;   % requested connection interval (s)
largeThr_mA = 9;        % large peak: 50 us mean above floor + this
largeMin_s  = 100e-6;   % large peak: at least this long
onsetThr_mA = 6;        % panel b alignment: first sample above floor + this
gridTol_s   = 50e-6;    % a peak this close to the grid continues it
zoomAt_s    = [100 20]; % per device: start of the 25 ms window of panel a (connected idle, no other load)
nOverlay    = 200;      % panel b: events overlaid
figWidth = 18; ink = [0.15 0.15 0.15];
cCur = [0.27 0.47 0.67]; cSmall = [0.87 0.80 0.47]; cLarge = [0.80 0.40 0.47]; cTick = [0.6 0.6 0.6];

for dv = 1:numel(devices)
    %% Load
    metaFile = fullfile(testDir, devices{dv}, 'meta.yml');
    meta = fileread(metaFile);
    get = @(key) strtrim(regexprep(regexp(meta, ['\n\s*' key ':\s*([^\n#]+)'], 'tokens', 'once'), '"', ''));
    num = @(key) str2double(get(key));
    fs = num('sample_rate_Hz');
    fid = fopen(fullfile(testDir, devices{dv}, char(get('file'))), 'r', 'ieee-le');
    raw = fread(fid, inf, 'int16=>double'); fclose(fid);
    i = (num('channel_range_V')*raw/65536 - num('channel_offset_V'))/shunt_ohm*1e3; clear raw   % mA
    n = numel(i); t = (0:n-1)'/fs;
    fl = movmin(movmean(i, 20), round(0.01*fs));                  % floor (10 ms)
    fprintf('=== %s: %.1f s at %g kHz\n', devices{dv}, t(end), fs/1e3);

    %% Large peaks and their onsets
    im = movmean(i, round(50e-6*fs));
    on = im > fl + largeThr_mA;
    st = find(on & ~[false; on(1:end-1)]); en = find(on & ~[on(2:end); false]);
    g = st(2:end) - en(1:end-1) < round(300e-6*fs); st = st([true; ~g]); en = en([~g; true]);
    st = st((en - st)/fs >= largeMin_s);
    % time: the 50 us mean crossing floor + largeThr_mA, interpolated between samples
    y0 = im(st - 1) - fl(st - 1) - largeThr_mA; y1 = im(st) - fl(st) - largeThr_mA;
    tL = t(st - 1) + (-y0./(y1 - y0))/fs;
    % index of the onset: first sample above floor + onsetThr_mA (panel b alignment)
    for k = 1:numel(st)
        a = max(1, st(k) - round(100e-6*fs)); j = find(i(a:st(k)) > fl(a:st(k)) + onsetThr_mA, 1);
        if ~isempty(j), st(k) = a - 1 + j; end
    end

    %% Follow the connection grid
    d = diff(tL); ok = abs(d - T0) < 0.1e-3;
    r = reshape(find(diff([0; ok; 0]) ~= 0), 2, [])'; [~, b] = max(r(:, 2) - r(:, 1));
    seg = tL(r(b, 1):r(b, 2)); pT = polyfit((0:numel(seg)-1)', seg, 1); T = pT(1);
    epoch = zeros(size(tL)); e = 0; last = NaN; nMiss = zeros(0, 1);
    for j = 1:numel(tL)
        if ~isnan(last)
            k = round((tL(j) - last)/T);
            if k >= 1 && abs(tL(j) - last - k*T) < gridTol_s
                epoch(j) = e; nMiss(e) = nMiss(e) + k - 1; last = tL(j); continue
            end
            if tL(j) - last < 3*T, continue, end                    % extra burst inside the event grid
        end
        nxt = tL(j:min(end, j + 3));
        if numel(nxt) == 4 && all(abs(diff(nxt) - T) < gridTol_s)   % a new grid starts here
            e = e + 1; nMiss(e, 1) = 0; epoch(j) = e; last = tL(j);
        end
    end
    % phase of every peak against the first grid, and per epoch
    ph = mod(tL - tL(find(epoch == 1, 1)) + T/2, T) - T/2;
    nE = max(epoch);
    Epoch = (1:nE)'; Start_s = zeros(nE, 1); End_s = Start_s; Events = Start_s; Missing = nMiss(1:nE);
    Phase_ms = Start_s; Jitter_us = Start_s;
    for k = 1:nE
        m = epoch == k; tk = tL(m); kk = round((tk - tk(1))/T);
        q = polyfit(kk, tk, 1);
        Start_s(k) = tk(1); End_s(k) = tk(end); Events(k) = nnz(m);
        Phase_ms(k) = 1e3*median(ph(m)); Jitter_us(k) = 1e6*std(tk - polyval(q, kk));
    end
    epTbl = table(Epoch, Start_s, End_s, Events, Missing, Phase_ms, Jitter_us);
    disp(epTbl)
    dk = diff(tL); dk = dk(epoch(1:end-1) > 0 & epoch(2:end) == epoch(1:end-1) & abs(dk - T) < gridTol_s);
    shifts = find(abs(diff(Phase_ms)) > 0.1);
    fprintf('Period %.5f ms (%+.1f ppm against the scope clock); consecutive intervals sd %.1f us (n %d)\n', ...
        1e3*T, 1e6*(T/T0 - 1), 1e6*std(dk), numel(dk));
    fprintf('%d phase shift(s): %s\n', numel(shifts), strjoin(arrayfun(@(s) sprintf('%.2f s (%+.2f ms)', ...
        Start_s(s + 1), Phase_ms(s + 1) - Phase_ms(s)), shifts', 'UniformOutput', false), ', '));
    outDir = fullfile(rootDir, 'results', devices{dv});
    if ~isfolder(outDir), mkdir(outDir); end
    writetable(epTbl, fullfile(outDir, 'radio_grid_epochs.csv'));

    %% Figure
    f = figure('Units', 'centimeters', 'Position', [2 2 figWidth 15], 'Color', 'w');
    try theme(f, 'light'); catch, end
    set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', 'DefaultTextInterpreter', 'none');
    % a: 25 ms of connected idle
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 10.6 figWidth - 2 3.6]); hold(ax, 'on')
    z0 = zoomAt_s(dv);
    m = t >= z0 & t < z0 + 25e-3;
    plot(ax, 1e3*(t(m) - z0), i(m), '-', 'Color', cCur, 'LineWidth', 0.6);
    tz = tL(tL >= z0 & tL < z0 + 25e-3);
    for k = 1:numel(tz)
        x = 1e3*(tz(k) - z0);
        text(ax, x + 0.1, 14, 'large', 'Color', cLarge, 'FontSize', 7);
        text(ax, x - 1.55 + 0.05, 10.2, 'small', 'Color', [0.6 0.5 0.1], 'FontSize', 7);
        if k > 1, plot(ax, 1e3*(tz(k - 1:k) - z0), [15.5 15.5], '-', 'Color', ink, 'LineWidth', 0.5);
            text(ax, 1e3*(mean(tz(k - 1:k)) - z0), 15.6, sprintf('%.3f ms', 1e3*diff(tz(k - 1:k))), ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink); end
    end
    text(ax, 1, 1.02, 'narrow spikes every 0.975 ms: 1 kHz firmware tick', 'Units', 'normalized', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', cTick);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [0 25]); ylim(ax, [-0.5 17.5]);
    xlabel(ax, sprintf('Time from %g s (ms), connected idle', z0)); ylabel(ax, 'Current (mA)');
    letter(ax, 'a', -0.07);
    % b: one connection event, overlaid
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 5.6 7.6 3.6]); hold(ax, 'on')
    w = round(-2.2e-3*fs):round(1.0e-3*fs); tw = 1e3*w/fs;
    sel = st(tL >= z0 & tL < z0 + 2 & epoch == epoch(find(tL >= z0, 1))); sel = sel(1:min(end, nOverlay));
    M = i(sel + w);
    plot(ax, tw, M', '-', 'Color', [0.82 0.82 0.82], 'LineWidth', 0.3);
    plot(ax, tw, median(M), '-', 'Color', ink, 'LineWidth', 1);
    patch(ax, [-1.62 -1.3 -1.3 -1.62], [-0.5 -0.5 16 16], cSmall, 'EdgeColor', 'none', 'FaceAlpha', 0.25);
    patch(ax, [0 0.37 0.37 0], [-0.5 -0.5 16 16], cLarge, 'EdgeColor', 'none', 'FaceAlpha', 0.2);
    text(ax, -1.46, 15, 'small: wake-up', 'HorizontalAlignment', 'center', 'FontSize', 7, 'Color', [0.6 0.5 0.1]);
    text(ax, -0.7, 2.2, '0.3 mA: crystal running', 'HorizontalAlignment', 'center', 'FontSize', 6.5, 'Color', ink);
    text(ax, 0.185, 15, 'large: RX + TX', 'HorizontalAlignment', 'center', 'FontSize', 7, 'Color', cLarge);
    hold(ax, 'off'); styleAxes(ax); xlim(ax, tw([1 end])); ylim(ax, [-0.5 16]);
    xlabel(ax, 'Time from the large-peak onset (ms)'); ylabel(ax, 'Current (mA)');
    text(ax, 0.02, 0.6, sprintf('%d events (grey), median (black)', size(M, 1)), 'Units', 'normalized', 'FontSize', 6.5, 'Color', ink);
    letter(ax, 'b', -0.17);
    % c: consecutive intervals
    ax = axes(f, 'Units', 'centimeters', 'Position', [10.9 5.6 6.6 3.6]);
    histogram(ax, 1e6*(dk - T0), -20:1:20, 'FaceColor', cCur, 'EdgeColor', 'none');
    styleAxes(ax); xlabel(ax, 'Interval − 7.5 ms (µs)'); ylabel(ax, 'Intervals');
    text(ax, 0.02, 0.92, sprintf('mean %+.2f µs, sd %.1f µs\n(5 µs samples), n %d', 1e6*(mean(dk) - T0), 1e6*std(dk), numel(dk)), ...
        'Units', 'normalized', 'VerticalAlignment', 'top', 'FontSize', 6.5, 'Color', ink);
    letter(ax, 'c', -0.2);
    % d: phase over the whole recording
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.1 figWidth - 2 3.4]); hold(ax, 'on')
    plot(ax, tL(epoch == 0), 1e3*ph(epoch == 0), '.', 'Color', [0.8 0.8 0.8], 'MarkerSize', 3);
    plot(ax, tL(epoch > 0), 1e3*ph(epoch > 0), '.', 'Color', cCur, 'MarkerSize', 4);
    for s = shifts'
        text(ax, Start_s(s + 1), Phase_ms(s + 1), sprintf('  %+.2f ms', Phase_ms(s + 1) - Phase_ms(s)), ...
            'FontSize', 7, 'Color', cLarge, 'VerticalAlignment', 'bottom');
    end
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [0 t(end)]); ylim(ax, [-3.75 3.75]); ax.YTick = -3.75:1.25:3.75;
    xlabel(ax, 'Time (s)'); ylabel(ax, 'Phase vs grid (ms)');
    text(ax, 0.99, 0.95, sprintf('blue: on the connection grid (T = %.5f ms, %+.1f ppm vs scope); grey: other bursts', 1e3*T, 1e6*(T/T0 - 1)), ...
        'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', 'FontSize', 6.5, 'Color', ink);
    letter(ax, 'd', -0.07);
    exportgraphics(f, fullfile(outDir, '8_radio_timing.png'), 'Resolution', 300, 'BackgroundColor', 'white');
    close(f);
    fprintf('Saved %s\n', fullfile(outDir, '8_radio_timing.png'));
end

%% Local functions
function letter(ax, s, x)
text(ax, x, 1.06, s, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', [0.15 0.15 0.15]);
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', 'XColor', ink, 'YColor', ink);
ax.Toolbar.Visible = 'off';
end
