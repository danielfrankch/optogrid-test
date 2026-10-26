% Rx resonance from a WaveForms Network Analyzer sweep (test 4, dip method)
% Run from MATLAB (Run button, or `analyse_network_analyzer` from any folder).
% Setup: Wavegen W1 -> series resistor Rser -> sniffer loop -> GND. Ch1 =
% wavegen output (drive side of Rser), Ch2 = voltage across the sniffer loop.
% The CSV header says Ch2 is "Relative: yes", so its magnitude (dB) and phase
% (deg) are already Ch2/Ch1; Ch1's magnitude column is its absolute level and
% is unused.
% Per-recording settings come from <recording>.meta.yml next to the CSV:
% tuning capacitor, Rx load (rx_loaded: device attached or not), series
% resistor, baseline window, fit range, smoothing.
% Baselines: a quadratic is fitted to the phase and to Re(Z) below
% baseline_lo_Hz and above baseline_hi_Hz. A narrow sweep inside the resonance
% names a wide sweep of the same setup as baseline_rec and takes the baselines
% (polynomials in absolute frequency, that recording's window) from it.
% Method A: phase dip. Corrected phase = phase - baseline; f0 = minimum of the
% smoothed dip, Q = f0 / (half-depth width), crossings linearly interpolated.
% Method B: reflected resistance. H = Ch2/Ch1 = Z / (Rser + Z), so
% Z = Rser H / (1 - H). dR = Re(Z) - baseline is the resistance the Rx
% reflects into the loop; A / (1 + (2Q(f - f0)/f0)^2) + c is fitted (nlinfit,
% 1-sigma from CovB; c is fixed at 0 when the sweep has no baseline of its
% own). Model-free check: half-maximum width of the smoothed peak.
% Both methods also give f0 as the vertex of a parabola through the part of
% the dip / peak deeper than topFrac (robust on a flat top).
% f0 and Q from method B do not depend on Rser (Z scales with it); A does.
% The installed tuning capacitor plus the parasitic capacitance (C at f0 minus
% the tuning capacitor) gives the tuning capacitor needed for fTarget.
% Output: results/device_<name>/<recording>_{bode,phase_dip,reflected_R}.png
% and <recording>_summary.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
recFolder = 'device_LRV-O-0001';
whichData = 'newest';   % 'newest', 'every', or a recording name (without .csv)
Lrx       = 2.62e-6;    % H, Rx coil inductance
fTarget   = 13.56e6;    % Hz
baseOrder = 2;          % polynomial order of both baselines
topFrac   = 0.9;        % parabola f0 uses points deeper than this fraction of the dip / peak
e24 = [1.0 1.1 1.2 1.3 1.5 1.6 1.8 2.0 2.2 2.4 2.7 3.0 3.3 3.6 3.9 4.3 4.7 5.1 5.6 6.2 6.8 7.5 8.2 9.1];  % C0G
ink = [0.15 0.15 0.15]; cData = [0.20 0.13 0.53]; cFit = [0.80 0.40 0.47];
cBase = [0.60 0.60 0.20]; cShade = [0.87 0.87 0.87]; cRaw = [0.53 0.80 0.93];   % Paul Tol muted

%% Recordings
dataDir = fullfile(testDir, recFolder);
recs = dir(fullfile(dataDir, 'network_analyzer_*.csv'));
recs = sort(erase({recs.name}, '.csv'));
switch whichData
    case 'newest', recs = recs(end);
    case 'every'
    otherwise, recs = {whichData};
end
outDir = fullfile(rootDir, 'results', recFolder);
if ~exist(outDir, 'dir'), mkdir(outDir); end
lorentz = @(p, f) p(1) ./ (1 + (2*p(3)*(f - p(2))./p(2)).^2) + p(4);   % f in MHz
capF = @(f) 1 ./ ((2*pi*f).^2 * Lrx);

for r = 1:numel(recs)
recName = recs{r};
metaFile = fullfile(dataDir, [recName '.meta.yml']);
meta = readMeta(metaFile);
Rser     = metaNum(meta, 'series_resistor_ohm', metaFile);
Ctune    = metaNum(meta, 'tuning_capacitor_pF', metaFile) * 1e-12;
smoothHz = metaNum(meta, 'smooth_Hz', metaFile);
fitLo    = metaNum(meta, 'fit_lo_Hz', metaFile);
fitHi    = metaNum(meta, 'fit_hi_Hz', metaFile);
if strcmpi(meta.rx_loaded, 'true'), loadTag = sprintf('loaded by %s', meta.device); else, loadTag = 'no load'; end
figTitle = sprintf('%s, %s: %s', regexprep(recName, '^.*_(test_\d+)$', '$1'), loadTag, meta.tuning_capacitor);
[f, mag, ph, hdr] = loadNA(fullfile(dataDir, [recName '.csv']));
fprintf('\n=== %s ===\n%s\n', recName, strjoin(hdr, newline));
fM = f/1e6;
H = 10.^(mag/20) .* exp(1i*deg2rad(ph));
Z = Rser * H ./ (1 - H);

% Baselines: own data, or baseline_rec's data and window
ownBase = ~isfield(meta, 'baseline_rec');
if ownBase
    fB = f; phB = ph; ZB = Z; baseFrom = recName; baseMeta = meta; baseMetaFile = metaFile;
else
    baseFrom = meta.baseline_rec;
    baseMetaFile = fullfile(dataDir, [baseFrom '.meta.yml']);
    baseMeta = readMeta(baseMetaFile);
    [fB, magB, phB] = loadNA(fullfile(dataDir, [baseFrom '.csv']));
    HB = 10.^(magB/20) .* exp(1i*deg2rad(phB));
    ZB = Rser * HB ./ (1 - HB);
    fprintf('Baselines from %s\n', baseFrom);
end
baseLo = metaNum(baseMeta, 'baseline_lo_Hz', baseMetaFile);
baseHi = metaNum(baseMeta, 'baseline_hi_Hz', baseMetaFile);
outside = @(f) f < baseLo | f > baseHi;
xc = 14;   % MHz, polynomial centre
o = outside(fB);
pPh = polyfit(fB(o)/1e6 - xc, phB(o), baseOrder);
pRe = polyfit(fB(o)/1e6 - xc, real(ZB(o)), baseOrder);
phBase = polyval(pPh, fM - xc);
reBase = polyval(pRe, fM - xc);
noiseA = std(phB(o) - polyval(pPh, fB(o)/1e6 - xc));
win = 2*floor(smoothHz/median(diff(f))/2) + 1;

%% Method A: phase dip
phC = ph - phBase;
phS = sgolayfilt(phC, 2, win);
[depthA, iA] = min(phS);
f0A = f(iA);
[fAlo, fAhi] = halfCrossings(f, -phS, -depthA/2, iA);
QA = f0A / (fAhi - fAlo);
f0Apar = parabolaVertex(f, -phC, -phS, iA, topFrac);

%% Method B: reflected resistance
dR = real(Z) - reBase;
dRs = sgolayfilt(dR, 2, win);
[pkB, iB] = max(dRs);
[fBlo, fBhi] = halfCrossings(f, dRs, pkB/2, iB);
f0Bmf = (fBlo + fBhi)/2;
QBmf = f0Bmf / (fBhi - fBlo);
f0Bpar = parabolaVertex(f, dR, dRs, iB, topFrac);
sel = f >= fitLo & f <= fitHi;
if isnan(QA), q0 = 8; else, q0 = QA; end
if ownBase   % c free
    model = lorentz; p0 = [pkB, fM(iB), q0, 0];
else         % no baseline of its own: c = 0
    model = @(p, f) lorentz([p 0], f); p0 = [pkB, fM(iB), q0];
end
[pB, ~, ~, covB] = nlinfit(fM(sel), dR(sel), model, p0);
eB = sqrt(diag(covB))';
if ~ownBase, pB(4) = 0; eB(4) = 0; end
resid = dR(sel) - model(pB(1:numel(p0)), fM(sel));
LloopUH = mean(imag(ZB(o)) ./ (2*pi*fB(o))) * 1e6;

%% Report
f0B = pB(2)*1e6;
Ctgt = capF(fTarget);
rows = {
    'baseline_from', NaN, baseFrom
    'tuning_capacitor_pF', Ctune*1e12, meta.tuning_capacitor
    'rx_loaded', double(strcmpi(meta.rx_loaded, 'true')), meta.rx_load
    'sweep_start_MHz', fM(1), ''
    'sweep_stop_MHz', fM(end), ''
    'step_kHz', median(diff(f))/1e3, ''
    'f0_A_MHz', f0A/1e6, 'min of smoothed corrected phase'
    'f0_A_parabola_MHz', f0Apar/1e6, sprintf('vertex over the deepest %g%%', 100*(1-topFrac))
    'Q_A', QA, 'NaN if the half-depth points are outside the sweep'
    'f_low_A_MHz', fAlo/1e6, ''
    'f_high_A_MHz', fAhi/1e6, ''
    'dip_depth_A_deg', depthA, ''
    'phase_baseline_rms_deg', noiseA, 'baseline misfit outside the dip'
    'f0_B_MHz', pB(2), 'Lorentzian fit'
    'f0_B_err_MHz', eB(2), '1 sigma'
    'Q_B', pB(3), 'Lorentzian fit'
    'Q_B_err', eB(3), '1 sigma'
    'A_B_ohm', pB(1), ''
    'A_B_err_ohm', eB(1), ''
    'c_B_ohm', pB(4), 'fixed at 0 without own baseline'
    'c_B_err_ohm', eB(4), ''
    'resid_rms_ohm', rms(resid), ''
    'f0_B_halfmax_MHz', f0Bmf/1e6, 'midpoint of the half-maximum points'
    'Q_B_halfmax', QBmf, ''
    'f_low_B_MHz', fBlo/1e6, ''
    'f_high_B_MHz', fBhi/1e6, ''
    'f0_B_parabola_MHz', f0Bpar/1e6, sprintf('vertex over the top %g%%', 100*(1-topFrac))
    'dR_peak_ohm', pkB, ''
    'L_loop_uH', LloopUH, 'Im(Z)/w outside the resonance'
    'C_target_pF', Ctgt*1e12, ''
    'C_f0B_pF', capF(f0B)*1e12, ''
    'dC_A_pF', (Ctgt - capF(f0A))*1e12, ''
    'dC_A_parabola_pF', (Ctgt - capF(f0Apar))*1e12, ''
    'dC_B_pF', (Ctgt - capF(f0B))*1e12, ''
    'dC_B_err_pF', 2*capF(f0B)*eB(2)/pB(2)*1e12, 'fit error only'
    'dC_B_parabola_pF', (Ctgt - capF(f0Bpar))*1e12, ''
    'dC_B_nearest_E24_pF', nearestE24((Ctgt - capF(f0B))*1e12, e24), ''
    'C_parasitic_B_pF', (capF(f0B) - Ctune)*1e12, 'C at f0_B minus the tuning capacitor'
    'C_tune_for_target_pF', (Ctune + Ctgt - capF(f0B))*1e12, 'tuning capacitor for fTarget (method B)'
    'C_tune_nearest_E24_pF', nearestE24((Ctune + Ctgt - capF(f0B))*1e12, e24), ''
    };
T = cell2table(rows, 'VariableNames', {'quantity', 'value', 'note'});
writetable(T, fullfile(outDir, [recName '_summary.csv']));
disp(T(2:end, 1:2));

%% Figures
fx = [fM(1) fM(end)];
% 1: Bode
fig = newFig(14, figTitle);
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 7.6 15.4 5.6]); hold(ax, 'on')
plot(ax, fM, mag, '-', 'Color', cData, 'LineWidth', 0.8);
xline(ax, fTarget/1e6, ':', 'Color', ink);
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx); ax.XTickLabel = [];
ylabel(ax, 'Ch2/Ch1 magnitude (dB)'); letter(ax, 'a');
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 1.4 15.4 5.6]); hold(ax, 'on')
plot(ax, fM, ph, '-', 'Color', cData, 'LineWidth', 0.8);
xline(ax, fTarget/1e6, ':', '13.56 MHz', 'Color', ink, 'FontSize', 9, 'LabelVerticalAlignment', 'bottom');
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx);
xlabel(ax, 'Frequency (MHz)'); ylabel(ax, 'Ch2/Ch1 phase (°)'); letter(ax, 'b');
saveFig(fig, outDir, [recName '_bode']);

