% Decoupling capacitor tests on V_BANK (test 3): how much an added
% capacitor reduces the radio dips during the capacitor-bank hold-up, how
% much hold-up it adds, and the expected return for 10-200 uF.
% Data (device not connected over BLE, so the radio events are advertising
% events, every ~190 ms, about 3 ms long):
%   baseline, no added capacitor: DC_5.0V_CapBank_Test_2.bin (200 kHz, the
%     whole hold-up from 5 V to the collapse; settings in its .meta.yml)
%   added capacitors: WaveForms CSV exports (volts, Sample Mode: Average),
%     short captures of the dips, and one 91 Hz log of a whole hold-up.
% Model. The bank feeds the board through Rs (bank ESR and wiring); the board
% side holds Cn (C54, effective at bias) plus the added capacitor Ceff. A
% radio event draws a current burst i(t); with x = bank voltage - node:
%   (Cn + Ceff) dx/dt = i(t) - x/Rs
% i(t) is recovered from the baseline dip at 200 kHz (Ceff = 0):
%   i = x/Rs + Cn dx/dt. For each capture the model is averaged over one
% sample (WaveForms Average mode) and Ceff is the value that reproduces the
% measured dip depth. Rs and Cn come from decoupling_capacitor_sizing.m.
% Hold-up. The device collapses when the mean bank voltage reaches
%   Vcol = Vfloor + k*dip(C)
% with dip(C) the modelled dip at the reference current; Vfloor and k are
% set by the two hold-up runs (baseline and 110 uF). The hold-up for any C is
% the time the measured 110 uF discharge (1 s mean) takes from the cut-off
% to Vcol. Two anchors only: an interpolation with a physical shape, not a fit.
% Output: results/<recording folder>/decoupling_tests.png, .pdf (figure and
% the computation), decoupling_tests_measured.csv, decoupling_tests_curve.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
recFolder = 'device_LRV-O-0001';
baseFile  = 'DC_5.0V_CapBank_Test_2.bin';       % no added capacitor, whole hold-up, 200 kHz
tests = struct( ...
    'file',    {'DC_5.0V_10uF6_3V_decoupling_CapBank_Test_1.csv', ...
                'DC_5.0V_40uF6_3V_decoupling_CapBank_Test_2.csv', ...
                'DC_5.0V_100uF6_3V_decoupling_CapBank_Test_3.csv'}, ...
    'nominal', {10, 44, 110}, ...                % uF
    'part',    {'1 x 10 uF X7R 0603, 6.3 V', ...
                '2 x Murata GRM155R60J226ME11 (22 uF X5R 0402, 6.3 V)', ...
                '5 x Murata GRM155R60J226ME11 (22 uF X5R 0402, 6.3 V)'});
holdFile    = 'DC_5.0V_100uF6_3V_decoupling_CapBank_Test_4_holdup_unconnected.csv';
holdNominal = 110;                              % uF, same 5 x 22 uF as Test_3
Rs   = 322;      % ohm, bank to board (decoupling_capacitor_sizing.m, test 1 event charge)
Cn   = 0.71e-6;  % F, C54 at bias (same source)
deepDip_V = 0.8; % baseline radio dips: deeper than this (V)
capDip_V  = 0.3; % capture radio dips: deeper than this (V)
curveNom_uF = 10:5:200;   % curve: nominal capacitance of GRM155R60J226ME11 parts (uF)

figWidth = 18; ink = [0.15 0.15 0.15];
cols = [0.55 0.55 0.55; 0.87 0.80 0.47; 0.80 0.40 0.47; 0.27 0.47 0.67];

%% Baseline: advertising dips with no added capacitor (200 kHz)
[~, b0] = fileparts(baseFile);
metaFile = fullfile(testDir, recFolder, [b0 '.meta.yml']);
meta = readMeta(metaFile);
fs = metaNum(meta, 'sample_rate_Hz', metaFile); dt = 1/fs;
fid = fopen(fullfile(testDir, recFolder, baseFile), 'r', 'ieee-le');
raw = fread(fid, inf, 'int16=>double'); fclose(fid);
v = metaNum(meta, 'channel_range_V', metaFile)*raw/65536 - metaNum(meta, 'channel_offset_V', metaFile);
clear raw
t = (0:numel(v)-1)'*dt;
[tUn0, tCol0, Vcol0] = holdupTimes(t, v);
hold0 = tCol0 - tUn0;
k = t > tUn0 + 0.5 & t < tCol0 - 0.5;
st = dipStarts(v, k, fs, deepDip_V);
pre = round(1e-3*fs); post = round(12e-3*fs);
X = nan(pre + post + 1, numel(st));
for j = 1:numel(st)
    top = max(v(st(j) - round(3e-3*fs):st(j)));
    X(:, j) = top - v(st(j) - pre:st(j) + post);
