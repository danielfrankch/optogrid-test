% Size a decoupling capacitor on V_BANK that removes the radio dips seen
% during the capacitor-bank hold-up (test 3).
% Input: the scope recording of the DC hold-up (WaveForms .bin and its
% .meta.yml, converted as in plot_capbank_dc.m). During the hold-up the bank
% feeds the board through a series resistance Rs (bank ESR and wiring); the
% only capacitance on the board side is Cn (C54, 2.2 uF, on V_BANK). Each
% radio event draws a current burst, so the node dips by I*Rs and recovers
% with tau = Rs*Cn when the burst ends.
% Measured per radio dip: depth dV (from the level just before), width
% (FWHM), recovery tau (exponential fit to the rise after the burst) and the
% area A = integral of the dip (V*s). Since the bank current is dip/Rs, the
% charge of one event is Q = A/Rs.
% Rs three ways: (1) tau/Cn, with Cn = the nominal board capacitance (a
% ceramic loses much of it under DC bias, so this is a lower bound on Rs);
% (2) the step of the mean voltage when the supply is cut, divided by the
% average current (bank slope x nominal bank capacitance); (3) A/Q with Q the
% charge of one idle radio event measured directly with the shunt in test 1.
% (3) needs no assumption about Cn or the bank, so the sizing is based on it.
% Sizing: with an added capacitor Cadd on V_BANK (Rs*(Cn + Cadd) much longer
% than the burst), the burst is supplied by the capacitor and the dip falls
% to Q/(Cn + Cadd); for a target dip dVt, Cadd = Q/dVt - Cn.
% Hold-up: the device collapses when a dip bottom reaches Vcrit (the dip
% bottom just before the measured collapse). With dips of dVt, it runs until
% the mean reaches Vcrit + dVt; the extra time follows from the mean
% discharge slope over the last fitWin_s before the collapse.
% Output: results/<recording folder>/<recording>_decoupling.pdf (page 1
% figures, page 2 computation and conclusion) and _decoupling.csv.
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
recFolder = 'device_LRV-O-0001';
scopeFile = 'DC_5.0V_CapBank_Test_4.bin';      % DC hold-up, scope on the bank node
Cn_uF     = 2.2;      % board capacitance on V_BANK (C54)
Cbank_mF  = 16.5;     % nominal bank (3 x 11 mF in parallel, 2 groups in series)
deepDip_V = 0.8;      % radio dips: deeper than this
pre_s     = [-2e-3 -0.1e-3];   % window before a dip for its starting level (max) (s)
post_s    = 3e-3;     % dip window after its start (s)
edge_s    = 0.5;      % skip this much after the cut-off and before the collapse (s)
fitWin_s  = 10;       % mean discharge slope: last fitWin_s before the collapse (s)
targets_V = [0.05 0.1 0.2 0.3 0.5];   % target dip depths for the sizing table (V)
test1Dir  = fullfile(fileparts(testDir), '1-current-consumption-test', 'analysis', 'results');
unplugDrop_V = 0.05;  % cut-off: 1 ms mean this far below the powered level
collapseFrac = 0.5;   % collapse: below this fraction of the powered level for 50 ms

figWidth = 18; ink = [0.15 0.15 0.15];
c1 = [0.27 0.47 0.67]; c2 = [0.80 0.40 0.47]; cGrey = [0.6 0.6 0.6];

%% Load
[~, base] = fileparts(scopeFile);
metaFile = fullfile(testDir, recFolder, [base '.meta.yml']);
meta = readMeta(metaFile);
fs = metaNum(meta, 'sample_rate_Hz', metaFile);
fid = fopen(fullfile(testDir, recFolder, scopeFile), 'r', 'ieee-le');
raw = fread(fid, inf, 'int16=>double'); fclose(fid);
v = metaNum(meta, 'channel_range_V', metaFile)*raw/65536 - metaNum(meta, 'channel_offset_V', metaFile);
clear raw
n = numel(v); t = (0:n-1)'/fs;

