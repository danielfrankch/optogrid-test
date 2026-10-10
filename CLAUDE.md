# OptoGrid bench tests

Bench tests of the OptoGrid wireless optogenetics device, one folder per test:

| Folder | Contents |
|--------|----------|
| `pilot-consumption-test/` | First current consumption test (2026-10-08): test script, analysis, data, results, method slide. Documented below. |
| `1-current-consumption-test/` | Test 1: `og_current_test.m` (100 + 50 stimulation sweeps, 40 s end idle), `session-1/`, `session-2/`, `analysis/analyse_current_test.m` |
| `2-latency-test/` | Test 2: `og_latency_setup.m` programs LED 1 and ends; each function generator pulse (CH2) sends a Bluetooth trigger command; CH1 is an optical sensor on the LED (or the shunt current, `ch1_type` in meta.yml). `analysis/analyse_latency_test.m` measures trigger pulse start to first light (start of the low-level steps before the main rise). Session 1 (5 ms flash, 31.3 ms trigger period): latency spreads evenly over ~3.5-11.2 ms (the 7.5 ms Bluetooth connection interval) plus a tail of missed connection events; median 8.0 ms. A trigger period that is a multiple of 2.5 ms (e.g. 50 ms) gives discrete 2.5 ms clusters instead. |
| `3-wireless-power-transfer-test/` | `session-1/`, `analysis/` (not started) |

Empty folders hold a `.gitkeep` so git tracks them. Raw `.bin` recordings are git-ignored
everywhere. Use kebab-case folder names (no spaces).

Each `session-N/` holds its `.bin` recording(s) directly (no `data/` subfolder) and a `meta.yml` logging the recording settings
(WaveForms record settings, Scope Ch1 range and offset, device, stimulation, schedule).
`meta.yml` is the reference: the test 1 analysis reads file, sample rate, range and
offset from it. Test 1 session 1: 299.401 kHz, 500 mV/div, 0 V offset; connected idle
0.70 mA mean with a floor at 0 mA (the pilot, at -200 mV offset, read a 2.2 mA floor;
check the pilot offset with a zero-current recording before comparing absolute values).

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

- Conversion: V = raw × 5/65536 − offset. Raw counts are relative to the hardware input
  range, which is 5 V full scale for any setting up to 500 mV/div (50 V above that), not
  to the on-screen V/div. The hardware applies the offset, so it is subtracted back out.
  This conversion is inferred, not documented: it is the only one that gives physically
  sensible currents (connected idle ≈ 2.6 mA). A recording with the device unplugged
  would confirm the zero-current level.
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

- Pre-script (status LED on, before connect): 6.1 mA
- Connected idle: 2.64 mA mean, with a 2.2 mA floor
- Radio events in idle: about 44 per second (30 ms connection interval), about 0.55 ms
  long, about 2.9 µC each. Radio-off current 2.51 mA, radio-on 7.9 mA.
- 1 kHz ticks, about 50 µs and up to about 12 mA, appear in every state.
- Status LED: +3.5 mA. Sham LED: +2.1–2.4 mA.
- Program: no measurable increase over idle.
- Stimulation: 10.97 mA mean. Each lit uLED adds about 6–7 mA on top of idle + sham.
- IMU streaming: 6.83 mA.
- **Idle after IMU stays raised at 4.28 mA (floor 3.2 mA), with a 100 Hz pattern of
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