end
x0 = median(X, 2); x0 = x0 - median(x0(1:round(0.8*pre)));   % zero before the burst
tx = (-pre:post)'*dt;
i0 = x0/Rs + Cn*gradient(movmean(x0, 5), dt);   % burst current (A)
i0(i0 < 0 & tx < 0) = 0;
Q0 = sum(i0)*dt;
depth0 = max(x0);
fprintf('Baseline: %d advertising dips, depth %.3f V, charge %.1f uC per event; hold-up %.1f s, collapse at mean %.2f V\n', ...
    numel(st), depth0, 1e6*Q0, hold0, Vcol0);
dipModel = @(Ceff, avgWin) peakDip(i0, dt, Rs, Cn + Ceff, avgWin);

%% Captures with added capacitors
nT = numel(tests);
Depth_V = nan(nT, 1); Level_V = Depth_V; Ceff_uF = Depth_V; Nominal_uF = [tests.nominal]';
shapes = cell(nT, 1);
for c = 1:nT
    [tc, vc, fsc] = readWaveformsCsv(fullfile(testDir, recFolder, tests(c).file));
    s = dipStarts(vc, true(size(vc)), fsc, capDip_V);
    d = nan(numel(s), 1); L = d;
    pc = round(1e-3*fsc); qc = round(12e-3*fsc);
    S = nan(pc + qc + 1, numel(s));
    for j = 1:numel(s)
        a = max(1, s(j) - round(3e-3*fsc));
        L(j) = max(vc(a:s(j)));
        w = vc(max(1, s(j) - pc):min(numel(vc), s(j) + qc));
        d(j) = L(j) - min(w);
        if s(j) - pc >= 1 && s(j) + qc <= numel(vc), S(:, j) = L(j) - vc(s(j) - pc:s(j) + qc); end
    end
    Depth_V(c) = median(d); Level_V(c) = median(L);
    shapes{c} = [(-pc:qc)'/fsc, median(S, 2, 'omitnan')];
    % effective capacitance that reproduces the depth (model averaged over one sample)
    Ceff_uF(c) = 1e6*fzero(@(C) dipModel(C, 1/fsc) - Depth_V(c), [0 2e-3]);
    fprintf('%-52s %3d uF nominal: %d dips, depth %.3f V at %.2f V -> effective %.1f uF (%.0f%%)\n', ...
        tests(c).part, tests(c).nominal, numel(s), Depth_V(c), Level_V(c), Ceff_uF(c), 100*Ceff_uF(c)/tests(c).nominal);
end
Retention_pct = 100*Ceff_uF./Nominal_uF;
Part = string({tests.part})';

%% Hold-up with 110 uF
[th, vh, fsh] = readWaveformsCsv(fullfile(testDir, recFolder, holdFile));
[tUnH, tColH, VcolH] = holdupTimes(th, vh);
holdH = tColH - tUnH;
vhm = movmean(vh, round(fsh));                  % 1 s mean
fprintf('110 uF hold-up: %.1f s, collapse at mean %.2f V (baseline %.1f s at %.2f V)\n', holdH, VcolH, hold0, Vcol0);

%% Collapse model and the return curve
Ceff110 = Ceff_uF(Nominal_uF == holdNominal)*1e-6;
d0 = dipModel(0, 0); d110 = dipModel(Ceff110, 0);
kk = (Vcol0 - VcolH)/(d0 - d110);
Vfloor = Vcol0 - kk*d0;
fprintf('Collapse model: Vcol = %.2f V + %.2f x dip (dip %.2f V without, %.2f V with 110 uF)\n', Vfloor, kk, d0, d110);
retention = Ceff110/(holdNominal*1e-6);         % of the GRM155 parts at the operating voltage
CeffCurve = retention*curveNom_uF*1e-6;
dipCurve = arrayfun(@(C) dipModel(C, 0), CeffCurve);
VcolCurve = Vfloor + kk*dipCurve;
after = th >= tUnH;
tTraj = th(after) - tUnH; vTraj = vhm(after);
holdAt = @(V) firstBelow(tTraj, vTraj, V);
holdCurve = arrayfun(holdAt, VcolCurve);
holdRef0 = holdAt(Vcol0);                        % baseline collapse level on the 110 uF discharge
Nominal = curveNom_uF'; Effective_uF = 1e6*CeffCurve'; Dip_V = dipCurve'; Collapse_V = VcolCurve';
HoldUp_s = holdCurve'; Gain_s = holdCurve' - holdRef0;
curveTbl = table(Nominal, Effective_uF, Dip_V, Collapse_V, HoldUp_s, Gain_s, ...
    'VariableNames', {'Nominal_uF', 'Effective_uF', 'Dip_V', 'Collapse_V', 'HoldUp_s', 'GainOverNone_s'});
outDir = fullfile(rootDir, 'results', recFolder);
if ~isfolder(outDir), mkdir(outDir); end
writetable(curveTbl, fullfile(outDir, 'decoupling_tests_curve.csv'));
measTbl = table(Part, Nominal_uF, Level_V, Depth_V, Ceff_uF, Retention_pct);
writetable(measTbl, fullfile(outDir, 'decoupling_tests_measured.csv'));
disp(measTbl); disp(curveTbl(ismember(curveTbl.Nominal_uF, [10 20 40 50 100 150 200]), :))

%% Figure
f = newFigure(figWidth, 16);
% a: dip shapes
ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 9.6 7.2 5.6]); hold(ax, 'on')
plot(ax, 1e3*tx, x0, '-', 'Color', cols(1, :), 'LineWidth', 1, 'DisplayName', 'none added (200 kHz)');
for c = 1:nT
    plot(ax, 1e3*shapes{c}(:, 1), shapes{c}(:, 2), '-', 'Color', cols(c + 1, :), 'LineWidth', 1, ...
        'DisplayName', sprintf('%d uF nominal', tests(c).nominal));
