% Simulate the capacitor-bank hold-up after the supply is cut (test 3.2),
% radio dips included, and extrapolate it to other banks.
% Circuit: ideal bank C (nSer groups in series of nPar cells in parallel)
% and its balancing resistors, then the bank ESR to the board node, which
% holds Cnode and draws the device load:
%   bank:  C dVb/dt = -(Vb - Vn)/ESR - Vb/Rbal
%   node:  Vn relaxes to Vb - ESR*I_load with tau = ESR*Cnode (exact step)
% Device load (the same in every case):
%   floor:  I = a + b*exp((Vn - 4.5 V)/s), voltage dependent (leakage-like)
%   ticks:  1 kHz tick, fixed current pulse shape
%   radio:  connection event every 22.5 ms, fixed current segments
% The tick and radio pulses keep their timing and shape; their current is
% scaled by (Vn/vRef)^eventExp. In the recording the radio dip depth falls
% with the node voltage (about as V^1.3: 1.63 V at 4.64 V, 1.20 V at 3.68 V),
% so the events do not draw a fixed charge; eventExp = 0 would give a fixed
% charge per event instead.
% All three were extracted from the 5.0 V DC-cut scope recording (no added
% capacitor, 20261013_190812) by inverting the circuit at ESR = 320 ohm and
% the nominal 16.5 mF; see "Load" for the values. Every simulated radio event
% is the same, while recorded ones vary and the device dies on a deep one;
% so the simulated device stops when the median of its radio-dip bottoms over
% the last second reaches vStop, the same median in the recording's last second.
% Case 1 (the measured board) is checked against that recording; the other
% cases show what a different bank would do.
% Output: results/capbank_holdup_simulation.png, and the hold-up per case
% in the command window.
clear; clc; close all;

%% Cases: bank ESR and cells
cases = struct( ...
    'name',     {'Measured bank', 'Lower-ESR bank'}, ...
    'esr_ohm',  {320, 160}, ...      % bank ESR (bank to board node)
    'nPar',     {3, 3}, ...          % cells in parallel per group
    'nSer',     {2, 2}, ...          % groups in series
    'cell_mF',  {11, 11.5});         % capacitance of one cell

%% Board and start
cNode_uF   = 0.72;    % effective board capacitance on V_BANK (C54 at bias; dip recovery tau 0.23 ms at 320 ohm)
rBal_kOhm  = 400;     % balancing resistors across the bank (2 x 200 kOhm)
v0         = 5.009;   % bank and node at the cut (V, powered level of the recording)
fs         = 200e3;   % simulation rate (Hz), as the scope
tMax_s     = 90;      % longest simulated hold-up (s)

%% Load (fixed): extracted from the recording at ESR 320 ohm, 16.5 mF
floorA_mA = 0.159; floorB_mA = 0.532; floorS_V = 0.841;   % floor current vs node voltage
vRef_V    = 4.03;     % node voltage at which the pulses below are given (mean over the recorded hold-up)
eventExp  = 1.3;      % pulse current scales with (Vn/vRef)^eventExp (0 = fixed charge); 1.3 matches the dip depth trend
tickPeriod_ms = 0.975; tick_mA = 4.0; tickDur_ms = 0.05;   % 0.20 uC per tick
radioPeriod_ms = 22.5;
% radio event above the floor, mean of the aligned recorded events:
% [start (ms) from the event start, duration (ms), current (mA)]
radioSeg = [0     0.06 9.0      % precursor (0.54 uC)
            1.55  0.06 8.2      % main burst onset
            1.61  0.40 4.4
            2.01  0.20 2.6
            2.21  0.25 0.7];    % 3.47 uC in total
% Averaging over event-to-event jitter smears the main burst; it is made
% kSharp times taller and shorter (same charge); kSharp and eventExp are set
% so the median dip depth follows the recording (1.63 V at the start,
% 1.20 V at 3.7 V)
kSharp = 2.0;
main = 2:size(radioSeg, 1);
radioSeg(main, 2:3) = radioSeg(main, 2:3).*[1/kSharp kSharp];
radioSeg(main, 1) = radioSeg(main(1), 1) + [0; cumsum(radioSeg(main(1:end-1), 2))];

%% Recording to compare with
here = fileparts(mfilename('fullpath')); if isempty(here), here = pwd; end
recFile = fullfile('..', 'device_LRV-O-0001', '2c-dc-cut-scope-and-ble', '20261013_190812_dc-cut_5.0V_scope.bin');
recDrop_V = 0.05;     % cut-off: first 1 ms mean this far below the powered level