% 2: Method A
fig = newFig(14, figTitle);
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 7.6 15.4 5.6]); hold(ax, 'on')
if ownBase, shadeBase(ax, baseLo, baseHi, cShade); end
h1 = plot(ax, fM, ph, '-', 'Color', cData, 'LineWidth', 0.8);
h2 = plot(ax, fM, phBase, '--', 'Color', cBase, 'LineWidth', 1.2);
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx); ax.XTickLabel = [];
legendTop(ax, [h1 h2], {'Phase', sprintf('Baseline (order %d, fitted outside %.1f-%.1f MHz of %s)', ...
    baseOrder, baseLo/1e6, baseHi/1e6, baseTag(baseFrom, recName))}, 2, 0.25);
ylabel(ax, 'Phase (°)'); letter(ax, 'a');
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 1.4 15.4 5.6]); hold(ax, 'on')
h1 = plot(ax, fM, phC, '-', 'Color', cRaw, 'LineWidth', 0.5);
h2 = plot(ax, fM, phS, '-', 'Color', cData, 'LineWidth', 1);
h3 = plot(ax, f0A/1e6, depthA, 'v', 'MarkerFaceColor', cFit, 'MarkerEdgeColor', 'none', 'MarkerSize', 6);
labs = {'Corrected', sprintf('Smoothed (%g kHz)', smoothHz/1e3), ...
    sprintf('f0 = %.3f MHz (parabola %.3f)', f0A/1e6, f0Apar/1e6)};