end
hold(ax, 'off'); styleAxes(ax); set(ax, 'YDir', 'reverse');
xlim(ax, [-1 12]); xlabel(ax, 'Time from dip start (ms)'); ylabel(ax, 'Dip below the bank level (V)');
legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 6);
title(ax, 'Advertising-event dip', 'FontWeight', 'normal', 'FontSize', 8);
panelLetter(ax, 'a');
% b: dip depth against capacitance
ax = axes(f, 'Units', 'centimeters', 'Position', [10.6 9.6 6.9 5.6]); hold(ax, 'on')
plot(ax, curveNom_uF, dipCurve, '-', 'Color', ink, 'LineWidth', 1.25, 'DisplayName', ...
    sprintf('model, GRM155 parts (%.0f%% effective)', 100*retention));
Ce = linspace(0, 200e-6, 100);
plot(ax, 1e6*Ce, arrayfun(@(C) dipModel(C, 0), Ce), '--', 'Color', ink, 'LineWidth', 0.75, ...
    'DisplayName', 'model, against effective C');
plot(ax, 0, depth0, 'o', 'MarkerFaceColor', cols(1, :), 'MarkerEdgeColor', ink, 'DisplayName', 'measured, none');
for c = 1:nT
    plot(ax, tests(c).nominal, Depth_V(c), 'o', 'MarkerFaceColor', cols(c + 1, :), 'MarkerEdgeColor', ink, ...
        'DisplayName', sprintf('measured, %d uF', tests(c).nominal));
end
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [0 200]); ylim(ax, [0 ceil(depth0*5)/5]);
xlabel(ax, 'Added capacitance (uF)'); ylabel(ax, 'Dip depth (V)');
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6);
panelLetter(ax, 'b');
% c: hold-up against capacitance
ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.3 7.2 6.4]); hold(ax, 'on')
plot(ax, curveNom_uF, holdCurve, '-', 'Color', ink, 'LineWidth', 1.25, 'DisplayName', 'model (on the 110 uF discharge)');
plot(ax, 0, holdRef0, 'o', 'MarkerFaceColor', cols(1, :), 'MarkerEdgeColor', ink, ...
    'DisplayName', sprintf('none: collapse at %.2f V (+%.1f s on this discharge)', Vcol0, holdRef0));
plot(ax, holdNominal, holdH, 'o', 'MarkerFaceColor', cols(4, :), 'MarkerEdgeColor', ink, ...
    'DisplayName', sprintf('110 uF measured: %.1f s', holdH));
for c = 1:nT
    if tests(c).nominal ~= holdNominal
        h = holdAt(Vfloor + kk*dipModel(Ceff_uF(c)*1e-6, 0));
        plot(ax, tests(c).nominal, h, 's', 'MarkerFaceColor', cols(c + 1, :), 'MarkerEdgeColor', ink, ...
            'DisplayName', sprintf('%d uF (its own retention): %.0f s predicted', tests(c).nominal, h));
    end