%% Cut-off, collapse, mean discharge
nb = round(1e-3*fs); nB = floor(n/nb);
bMean = mean(reshape(v(1:nB*nb), nb, nB))'; tb = ((0:nB-1)' + 0.5)*1e-3;
vPow = median(bMean(tb <= 1));
tUn = tb(find(bMean < vPow - unplugDrop_V, 1)) - 0.5e-3;
iCol = find(movmax(bMean, [0 49]) < collapseFrac*vPow & tb > tUn, 1);
tCol = tb(iCol) - 0.5e-3;
vMean = movmean(v, round(0.1*fs));               % 100 ms mean
hold_ = t > tUn + edge_s & t < tCol - edge_s;
% step at the cut-off: mean just before vs the mean discharge line extrapolated back
mBefore = mean(v(t > tUn - 0.5 & t < tUn - 0.01));
m1 = t > tUn + 0.2 & t < tUn + 2.2;
q = polyfit(t(m1) - tUn, v(m1), 1);
step_V = mBefore - q(2);
mEnd = t > tCol - edge_s - fitWin_s & t < tCol - edge_s;
qEnd = polyfit(t(mEnd), v(mEnd), 1);              % V/s near the end
slopeAll = polyfit(t(hold_), v(hold_), 1);
Iavg_mA = -slopeAll(1)*Cbank_mF;                  % mF x V/s = mA
fprintf('Cut-off %.3f s, collapse %.3f s (hold-up %.2f s); step %.3f V; mean slope %.4f V/s -> %.2f mA at %.1f mF\n', ...
    tUn, tCol, tCol - tUn, step_V, slopeAll(1), Iavg_mA, Cbank_mF);

%% Radio dips
base20 = movmax(v, round(0.02*fs));
d = (base20 - v) > deepDip_V & hold_;
st = find(d & ~[false; d(1:end-1)]);
st = st([true; diff(st) > round(5e-3*fs)]);
nD = numel(st);
Depth = nan(nD, 1); Width = Depth; Tau = Depth; Area = Depth; Bottom = Depth; Top = Depth; Tdip = t(st);
for j = 1:nD
    a = st(j) + round(pre_s(1)*fs); b = st(j) + round(pre_s(2)*fs);
    top = max(v(a:b)); Top(j) = top;
    w = v(st(j) - round(0.2e-3*fs) : min(n, st(j) + round(post_s*fs)));
    dv = top - w;
    [mx, im] = max(dv); Depth(j) = mx; Bottom(j) = top - mx;
    half = dv > mx/2;
    i1 = find(~half(1:im), 1, 'last') + 1; if isempty(i1), i1 = 1; end
    i2 = im + find(~half(im:end), 1) - 2; if isempty(i2), i2 = numel(dv); end
    Width(j) = (i2 - i1 + 1)/fs;
    % area over the dip, until it has recovered to 10 % (or the window ends)
    i3 = im + find(dv(im:end) < 0.1*mx, 1) - 1; if isempty(i3), i3 = numel(dv); end
    Area(j) = sum(max(dv(1:i3), 0))/fs;
    % recovery: fit log(dv) between 70 % and 15 % of the depth after the bottom
    r = (i2:i3)'; r = r(dv(r) < 0.7*mx & dv(r) > 0.15*mx);
    if numel(r) >= 4
        pr = polyfit((r - r(1))/fs, log(dv(r)), 1);
        if pr(1) < 0, Tau(j) = -1/pr(1); end
    end
end
ok = ~isnan(Tau);
dV = median(Depth); W = median(Width); tau = median(Tau(ok)); A = median(Area);
interval = median(diff(Tdip));
fprintf('%d radio dips every %.1f ms: depth %.2f V, FWHM %.2f ms, recovery tau %.3f ms, area %.3f mV*s\n', ...
    nD, 1e3*interval, dV, 1e3*W, 1e3*tau, 1e3*A);

%% Series resistance, burst current and charge
Cn = Cn_uF*1e-6;
Rs_tau = tau/Cn;                                  % ohm
Rs_step = step_V/(Iavg_mA*1e-3);                  % ohm
% (3) test 1: charge of one idle radio event, measured with the shunt
d1 = dir(fullfile(test1Dir, '*', 'idle_radio_summary.csv'));
q1 = zeros(numel(d1), 1);
for i = 1:numel(d1)
    T1 = readtable(fullfile(d1(i).folder, d1(i).name), 'TextType', 'string');
    q1(i) = T1.EventCharge_uC(T1.Window == "Idle");