if ~isnan(QA), labs{3} = sprintf('%s, Q = %.2f', labs{3}, QA); end
hs = [h1 h2 h3];
if ~isnan(QA)
    hs(4) = plot(ax, [fAlo fAhi]/1e6, depthA/2*[1 1], '-', 'Color', cFit, 'LineWidth', 1.5);
    labs{4} = sprintf('Half depth: %.3f MHz', (fAhi - fAlo)/1e6);
end
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx);
legendTop(ax, hs, labs, 2, 0.4);
xlabel(ax, 'Frequency (MHz)'); ylabel(ax, 'Corrected phase (°)'); letter(ax, 'b');
saveFig(fig, outDir, [recName '_phase_dip']);

% 3: Method B
fig = newFig(18, figTitle);
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 11.6 15.4 5.6]); hold(ax, 'on')
if ownBase, shadeBase(ax, baseLo, baseHi, cShade); end
h1 = plot(ax, fM, real(Z), '-', 'Color', cData, 'LineWidth', 0.8);
h2 = plot(ax, fM, reBase, '--', 'Color', cBase, 'LineWidth', 1.2);
h3 = plot(ax, fM, imag(Z), '-', 'Color', cFit, 'LineWidth', 0.8);
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx); ax.XTickLabel = [];
legendTop(ax, [h1 h2 h3], {'Re(Z)', 'Re baseline', 'Im(Z)'}, 3, 0.25);
ylabel(ax, 'Z loop (Ω)'); letter(ax, 'a');
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 5.4 15.4 5.6]); hold(ax, 'on')
h1 = plot(ax, fM, dR, '-', 'Color', cData, 'LineWidth', 0.8);
h2 = plot(ax, fM(sel), model(pB(1:numel(p0)), fM(sel)), '-', 'Color', cFit, 'LineWidth', 1.5);
labs = {'ΔR = Re(Z) − baseline', sprintf('Lorentzian: f0 = %.3f MHz ± %.1f kHz, Q = %.2f ± %.2f, A = %.2f ± %.2f Ω', ...
    pB(2), eB(2)*1e3, pB(3), eB(3), pB(1), eB(1))};