end
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [0 200]); ylim(ax, [0 ceil(max(holdCurve)/10)*10 + 10]);
xlabel(ax, 'Added capacitance, nominal (uF)'); ylabel(ax, 'Hold-up after the cut-off (s)');
legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 6);
panelLetter(ax, 'c');
% d: the two hold-up runs
ax = axes(f, 'Units', 'centimeters', 'Position', [10.6 1.3 6.9 6.4]); hold(ax, 'on')
kb = 1:round(0.01*fs):numel(v);
vb = movmean(v, round(fs));
plot(ax, t(kb) - tUn0, vb(kb), '-', 'Color', cols(1, :), 'LineWidth', 1.25, 'DisplayName', 'none added (1 s mean)');
plot(ax, th - tUnH, vhm, '-', 'Color', cols(4, :), 'LineWidth', 1.25, 'DisplayName', '110 uF nominal (1 s mean)');
plot(ax, hold0, Vcol0, 'v', 'MarkerFaceColor', cols(1, :), 'MarkerEdgeColor', ink, 'HandleVisibility', 'off');
plot(ax, holdH, VcolH, 'v', 'MarkerFaceColor', cols(4, :), 'MarkerEdgeColor', ink, 'HandleVisibility', 'off');
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [-5 holdH + 10]); ylim(ax, [1 5.5]);
xlabel(ax, 'Time from the cut-off (s)'); ylabel(ax, 'Bank node (V)');
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6);
panelLetter(ax, 'd');
exportgraphics(f, fullfile(outDir, 'decoupling_tests.png'), 'Resolution', 300, 'BackgroundColor', 'white');
pdfFile = fullfile(outDir, 'decoupling_tests.pdf');
exportgraphics(f, pdfFile, 'ContentType', 'vector', 'BackgroundColor', 'white');
close(f);

%% Page 2: computation and conclusion
pick = @(n) curveTbl(curveTbl.Nominal_uF == n, :);
txt = {
    'Decoupling capacitor tests: radio dips and hold-up (device not connected, advertising)'
    ''
    'Parts: Murata GRM155R60J226ME11 = 22 uF, X5R, 6.3 V, 0402, +/-20% (2 x = 44 uF, 5 x = 110 uF nominal);'
    '       10 uF X7R 0603, 6.3 V. The file names already give the right rating (6.3 V).'
    ''
    '1. Radio event with no added capacitor (DC_5.0V_CapBank_Test_2.bin, 200 kHz)'
    sprintf('   Advertising events every ~190 ms: three bursts over ~3 ms, dip %.2f V; charge %.1f uC per event', depth0, 1e6*Q0)
    sprintf('   (i = x/Rs + Cn dx/dt, Rs = %.0f ohm, Cn = %.2f uF). Hold-up %.1f s; collapse at mean %.2f V.', Rs, 1e6*Cn, hold0, Vcol0)
    ''
    '2. Effective capacitance of the added parts (model dip matched to the measured dip)'
    };
for c = 1:nT
    txt{end+1} = sprintf('   %-52s depth %.2f V at %.2f V -> %.1f uF effective (%.0f%% of nominal)', ...
        tests(c).part, Depth_V(c), Level_V(c), Ceff_uF(c), Retention_pct(c)); %#ok<SAGROW>
end
txt = [txt; {
    '   The 0402 22 uF parts keep only about a quarter of their capacitance at 3-4 V (DC bias), as expected'
    '   for a 6.3 V 0402 X5R part.'
    ''
    '3. Hold-up'
    sprintf('   110 uF nominal: %.1f s, collapse at mean %.2f V (none: %.1f s, %.2f V). On the same discharge,', holdH, VcolH, hold0, Vcol0)
    sprintf('   reaching %.2f V took %.1f s, so the capacitor added about %.0f s for the same bank.', Vcol0, holdRef0, holdH - holdRef0)
    sprintf('   Collapse rule from the two runs: Vcol = %.2f V + %.2f x dip.', Vfloor, kk)
    ''
    '4. Return for 10-200 uF of GRM155R60J226ME11 (see decoupling_tests_curve.csv)'
    }];
for n = [10 22 44 66 110 150 200]
    r = curveTbl(abs(curveTbl.Nominal_uF - n) == min(abs(curveTbl.Nominal_uF - n)), :); r = r(1, :);
    txt{end+1} = sprintf('   %3d uF nominal (%4.1f uF effective): dip %.2f V, collapse at %.2f V, hold-up %4.1f s (+%4.1f s)', ...
        r.Nominal_uF, r.Effective_uF, r.Dip_V, r.Collapse_V, r.HoldUp_s, r.GainOverNone_s); %#ok<SAGROW>
