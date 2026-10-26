# OptoGrid bench tests

Bench tests of the OptoGrid wireless optogenetics device, one folder per test:

| Folder | Contents |
|--------|----------|
| `pilot-consumption-test/` | First current consumption test (2026-10-08): test script, analysis (v1 and v2), `data/`, `results/`, `results_v2/`, method slide. Documented below. |
| `1-current-consumption-test/` | Test 1: `og_current_test.m` (100 + 50 stimulation sweeps, 20 s end idle), recordings in `device_FKY-O-0024/` and `device_OLI-O-0001/`, `analysis/analyse_current_test.m`, `test_method.pdf`. |
| `2-latency-test/` | Test 2: `og_latency_setup.m` programs LED 1 and ends; each function generator pulse (CH2) triggers the Raspberry Pi (GPIO 21), which sends a Bluetooth trigger command; CH1 is a photodiode + amplifier on LED 1 (or the shunt current, `ch1_type` in meta.yml). `analysis/analyse_latency_test.m` measures trigger pulse start to first light. Recordings in `device_FKY-O-0024/` (GPIO interrupt and polling) and `device_LRV-O-0001/`; method slide `latency_test_method.pdf`. |
| `3-wireless-power-transfer-test/` | Test 3 (device LRV-O-0001), summary table of every recording in its `README.md`. `1-voltage-during-functions-on-wpt/`: bank voltage on WPT power, sub-tests 1a load states (`og_wpt_load_states.m` / `analyse_load_states.m`, Rx model V = Voc − Rs·I with test 1 currents as loads; no added cap: Voc ≈ 4.58 V, Rs ≈ 0.17 kΩ, max ≈ 31 mW at 13.5 mA, regulation to ≈ 7 mA; with 110 uF on V_BANK Rs ≈ 46 Ω but the Rx current-limits at ≈ 5–6 mA), 1b drain by sham + status (`og_wpt_drain_by_sham_status.m` / `analyse_drain_by_sham_status.m`), 1c LED 1 amplitude sweep (`og_wpt_stim_sweep.m` / `analyse_stim_sweep.m`), 1d duration and 1e ITI sweeps (`analyse_stim_recovery.m`), 1g drain by sham + status + stim LED (`og_wpt_drain_by_sham_status_stim_led.m` / `analyse_drain_by_sham_status_stim_led.m`: status + LED 1 at 100 % for 60 s; plateau 2.84 V at the coil's 3-turn bundle, 2.61 V at its center), 1h power curve (`og_wpt_power_curve.m` / `analyse_power_curve.m`). From 24 Oct (Rx retuned to 43 + 3.3 pF) the power model is a current source I_rx plus the bank zener's soft knee: I_z = I_rx − I_use, V = Vk + Vs·ln(I_z/1 mA) + Rz·I_z (near the bundle I_rx 9.64 mA, Vk 4.45 V, Vs 44 mV, Rz 26 Ω; at the center I_rx 6.1 mA); useful power peaks just below I_rx (≈ 41 mW near the bundle). Recordings carry the device position on the 17 × 8.5 cm, 3-turn Tx coil (`position` in meta.yml and the file name, e.g. `_coil-bundle-5mm`, `_coil-center`). `2-hold-up-during-power-loss/`: 2a WPT switched off with BLE reads (`og_holdup_ble_log.m` / `analyse_wpt_switch_off.m`; 16–42 s without, 61.6 s with 110 uF), 2b DC supply cut, scope only (`plot_dc_cut_scope.m`), 2c DC cut with scope + BLE pairs (`analyse_ble_vs_scope.m`, pairs via `ble_log` in the scope meta.yml; writes `calibration_readbattery_wpt.csv` from the no-cap pair only), 2d decoupling capacitor sizing/tests. Recordings are `<yyyyMMdd_HHmmss>_<test>_<conditions>` (time saved = end) in `device_LRV-O-0001/<sub-test>/`; results in `analysis/results/device_LRV-O-0001/<sub-test>/`. Pre-reorganisation copy: `3-wireless-power-transfer-test-bak/`. |

## Layout conventions

```
<n>-<test-name>/
  <test script>.m               run on the PC to drive the device
  <method>.pdf                  method slide (exported from the git-ignored .key)
  device_<name>/                one folder per device (or session-N/)
    <recording>.bin             raw WaveForms recording (git-ignored)
    meta.yml                    recording settings for the folder
    <recording>.meta.yml        optional, per-recording settings (overrides meta.yml)
  analysis/
    analyse_<test>.m            run from MATLAB; reads the .bin + meta.yml
    results/device_<name>/      figures (.pdf, .png) and tables (.csv)
```

- Test 1 results: `1_overview` ... `7_led_distribution`, plus `task_summary.csv`, `idle_radio_summary.csv`, `led_summary.csv`.
- Test 2 results are named after the recording: `<recording>_latency.pdf/.png`, `<recording>_latencies.csv`, `<recording>_latency_summary.csv`.
- Both analyses default to the newest recording (`whichData` at the top); test 2 also has `'every'`.
- Git-ignored: `*.bin` (raw recordings, too big for GitHub), `*.key`, `*.asv`, `.DS_Store`. Figures (.pdf, .png) and result tables (.csv) are tracked; latency PDFs embed a 300 dpi image (a vector PDF of the overlaid traces is ~90 MB, too big for GitHub).
- Use kebab-case folder names, no spaces. Empty folders hold a `.gitkeep`.
- WaveForms .bin conversion (from the manual and `DC_5.0V_CapBank_Test_1`): Volts = Range*Sample/65536 − Offset,
  with Range and Offset the exact channel values WaveForms reports (e.g. 1 V/div gave Range 61.62 V,
  Offset −2.00 V; a 500 mV/div-class channel gave Range 5.49 V). The manual writes "+ Offset", but only
  "− Offset" reads the 5.0 V supply as 5.00 V. Pilot, test 1 and the test 3 cap-bank plot use it (Range in
  meta.yml `channel_range_V`, or the pilot script settings); the low-gain Range of Ch1 was not recorded, so
  5.4925 V (Ch2) is used there (CHECK). The latency analysis (test 2) still uses the old 5 V / 50 V
  full-scale rule; its timing results do not depend on the scale.

`meta.yml` is the reference for each recording: the analyses read file, sample rate, ranges,
offsets, schedule and stimulation from it. Test 1 `device_FKY-O-0024`: 500 mV/div, 0 V offset;
connected idle 1.10 mA mean with a 0.03 mA floor (the pilot, at -200 mV offset, reads 0.93 mA
with a 0.46 mA floor; check the pilot offset with a zero-current recording before comparing
absolute values).

## Latency results (test 2, trigger start to first light)

| Recording | Mode | Trigger period | Median | Mean ± s.d. |
|---|---|---|---|---|
| FKY-O-0024 `20261009_60s` | GPIO interrupt | 31.3 ms | 8.01 ms | 8.02 ± 2.37 ms |
| FKY-O-0024 `20261012_120s_2` | GPIO interrupt | 99.9 ms | 8.46 ms | 8.48 ± 2.39 ms |
| FKY-O-0024 `20261012_120s_3` | GPIO polling | 99.9 ms | 7.11 ms | 7.15 ± 2.24 ms |
| LRV-O-0001 `20261012_60s_1` | GPIO interrupt (assumed) | 31.3 ms | 8.28 ms | 8.31 ± 2.44 ms |

Latency spreads evenly over a 7.5 ms window (the Bluetooth connection interval) above a
~3.5 ms minimum, plus a thin tail of missed connection events. A trigger period that is a
multiple of 2.5 ms (e.g. 50 ms) gives artificial discrete clusters 2.5 ms apart.

# Pilot consumption test (`pilot-consumption-test/`)

Bench test of the OptoGrid wireless optogenetics device. A MATLAB script plays a fixed
sequence of device functions over Bluetooth while a Digilent Analog Discovery Studio
records the voltage across a shunt resistor in series with the device. A second MATLAB
script turns the recording into per-function current figures and tables.

## Files (paths relative to `pilot-consumption-test/`)

- `og_test_1.m`: runs the test sequence on the device. All timing and the stimulation
  settings are defined at the top of the file. The total must stay under 80 s (the script
  checks this before connecting).
- `analyse_og_test_1.m`: analyses the recordings in `data/` and writes figures and CSVs
  to `results/<session>/`. Its schedule settings must match `og_test_1.m`.
- `data/*.bin`: WaveForms Scope "Record to File" binary recordings.
- `test_method.key` / `test_method.pdf`: method slide (circuit and test sequence).
- OptoGrid MATLAB class (not in this repo): `optogrid-manager/matlab-optogrid/OptoGrid.m`,
  next to this repo.
  It talks to the device through a ZMQ bridge (`tcp://localhost:5555`), with a 60 s reply timeout.

## Test sequence (`og_test_1.m`)

Before the script starts, the status LED is on (the device default). The script connects,
turns the status LED off, then runs these tasks with a 3 s ITI between them:

| # | Task | Call | Duration |
|---|------|------|----------|
| 1 | Idle | none | 5 s |
| 2 | Status LED | `toggleStatusLED(1/0)` | 5 s |
| 3 | Sham LED | `toggleShamLED(1/0)` | 5 s |
| 4 | Program | `og.OptoSetting = ...; og.program` | 5 s hold |
| 5 | Stimulation | `og.trigger` | 5 s hold |
| 6 | IMU streaming | `enableIMU` / `disableIMU` | 15 s |
| 7 | Battery reads | `readbattery` × 10, 0.5 s apart | about 7.5 s |
| 8 | uLED checks | `readuLEDCheck` × 10, 0.5 s apart | about 7.5 s |

Stimulation settings: all 64 uLEDs (`led_selection = intmax('uint64')`), fired one after
another. Each LED has a 2 ms slot, so one sweep through all 64 takes 130 ms
(`period = 64*2+2`). Full amplitude lasts 20 sweeps (`duration` = 2600 ms), followed by a
5-sweep ramp-down (`ramp_down` = 650 ms). The sham LED stays on for the whole
stimulation. The other settings are `pulse_width = 2`, `amplitude = 100` and
`pwm_frequency = 50000`.

## Recording setup

- Shunt resistor: 10 Ω. Current (mA) = V / 10 × 1000.
- The .bin file is raw little-endian int16 from one channel. The ADC is 14-bit, stored
  left-aligned, so the low 2 bits are always 0. The file has no header, so the scope
  settings must be recorded separately:

  | Session | File | Sample rate | Range | Offset |
  |---------|------|-------------|-------|--------|
  | 1 | `..._081026_1.bin` | 400 kHz | 100 mV/div | -200 mV |
  | 2 | `..._081026_2.bin` | 299.401 kHz | 100 mV/div | -200 mV |

- Conversion: V = Range × raw/65536 − offset, with Range the value WaveForms reports for
  the channel (`rangeV` in the script settings; 5.4925 V, the Ch2 low-gain value, as Ch1's
  was not recorded) rather than the on-screen V/div. The hardware applies the offset, so it
  is subtracted back out. The older 5 V full-scale rule read idle as 2.6 mA; with the
  reported Range the pilot agrees with test 1. A recording with the device unplugged would
  confirm the zero-current level.
- Recording starts before `og_test_1.m` runs and stops after it, about 90 s in total.

## How the analysis works

- Task edges come from the 10 ms median current. The status LED step up anchors the
  timeline. Stimulation on/off comes from the 0.5 ms minimum current, which stays above
  idle while the sham LED is on. uLED checks show up as 10 short jumps in the 1 ms minimum.
  Program and battery-read windows are placed from the schedule because they show no step.
- Idle radio on/off: activity more than 4 mA above the idle floor that lasts at least
  150 µs (after merging gaps under 200 µs) counts as a radio event. This separates radio
  events from the narrow 1 kHz ticks.
- Per-LED current: the sweep period is estimated by autocorrelation (the device clock
  differs from the scope clock by about 0.05%). The slot phase is refined by maximising the
  contrast between LEDs. Each slot's mean current minus the Sham LED task mean gives the
  uLED-only current. LEDs below 30% of the median LED current are flagged as not lighting.

## Findings so far (sessions 1 and 2, 2026-10-08)

The two sessions agree to within about 0.1 mA unless noted.

(Numbers use the reported-Range conversion of 2026-10-13; see Recording setup.)

- Pre-script (status LED on, before connect): 4.75 mA
- Connected idle: 0.93 mA mean, with a 0.46 mA floor
- Radio events in idle: about 44 per second (30 ms connection interval), about 0.55 ms
  long, about 3.2 µC each. Radio-off current 0.79 mA, radio-on 6.6 mA.
- 1 kHz ticks, about 50 µs long, appear in every state.
- Status LED: +3.9 mA. Sham LED: +2.4–2.6 mA.
- Program: no measurable increase over idle.
- Stimulation: 10.08 mA mean. Each lit uLED adds about 6.5–7.5 mA on top of idle + sham.
- IMU streaming: 5.53 mA.
- **Idle after IMU stays raised at 2.73 mA (floor 1.56 mA), with a 100 Hz pattern of
  about 4 ms at about +2 mA.** Something keeps running after `disableIMU`. Battery reads
  and uLED checks sit on this raised level and add almost nothing visible.
- Ramp-down: sweep-mean µLED current falls roughly linearly, 92 → 73 → 55 → 37 → 23%
  of full amplitude over the 5 ramp sweeps (session 2).
- Dark uLEDs (by firing order): session 1: 47, 48, 55, 56. Session 2: 47, 48. The user
  reported 2 broken LEDs, so 55 and 56 dropping out in session 1 is unexplained.

## Figures (`results/<session>/`, each as vector PDF + 300 dpi PNG)

1. Mean current per epoch: step line over shaded, labelled task windows (grey = intervals)
2. Each function: 10 ms mean trace, window shaded, epoch mean dashed
3. a: mean current per function; b: idle radio off / overall / on
4. 100 ms examples of radio-event detection in each idle window
5. 8×8 grid of per-LED current waveforms (mean of full-amplitude sweeps)
6. a: per-LED µLED current; b: per-slot current over the last 2 full sweeps and the
   ramp-down; c: sweep-mean current through the ramp (% of full amplitude)

Style follows the user's publication brief: Arial, 8 pt ticks / 9 pt labels / 11 pt bold
panel letters, 18 cm width, Paul Tol muted palette with one fixed colour per task
(stimulation = blue), no TeX interpreter (Unicode µ, ±), MATLAB light theme forced.

## Conventions

- MATLAB R2025b is installed at `/Applications/MATLAB_R2025b.app`. Scripts can be run
  headless from the test folder, e.g. `cd pilot-consumption-test && matlab -batch "analyse_og_test_1"`.
- Keep every user-tunable setting at the top of each script.