hs = [h1 h2];
if ~isnan(QBmf)
    hs(3) = plot(ax, [fBlo fBhi]/1e6, pkB/2*[1 1], '-', 'Color', cBase, 'LineWidth', 1.5);
    labs{3} = sprintf('Half maximum: centre %.3f MHz, Q = %.2f', f0Bmf/1e6, QBmf);
end
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx); ax.XTickLabel = [];
legendTop(ax, hs, labs, 1, 0.6);
ylabel(ax, 'ΔR (Ω)'); letter(ax, 'b');
ax = axes(fig, 'Units', 'centimeters', 'Position', [2.0 1.4 15.4 3.0]); hold(ax, 'on')
plot(ax, fM(sel), resid, '-', 'Color', cData, 'LineWidth', 0.6);
yline(ax, 0, '-', 'Color', ink, 'LineWidth', 0.5);
hold(ax, 'off'); styleAxes(ax); xlim(ax, fx);
xlabel(ax, 'Frequency (MHz)'); ylabel(ax, 'Residual (Ω)'); letter(ax, 'c');
saveFig(fig, outDir, [recName '_reflected_R']);
end

%% Local functions
function [f, mag, ph, hdr] = loadNA(file)
% WaveForms Network Analyzer CSV: '#' header lines, one names row, then data
txt = readlines(file);
hdr = txt(startsWith(txt, '#'));
iNames = find(~startsWith(txt, '#') & strlength(txt) > 0, 1);
names = strtrim(split(txt(iNames), ','));
d = readmatrix(file, 'NumHeaderLines', iNames, 'Delimiter', ',');
f   = d(:, names == "Frequency (Hz)");
mag = d(:, names == "Channel 2 Magnitude (dB)");
ph  = d(:, names == "Channel 2 Phase (deg)");
end