%% Recording (time from the cut, up to its collapse)
meta = fileread(strrep(fullfile(here, recFile), '.bin', '.meta.yml'));
num = @(key) str2double(regexp(meta, [key ':\s*([-\d.]+)'], 'tokens', 'once'));
fid = fopen(fullfile(here, recFile), 'r', 'ieee-le'); raw = fread(fid, inf, 'int16=>double'); fclose(fid);
vr = num('channel_range_V')*raw/65536 - num('channel_offset_V'); clear raw
fsr = num('sample_rate_Hz'); nb = round(1e-3*fsr);
bm = mean(reshape(vr(1:floor(numel(vr)/nb)*nb), nb, []))';
iCut = (find(bm < median(bm(1:1000)) - recDrop_V, 1) - 1)*nb + 1;
vr = vr(iCut:end); tr = (0:numel(vr)-1)'/fsr;
iEnd = find(movmax(bm(ceil(iCut/nb):end), [0 49]) < 0.5*v0, 1)*nb;   % collapse: 1 ms means below half for 50 ms
rec.t = tr(1:iEnd); rec.vn = vr(1:iEnd);
[tDip, bot] = dipBottoms(rec.t, rec.vn);
vStop = median(bot(tDip > tDip(end) - 1)); rec.tCol = tDip(end);
fprintf('Recording: hold-up %.2f s (last radio dip); median dip bottom in its last second %.3f V = vStop\n', rec.tCol, vStop);


%% Event current over the whole run (both periods are whole numbers of samples)
dt = 1/fs; N = round(tMax_s*fs);
radio = zeros(round(radioPeriod_ms*1e-3*fs), 1);
for s = 1:size(radioSeg, 1)
    k = round(radioSeg(s, 1)*1e-3*fs) + (1:round(radioSeg(s, 2)*1e-3*fs));
    radio(k) = radio(k) + radioSeg(s, 3)*1e-3;
end
tick = zeros(round(tickPeriod_ms*1e-3*fs), 1);
tick(1:round(tickDur_ms*1e-3*fs)) = tick_mA*1e-3;
iRadio = repmat(radio, ceil(N/numel(radio)), 1); iTick = repmat(tick, ceil(N/numel(tick)), 1);
iEvent = iRadio(1:N) + iTick(1:N); clear iRadio iTick
fprintf('Load at %.2f V: radio %.2f uC every %.1f ms, tick %.2f uC every %.3f ms; floor %.2f mA at 4.5 V\n', ...
    vRef_V, 1e6*sum(radio)*dt, radioPeriod_ms, 1e6*sum(tick)*dt, tickPeriod_ms, floorA_mA + floorB_mA);

%% Simulate each case
sim = struct('t', {}, 'vn', {}, 'tCol', {});
for c = 1:numel(cases)
    R = cases(c).esr_ohm;
    Cb = cases(c).nPar*cases(c).cell_mF*1e-3/cases(c).nSer;   % F
    Rbal = rBal_kOhm*1e3; ex = exp(-dt/(R*cNode_uF*1e-6));
    vb = v0; vn = v0; vs = zeros(N, 1, 'single'); tCol = NaN; nR = numel(radio); botR = inf;
    nWin = round(1/(radioPeriod_ms*1e-3)); bots = inf(nWin, 1); p = 0;   % dip bottoms of the last 1 s
    for j = 1:N
        iL = 1e-3*(floorA_mA + floorB_mA*exp((vn - 4.5)/floorS_V)) + iEvent(j)*(vn/vRef_V)^eventExp;
        vt = vb - iL*R;  vn = vt + (vn - vt)*ex;             % node: exact relaxation over dt
        vb = vb - dt*((vb - vn)/R + vb/Rbal)/Cb;             % bank: charge through the ESR and leakage
        vs(j) = vn; botR = min(botR, vn);
        if mod(j, nR) == 0                                   % end of a radio period: its dip bottom
            p = p + 1; bots(mod(p - 1, nWin) + 1) = botR; botR = inf;
            if p >= nWin && median(bots) < vStop, tCol = j*dt; break, end   % as vStop is defined
        end
    end
    sim(c).t = (0:j-1)'*dt; sim(c).vn = double(vs(1:j)); sim(c).tCol = tCol;
    [~, b] = dipBottoms(sim(c).t, sim(c).vn);
    fprintf('%-15s ESR %3d ohm, %d x (%d x %.1f mF) = %.2f mF: hold-up %.2f s (first dip bottom %.2f V)\n', ...
        cases(c).name, R, cases(c).nSer, cases(c).nPar, cases(c).cell_mF, 1e3*Cb, tCol, b(1));
end