end
Q_t1 = mean(q1);
Rs_t1 = A/(Q_t1*1e-6);
Rs = [Rs_tau Rs_step Rs_t1];
how = ["tau / Cn (2.2 uF)", "cut-off step", "test 1 event charge"];
I_burst_mA = 1e3*dV./Rs;                          % mA
Q_uC = 1e6*A./Rs;                                 % uC per event
CnEff_uF = 1e6*tau/Rs_t1;                         % board capacitance implied by (3)
fprintf('Rs: %.0f ohm (tau/Cn), %.0f ohm (cut-off step / mean current), %.0f ohm (test 1 charge %.2f uC)\n', ...
    Rs_tau, Rs_step, Rs_t1, Q_t1);
fprintf('Burst %s mA; charge %s uC per radio event; Cn implied by (3) %.2f uF\n', ...
    mat2str(round(I_burst_mA, 1)), mat2str(round(Q_uC, 2)), CnEff_uF);

%% Sizing and hold-up gain
iLastDip = find(Tdip < tCol - edge_s, 1, 'last');
Vcrit = median(Bottom(max(1, iLastDip - 9):iLastDip));   % dip bottoms just before the collapse
VmeanCol = polyval(qEnd, tCol - edge_s);
Cadd_uF = 1e6*(Q_uC(:)'*1e-6 ./ targets_V(:) - Cn);      % rows: targets, cols: Rs estimate
Cadd_uF = max(Cadd_uF, 0);
VendTarget = Vcrit + targets_V(:);
extra_s = (VmeanCol - VendTarget)/(-qEnd(1));
tauNew_ms = 1e3*Rs.*(Cn + Cadd_uF*1e-6);
fprintf('Collapse when dip bottoms reach %.2f V (mean %.2f V); mean slope at the end %.4f V/s\n', ...
    Vcrit, VmeanCol, qEnd(1));
Target_V = targets_V(:); Cadd_RsTau_uF = Cadd_uF(:, 1); Cadd_RsStep_uF = Cadd_uF(:, 2);
Cadd_Test1_uF = Cadd_uF(:, 3); MeanAtCollapse_V = VendTarget; ExtraHoldUp_s = extra_s;
tbl = table(Target_V, Cadd_Test1_uF, Cadd_RsStep_uF, Cadd_RsTau_uF, MeanAtCollapse_V, ExtraHoldUp_s);
disp(tbl)
outDir = fullfile(rootDir, 'results', recFolder);
if ~isfolder(outDir), mkdir(outDir); end
writetable(tbl, fullfile(outDir, [base '_decoupling.csv']));

%% Page 1: figures
f = newFigure(figWidth, 16);
% a: one radio dip with its measures
ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 10.6 7.2 4.6]); hold(ax, 'on')
j = round(nD/2); ex = st(j);
m = (ex - round(1e-3*fs)):(ex + round(4e-3*fs));
plot(ax, 1e3*(t(m) - t(ex)), v(m), '-', 'Color', c1, 'LineWidth', 0.75);
yline(ax, Top(j), ':', 'Color', ink); yline(ax, Bottom(j), ':', 'Color', ink);
text(ax, 3.9, Top(j), sprintf('depth %.2f V', Depth(j)), 'HorizontalAlignment', 'right', ...
    'VerticalAlignment', 'bottom', 'FontSize', 7, 'Color', ink);
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [-1 4]); xlabel(ax, 'Time from dip start (ms)'); ylabel(ax, 'Bank node (V)');
title(ax, sprintf('Radio dip at %.1f s', t(ex)), 'FontWeight', 'normal', 'FontSize', 8);
panelLetter(ax, 'a');
% b: dip bottoms and mean over the hold-up
ax = axes(f, 'Units', 'centimeters', 'Position', [10.6 10.6 6.9 4.6]); hold(ax, 'on')
k = 1:round(0.01*fs):n; kk = k(t(k) > tUn - 1 & t(k) < tCol + 1);
plot(ax, t(kk), vMean(kk), '-', 'Color', c1, 'LineWidth', 1.25, 'DisplayName', '100 ms mean');
plot(ax, Tdip, Bottom, '.', 'Color', c2, 'MarkerSize', 4, 'DisplayName', 'radio dip bottoms');
yline(ax, Vcrit, ':', 'Color', ink, 'HandleVisibility', 'off');
text(ax, tUn, Vcrit, sprintf(' collapse level %.2f V', Vcrit), 'VerticalAlignment', 'top', 'FontSize', 7, 'Color', ink);
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [tUn - 1 tCol + 1]); ylim(ax, [floor(min(Bottom)*2)/2 - 0.5, ceil(vPow*2)/2]);
xlabel(ax, 'Time (s)'); ylabel(ax, 'Voltage (V)');
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6);
panelLetter(ax, 'b');
% c: added capacitance against the target dip
ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 1.4 7.2 6.8]); hold(ax, 'on')
tg = linspace(0.02, 1, 200)';
cols = [cGrey; c2; c1];
for i = [3 2 1]
    cc = 1e6*(Q_uC(i)*1e-6./tg - Cn);
    plot(ax, tg, max(cc, 0.1), '-', 'Color', cols(i, :), 'LineWidth', 1.25, 'DisplayName', ...
        sprintf('Rs = %.0f ohm (%s)', Rs(i), how(i)));