function [fLo, fHi] = halfCrossings(f, y, level, i0)
% Frequencies where the peak y(i0) falls to level on each side (linear interp), NaN if outside the sweep
lo = find(y(1:i0) < level, 1, 'last');
hi = i0 - 1 + find(y(i0:end) < level, 1);
fLo = NaN; fHi = NaN;
if ~isempty(lo), fLo = interp1(y([lo lo+1]), f([lo lo+1]), level); end
if ~isempty(hi), fHi = interp1(y([hi-1 hi]), f([hi-1 hi]), level); end
end

function fv = parabolaVertex(f, y, ys, i0, frac)
% Vertex of a parabola through the raw y where the smoothed ys stays above frac*ys(i0) around i0
k = ys >= frac*ys(i0);
lo = find(~k(1:i0), 1, 'last') + 1; if isempty(lo), lo = 1; end
hi = i0 - 1 + find(~k(i0:end), 1) - 1; if isempty(hi), hi = numel(f); end
x = f(lo:hi)/1e6 - f(i0)/1e6;
p = polyfit(x, y(lo:hi), 2);
fv = (f(i0)/1e6 - p(2)/(2*p(1))) * 1e6;
end

function v = nearestE24(x, e24)
% Nearest E24 value to |x|, with the sign of x (negative: capacitance to remove)
vals = e24(:) * 10.^(-1:2); vals = vals(:);
[~, i] = min(abs(vals - abs(x))); v = sign(x) * vals(i);
end

function s = baseTag(baseFrom, recName)
if strcmp(baseFrom, recName), s = 'this sweep'; else, s = baseFrom; end
end

function shadeBase(ax, lo, hi, c)
% Shade the resonance region (the baseline is fitted outside it)
xregion(ax, lo/1e6, hi/1e6, 'FaceColor', c, 'FaceAlpha', 1, 'EdgeColor', 'none', 'HandleVisibility', 'off');
end

function fig = newFig(h, ttl)
% h cm of axes area, plus a 0.7 cm title line naming the recording and tuning capacitor
fig = figure('Units', 'centimeters', 'Position', [2 2 18 h + 0.7], 'Color', 'w');
try theme(fig, 'light'); catch, end
set(fig, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', 'DefaultTextInterpreter', 'none');
annotation(fig, 'textbox', 'Units', 'centimeters', 'Position', [0.3 h 17.4 0.6], 'String', ttl, ...
    'EdgeColor', 'none', 'FontName', 'Arial', 'FontSize', 10, 'FontWeight', 'bold', ...
    'Color', [0.15 0.15 0.15], 'Interpreter', 'none', 'VerticalAlignment', 'middle');
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

function saveFig(fig, outDir, name)
exportgraphics(fig, fullfile(outDir, [name '.png']), 'Resolution', 300, 'BackgroundColor', 'white');
fprintf('Saved %s.png\n', fullfile(outDir, name));
end

function legendTop(ax, h, labs, ncol, frac)
% Legend across the top, in headroom (frac of the data range) added above the data
yl = ylim(ax);
ylim(ax, [yl(1), yl(2) + frac*diff(yl)]);
legend(ax, h, labs, 'Location', 'north', 'NumColumns', ncol, 'Box', 'off', 'FontSize', 9, 'Interpreter', 'none');
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 10, 'LabelFontSizeMultiplier', 1.1, 'LineWidth', 0.6, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', 'XColor', ink, 'YColor', ink, ...
    'Layer', 'top');
ax.Toolbar.Visible = 'off';
end

function letter(ax, s)
text(ax, -0.09, 1.08, s, 'Units', 'normalized', 'FontSize', 13, 'FontWeight', 'bold', 'Color', [0.15 0.15 0.15]);
end
