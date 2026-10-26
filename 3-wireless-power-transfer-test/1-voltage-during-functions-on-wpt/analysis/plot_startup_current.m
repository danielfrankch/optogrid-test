% Plot the start-up current of test 3.1f: the current through a 10 ohm shunt
% over the 20 s recording, during which the power source is enabled.
% Input: ../device_LRV-O-0001/1f-start_up_curent_test/<recording>.bin
% (WaveForms, int16, one channel) and its .meta.yml (sample rate, Range,
% Offset). Volts = Range*Sample/65536 - Offset; current = V/shunt.
% Output: results/device_LRV-O-0001/1f-start_up_curent_test/<recording>_current.png
clear; clc; close all;

%% Settings
rootDir = fileparts(mfilename('fullpath'));     % analysis/
if isempty(rootDir), rootDir = pwd; end
testDir = fileparts(rootDir);
subTest = fullfile('device_LRV-O-0001', '1f-start_up_curent_test');
recName = '10ohm_shunt_resistor_allow_boot_on_3.5VBAT_given3.3VSupplyAcrossShuntandDevice_1';
plotTitle = 'Allow to boot when VBAT > 3.5 V, VBAT sampled with 50 ms interval. LED EN is disabled during boot.';
binWin_s = 1e-3;     % envelope bin (s)
meanWin_s = 10e-3;   % running mean (s)

%% Load
meta = fileread(fullfile(testDir, subTest, [recName '.meta.yml']));
num = @(key) str2double(regexp(meta, ['\n\s*' key ':\s*([-\d.eE]+)'], 'tokens', 'once'));
fs = num('sample_rate_Hz');
fid = fopen(fullfile(testDir, subTest, [recName '.bin']), 'r', 'ieee-le');
raw = fread(fid, inf, 'int16=>double'); fclose(fid);
i = (num('channel_range_V')*raw/65536 - num('channel_offset_V'))/num('shunt_ohm')*1e3;   % mA
n = numel(i); fprintf('%s: %.2f s at %g kHz\n', recName, n/fs, fs/1e3);

%% Plot: 1 ms min-max envelope and 10 ms mean
nb = round(binWin_s*fs); nB = floor(n/nb);
I = reshape(i(1:nB*nb), nb, nB); tb = ((0:nB-1)' + 0.5)*binWin_s;
f = figure('Units', 'centimeters', 'Position', [2 2 18 8], 'Color', 'w');
try theme(f, 'light'); catch, end
ax = axes(f); hold(ax, 'on')
patch(ax, [tb; flipud(tb)], [min(I)'; flipud(max(I)')], [0.75 0.75 0.75], 'EdgeColor', 'none');
plot(ax, tb, movmean(mean(I)', round(meanWin_s/binWin_s)), '-', 'Color', [0.27 0.47 0.67], 'LineWidth', 1);
hold(ax, 'off')
set(ax, 'FontName', 'Arial', 'FontSize', 8, 'TickDir', 'out', 'Box', 'off', 'LineWidth', 0.5);
xlim(ax, [0 n/fs]); xlabel(ax, 'Time (s)'); ylabel(ax, 'Current (mA)');
title(ax, plotTitle, 'FontSize', 9, 'FontWeight', 'normal', 'Interpreter', 'none');
legend(ax, {sprintf('%g ms min-max', 1e3*binWin_s), sprintf('%g ms mean', 1e3*meanWin_s)}, 'Box', 'off', 'Location', 'northwest');
outDir = fullfile(rootDir, 'results', subTest);
if ~isfolder(outDir), mkdir(outDir); end
exportgraphics(f, fullfile(outDir, [recName '_current.png']), 'Resolution', 300, 'BackgroundColor', 'white');
fprintf('Saved %s\n', fullfile(outDir, [recName '_current.png']));