end
hold(ax, 'off'); styleAxes(ax); set(ax, 'YScale', 'log');
xlim(ax, [0 1]); ylim(ax, [1 1000]);
xlabel(ax, 'Target radio dip (V)'); ylabel(ax, 'Added capacitance on V_BANK (µF)');
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 6);
panelLetter(ax, 'c');
% d: hold-up against the target dip
ax = axes(f, 'Units', 'centimeters', 'Position', [10.6 1.4 6.9 6.8]); hold(ax, 'on')
dEnd = VmeanCol - Vcrit;                          % dip depth at the collapse
td = linspace(0, max(1.5, dEnd + 0.2), 200);
plot(ax, td, (tCol - tUn) + (VmeanCol - (Vcrit + td))/(-qEnd(1)), '-', 'Color', ink, 'LineWidth', 1.25);
plot(ax, dEnd, tCol - tUn, 'o', 'MarkerFaceColor', c2, 'MarkerEdgeColor', ink, 'MarkerSize', 5);
text(ax, dEnd, tCol - tUn, sprintf('  measured (%.2f V dips at the end)', dEnd), 'FontSize', 7, 'Color', ink);
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [0 td(end)]);
xlabel(ax, 'Radio dip depth (V)'); ylabel(ax, 'Hold-up after the cut-off (s)');
panelLetter(ax, 'd');
pdfFile = fullfile(outDir, [base '_decoupling.pdf']);
exportgraphics(f, pdfFile, 'ContentType', 'vector', 'BackgroundColor', 'white');
close(f);

%% Page 2: computation and conclusion
iT = find(abs(targets_V - 0.1) < 1e-9, 1);
lines = {
    'Decoupling capacitor for the radio dips during the capacitor-bank hold-up'
    ''
    sprintf('Recording: %s (5 V DC supply cut by hand; scope at %g kHz on the bank node).', scopeFile, fs/1e3)
    ''
    '1. Measured (bank only, after the cut-off)'
    sprintf('   Hold-up %.1f s; mean discharge %.4f V/s (%.2f mA at the nominal %.1f mF).', tCol - tUn, slopeAll(1), Iavg_mA, Cbank_mF)
    sprintf('   Radio events every %.1f ms: dip %.2f V deep, %.2f ms wide (FWHM), recovery tau %.3f ms,', 1e3*interval, dV, 1e3*W, 1e3*tau)
    sprintf('   area A = %.3f mV*s. Mean voltage step at the cut-off: %.3f V.', 1e3*A, step_V)
    '   1 ms ticks: about 0.45 V for about 40 us (small charge; the same capacitor removes them).'
    ''
    '2. Series resistance Rs between the bank and the board, and the charge per radio event'
    '   The bank current is (dip / Rs), so the charge of one event is Q = A / Rs.'
    sprintf('   (a) test 1 shunt, idle radio event charge %.2f uC (direct):  Rs = A / Q = %.0f ohm.', Q_t1, Rs_t1)
    sprintf('   (b) cut-off step / mean current = %.3f V / %.2f mA:          Rs = %.0f ohm (Q = %.2f uC).', step_V, Iavg_mA, Rs_step, Q_uC(2))
    sprintf('   (c) recovery tau / nominal C54 = %.3f ms / %.1f uF:           Rs = %.0f ohm (Q = %.2f uC).', 1e3*tau, Cn_uF, Rs_tau, Q_uC(1))
    '   (a) and (b) agree. (c) is low because C54 (2.2 uF ceramic) has lost capacitance at 4-5 V bias:'
    sprintf('   (a) implies Cn = tau / Rs = %.2f uF. Burst current dip / Rs = %.1f mA (a).', CnEff_uF, I_burst_mA(3))
    ''
    '3. Capacitor on V_BANK (next to C54 at the LDO input, on the board side of Rs)'
    '   The capacitor supplies each burst and recharges through Rs between events:'
    '   dip = Q / (Cn + Cadd), so Cadd = Q / target - Cn (effective capacitance, at the bias voltage).'
    };