%% Figure
ink = [0.15 0.15 0.15]; cRec = [0.55 0.55 0.55]; cSim = [0.27 0.47 0.67; 0.80 0.40 0.47];
f = figure('Units', 'centimeters', 'Position', [2 2 18 14], 'Color', 'w');
try theme(f, 'light'); catch, end
set(f, 'DefaultAxesFontName', 'Arial', 'DefaultTextFontName', 'Arial', 'DefaultTextInterpreter', 'none');
% a: whole hold-up, 1 ms min-max envelope and 50 ms mean
ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 8.2 16 5.2]); hold(ax, 'on')
traces = [{rec}, num2cell(sim(:)')];
lab = [{'Recorded (20261013-190812)'}, arrayfun(@(c) sprintf('%s: ESR %d ohm, %.2f mF', cases(c).name, ...
    cases(c).esr_ohm, cases(c).nPar*cases(c).cell_mF/cases(c).nSer), 1:numel(cases), 'UniformOutput', false)];
col = [cRec; cSim]; h = gobjects(numel(traces), 1);
for i = 1:numel(traces)
    [te, lo, hi, mu] = envelope1ms(traces{i}.t, traces{i}.vn);
    patch(ax, [te; flipud(te)], [lo; flipud(hi)], col(i, :), 'EdgeColor', 'none', 'FaceAlpha', 0.25);
    h(i) = plot(ax, te, movmean(mu, 50), '-', 'Color', col(i, :), 'LineWidth', 1.2);
    plot(ax, traces{i}.tCol, vStop, 'v', 'MarkerFaceColor', col(i, :), 'MarkerEdgeColor', 'none');
end
yline(ax, vStop, ':', sprintf('device stops: typical dip bottom reaches %.2f V', vStop), 'Color', ink, 'FontSize', 7, ...
    'LabelHorizontalAlignment', 'right');
hold(ax, 'off'); styleAxes(ax);
xlim(ax, [0 1.05*max(cellfun(@(x) x.tCol, traces))]); ylim(ax, [2 5.2]);
xlabel(ax, 'Time after the supply cut (s)'); ylabel(ax, 'Bank-node voltage (V)');
legend(ax, h, lab, 'Location', 'northeast', 'Box', 'off', 'FontSize', 7);
text(ax, 0.01, 0.04, 'shaded: 1 ms min-max (radio dips); line: 50 ms mean; triangle: device stops', ...
    'Units', 'normalized', 'FontSize', 6.5, 'Color', ink);
text(ax, -0.07, 1.04, 'a', 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', ink);
% b, c: 30 ms at full rate after the cut and just before the recorded collapse, aligned on a radio dip
when = [2, min(cellfun(@(x) x.tCol, traces)) - 0.5];   % after the cut, and before the first stop
for p = 1:2
    ax = axes(f, 'Units', 'centimeters', 'Position', [1.5 + (p - 1)*8.4 1.1 7.6 5.2]); hold(ax, 'on')
    for i = 1:numel(traces)
        if when(p) > traces{i}.tCol - 0.05, continue, end
        [tw, vw] = dipWindow(traces{i}.t, traces{i}.vn, when(p), 30e-3);
        plot(ax, 1e3*tw, vw, '-', 'Color', col(i, :), 'LineWidth', 0.6);
    end
    hold(ax, 'off'); styleAxes(ax); xlim(ax, [-2 30]); ylim(ax, [2 5.2]);
    xlabel(ax, sprintf('Time from a radio-dip bottom near %.1f s (ms)', when(p))); ylabel(ax, 'Bank-node voltage (V)');
    text(ax, -0.15, 1.04, char('a' + p), 'Units', 'normalized', 'FontSize', 11, 'FontWeight', 'bold', 'Color', ink);
end
outDir = fullfile(here, 'results'); if ~isfolder(outDir), mkdir(outDir); end
exportgraphics(f, fullfile(outDir, 'capbank_holdup_simulation.png'), 'Resolution', 300, 'BackgroundColor', 'white');
fprintf('Saved %s\n', fullfile(outDir, 'capbank_holdup_simulation.png'));

%% Local functions
function [te, lo, hi, mu] = envelope1ms(t, v)
% 1 ms bins: centre time, minimum, maximum and mean
nb = round(1e-3/(t(2) - t(1))); nB = floor(numel(v)/nb);
V = reshape(v(1:nB*nb), nb, nB);
te = (((0:nB-1) + 0.5)*1e-3)'; lo = min(V)'; hi = max(V)'; mu = mean(V)';
end

function [tDip, bot] = dipBottoms(t, v)
% Radio dips (> 0.5 V below the 20 ms maximum): time and bottom of each
fs = round(1/(t(2) - t(1))); d = movmax(v, round(0.02*fs)) - v > 0.5;
st = find(d & ~[false; d(1:end-1)]); st = st([true; diff(st) > round(5e-3*fs)]);
st = st(st + round(2.5e-3*fs) <= numel(v));
bot = arrayfun(@(i) min(v(i:i + round(2.5e-3*fs))), st); tDip = t(st);
end

function [tw, vw] = dipWindow(t, v, t0, len)
% len of trace starting 2 ms before the first radio dip (> 0.5 V below the
% 20 ms maximum) after t0, with time relative to its bottom
fs = 1/(t(2) - t(1)); k = find(t >= t0, 1) + (0:round(0.05*fs));
k = k(k <= numel(v));
i = k(find(movmax(v(k), round(0.02*fs)) - v(k) > 0.5, 1));
[~, m] = min(v(i:min(end, i + round(2.5e-3*fs)))); i = i + m - 1;   % align on the dip bottom
w = i + (-round(2e-3*fs):round(len*fs)); w = w(w >= 1 & w <= numel(v));
tw = t(w) - t(i); vw = v(w);
end

function styleAxes(ax)
ink = [0.15 0.15 0.15];
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'LabelFontSizeMultiplier', 9/8, 'LineWidth', 0.5, ...
    'TickDir', 'out', 'TickLength', [0.01 0.01], 'Box', 'off', 'Color', 'w', 'XColor', ink, 'YColor', ink);
ax.Toolbar.Visible = 'off';
end