end
r100 = pick(100); r200 = pick(200); r50 = pick(50);
txt = [txt; {
    ''
    '5. Conclusion'
    sprintf('   Most of the gain comes in the first ~50 uF nominal (+%.0f s); 100 uF gives +%.0f s and 200 uF +%.0f s.', ...
        r50.GainOverNone_s, r100.GainOverNone_s, r200.GainOverNone_s)
    '   Past ~100 uF the device runs down close to its floor voltage and extra capacitance adds little.'
    '   The 0402 6.3 V parts are inefficient at this voltage: a 10 V (or 16 V) 0603/0805 X5R/X7R part keeps far'
    '   more capacitance, so fewer parts give the same effective value; a polymer capacitor barely derates.'
    '   Caveats: two hold-up runs only (no hold-up with 10 or 44 uF); the bank discharge differs between runs,'
    '   so hold-up times are compared on one discharge (the 110 uF run); Rs and Cn are taken as fixed.'
    }];
f = newFigure(figWidth, 25);
ax = axes(f, 'Units', 'normalized', 'Position', [0.05 0.03 0.9 0.94], 'Visible', 'off');
text(ax, 0, 1, txt, 'VerticalAlignment', 'top', 'FontName', 'Arial', 'FontSize', 8.5, 'Interpreter', 'none', 'Color', ink);
exportgraphics(f, pdfFile, 'ContentType', 'vector', 'BackgroundColor', 'white', 'Append', true);
close(f);
fprintf('Saved %s\n', pdfFile);

%% Local functions
function [tUn, tCol, Vcol] = holdupTimes(t, v)
% Supply cut-off: first 10 ms mean more than 0.05 V below the powered level
% (highest 1 s median). Collapse: from then on the trace stays within 0.1 V
% of its final level. Vcol: 1 s mean ending 0.2 s before the collapse.
fsx = 1/median(diff(t));
vm = movmedian(v, max(3, round(fsx)));
pw = max(vm); iP = find(vm > pw - 0.02, 1, 'last');
v10 = movmean(v, max(1, round(0.01*fsx)));
iU = iP + find(v10(iP:end) < pw - 0.05, 1) - 1;
tUn = t(iU);
vEnd = median(v(t > t(end) - 2));
away = abs(v - vEnd) > 0.1 & t > tUn;
iC = find(away, 1, 'last') + 1;
tCol = t(iC);
w = t > tCol - 1.2 & t <= tCol - 0.2;
Vcol = mean(v(w));
end

function st = dipStarts(v, mask, fsx, thr)
% Start of each dip deeper than thr below the 20 ms running maximum
base = movmax(v, round(0.02*fsx));
d = (base - v) > thr & mask;
st = find(d & ~[false; d(1:end-1)]);
st = st([true; diff(st) > round(0.02*fsx)]);
st = st(st > round(0.003*fsx) & st < numel(v) - round(0.012*fsx));
end

function pk = peakDip(i, dt, Rs, C, avgWin)
% Peak of x for C dx/dt = i - x/Rs (x = 0 before the burst); optionally
% averaged over avgWin (WaveForms Average sample mode)
n = numel(i) + round(0.02/dt);
ii = [i; zeros(n - numel(i), 1)];
x = zeros(n, 1);
a = exp(-dt/(Rs*C));
for m = 2:n
    x(m) = x(m-1)*a + ii(m)*Rs*(1 - a);
end
if avgWin > dt, x = movmean(x, round(avgWin/dt)); end
pk = max(x);
end

function tt = firstBelow(t, v, V)
i = find(v < V, 1);
if isempty(i), tt = NaN; else, tt = t(i); end
end

function [t, v, fsx] = readWaveformsCsv(file)
% WaveForms Oscilloscope CSV export: '#' header lines, then Time (s), Channel 1 (V)
txt = fileread(file);
tok = regexp(txt, '#Sample rate: ([0-9.eE+-]+)Hz', 'tokens', 'once');
fsx = str2double(tok{1});
M = readmatrix(file, 'NumHeaderLines', find(startsWith(splitlines(txt), 'Time (s)'), 1));
t = M(:, 1); v = M(:, 2);
end

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
text(ax, -0.2, 1.08, s, 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', [0.15 0.15 0.15]);
end

function f = newFigure(wCm, hCm)
f = figure('Units', 'centimeters', 'Position', [2 2 wCm hCm], 'Color', 'w');
try theme(f, 'light'); catch, end
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', ...
    'DefaultTextInterpreter', 'none', 'DefaultAxesTickLabelInterpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', 'XColor', ink, 'YColor', ink);
ax.Toolbar.Visible = 'off';
end