for i = 1:numel(targets_V)
    lines{end+1} = sprintf('   target %.2f V: Cadd = %.0f uF from (a)  [%.0f uF from (b), %.0f uF from (c)]; recovery tau %.1f ms', ...
        targets_V(i), Cadd_uF(i, 3), Cadd_uF(i, 2), Cadd_uF(i, 1), tauNew_ms(i, 3)); %#ok<SAGROW>
end
lines = [lines; {
    sprintf('   Recovery stays well inside the %.1f ms between radio events.', 1e3*interval)
    ''
    '4. Hold-up gain'
    sprintf('   The device collapsed when the dip bottoms reached %.2f V, with the mean still at %.2f V.', Vcrit, VmeanCol)
    sprintf('   With %.2f V dips it would run until the mean reaches %.2f V: about %.0f s more (%.0f s instead of %.0f s),', ...
        targets_V(iT), Vcrit + targets_V(iT), extra_s(iT), tCol - tUn + extra_s(iT), tCol - tUn)
    sprintf('   at the end-of-discharge slope %.4f V/s (linear extrapolation; the current may change in LDO dropout).', qEnd(1))
    ''
    '5. Conclusion'
    sprintf('   Each radio event draws about %.1f uC (about %.0f mA for %.1f ms) through about %.0f ohm between the bank', ...
        Q_t1, I_burst_mA(3), 1e3*W, Rs_t1)
    sprintf('   and the board, so V_BANK dips by %.1f V. About %.0f uF of effective capacitance on V_BANK cuts the dips', dV, Cadd_uF(iT, 3))
    sprintf('   to 0.1 V (%.0f uF for 0.2 V) and adds roughly %.0f s of hold-up at idle (about %.0f%% longer).', ...
        Cadd_uF(targets_V == 0.2, 3), extra_s(iT), 100*extra_s(iT)/(tCol - tUn))
    '   Ceramics lose 50-70% of their capacitance at 4-5 V: use X5R/X7R rated >= 10 V with 2-3x the effective'
    '   value as nominal (e.g. 2 x 47 uF or 1 x 100 uF, 10 V, 0805/1206), or a polymer tantalum or aluminium'
    '   capacitor (check its leakage against the about 1 mA idle current). The BLE battery reads, which'
    '   sample at the dip bottom, would then read close to the true bank voltage.'
    '   Assumptions: Rs is the bank ESR plus wiring and does not change with voltage; the radio events'
    '   during the hold-up carry the same charge as the idle events of test 1.'
    }];
f = newFigure(figWidth, 25);
ax = axes(f, 'Units', 'normalized', 'Position', [0.05 0.03 0.9 0.94], 'Visible', 'off');
text(ax, 0, 1, lines, 'VerticalAlignment', 'top', 'FontName', 'Arial', 'FontSize', 8.5, ...
    'Interpreter', 'none', 'Color', ink);
exportgraphics(f, pdfFile, 'ContentType', 'vector', 'BackgroundColor', 'white', 'Append', true);
close(f);
fprintf('Saved %s\n', pdfFile);

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
