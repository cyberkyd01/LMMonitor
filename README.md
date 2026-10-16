# LM Monitor

LM Monitor is a macOS menu bar app that shows what LM Studio is doing in real time: generation speed, prompt processing, prefix-cache reuse, context use, and the Mac's CPU, GPU, memory, disk and power. It also warns about problems such as GPU out-of-memory errors, swap, and runaway generations.

## Download

Get `LMMonitor.dmg` from the [latest release](https://github.com/cyberkyd01/LMMonitor/releases/latest), or build it yourself (see [Build](#build)). See [Install](#install) for the first-launch step.

## What you see

### Menu bar

- While generating, live tokens/sec. While prefilling, prompt-processing percent. Otherwise, the last request's speed.
- Icon:
  - gauge: idle
  - hourglass: processing prompt
  - bolt: generating
  - warning triangle: critical alert
  - moon: LM Studio not running
- Display modes: tok/s, tok/s + GPU %, CPU/GPU/RAM, icon only.

### Popover

The top of the popover is always visible:

- Status of LM Studio, the server port, and the three log streams.
- Live card:
  - tokens/sec (sum across parallel slots)
  - prompt-processing progress bar with token count and time remaining
  - one row per slot when several requests run in parallel
  - prefix-cache line
- Vitals strip: CPU, GPU, GPU memory vs. GPU budget, RAM (colored by memory pressure), swap, disk read/write, power.

### Overview tab

- Last prediction: tokens/sec, time to first token, prefill tokens/sec, prompt tokens split into cached and new ("prefix") tokens, generated tokens, speculative-decoding draft acceptance, stop reason, duration, context at end. Values marked ≈ are estimated.
- Context meter for the whole pool and for each slot, with a "truncated" badge.
- Model card:
  - name, architecture, quantization, size
  - engine and version
  - context loaded / max, parallel slots
  - auto-unload countdown, speculative decoding
  - memory-fit verdict: fits / tight / will swap
  - buttons: Unload, Open LM Studio, Start server
  - list of on-disk models, each with an "Estimate fit" button that runs LM Studio's own estimate

### System tab

- CPU, with the P-core / E-core split
- GPU utilization (device, renderer, tiler)
- GPU memory vs. budget
- RAM, with wired and compressed memory
- Memory pressure, swap, disk
- Thermal state, SoC temperatures
- Power for CPU, GPU, ANE and DRAM
- Battery and Low Power Mode
- Memory and CPU of the LM Studio engine process and of the LM Studio app
- 10-minute history graphs, with a 1, 5 or 10 minute range

### History tab

- Recent requests.
- Per-model statistics: count, median and average tok/s, average prefill speed, average time to first token, total tokens.
- Export CSV writes to Downloads.

### Alerts tab

Alerts cover:

- GPU out of memory, model failed to load, compute error, KV cache full
- Memory pressure, swap in use or growing, GPU memory at budget
- Thermal throttling, Low Power Mode or battery during inference
- Context nearly full or truncated
- Runaway generation (default: over 15 minutes or 20,000 tokens)
- Generation much slower than usual for the model
- LM Studio server not running, lms CLI missing, log stream down
- Model fit tight or will swap

Each alert says what to do. Optional macOS notifications cover the important ones. They are off by default; turn them on in Settings.

## How it works

- LM Monitor reads LM Studio's own logs through the `lms` command-line tool (`lms log stream` for the runtime, model and server sources).
- It polls `lms ps` and LM Studio's REST API for model details.
- It reads system stats from macOS directly. It needs no root and no kernel extensions. Power and temperatures use the private IOReport and HID interfaces; if they are unavailable, those readings are hidden.
- Nothing needs to be routed through LM Monitor. Requests from the LM Studio chat window, curl, or any tool pointed at port 1234 are all seen.
- LM Monitor never starts LM Studio. When LM Studio is closed, it waits instead of launching the `lms` daemon.

Privacy: prompt and response text are never read or stored. Only counts and timings are kept.

History is saved to `~/Library/Application Support/LMMonitor/history.jsonl`. It keeps the newest 1,000 requests. You can turn history off.

## Requirements

- macOS 13 or later. Apple Silicon is recommended.
- LM Studio 0.4 or later, with the `lms` CLI installed at `~/.lmstudio/bin/lms`.
  - If it is missing, run `~/.lmstudio/bin/lms bootstrap`, or install it from LM Studio's Developer settings.
- To build: Xcode Command Line Tools (`xcode-select --install`).

## Build

Double-click `build.command`, or run `./build.command`. Add `--no-launch` to skip launching the app.

The script:

1. Compiles a release build.
2. Runs the built-in self-test (`LMMonitor --selftest`). It runs several hundred checks of the log parsers and state machine against captured LM Studio logs. If anything fails, the build stops.
3. Creates `dist/LMMonitor.app` and `LMMonitor.dmg`.

Build output goes to `build.log`.

## Install

1. Open `LMMonitor.dmg`.
2. Drag LM Monitor to Applications.
3. The app is ad-hoc signed, not notarized, so macOS blocks the first launch of a downloaded copy:
   - macOS 15 or later: open it once, then go to System Settings → Privacy & Security and click "Open Anyway".
   - macOS 13–14: right-click it, choose Open, then Open again.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/LMMonitor.app`

   A copy you built yourself with `build.command` opens normally.

For launch at login, turn it on in Settings. macOS may ask you to approve it in System Settings → General → Login Items.

## Settings

- Menu bar display mode
- Sampling interval: 1 s or 2 s
- Notifications on or off, per alert type
- Launch at login
- Path to `lms` (auto-detected)
- LM Studio host and port (port 0 reads the port from LM Studio's config)
- Runaway thresholds (minutes, tokens)
- Context warning level (default 85%)
- Keep history
- Poll `lms ps`
- Optional proxy

## Optional proxy

The proxy is not needed anymore and is off by default. When enabled, it listens on port 1235 and forwards to LM Studio. It is only useful if you want per-request HTTP details. To use it, point a tool at `http://localhost:1235/v1`.

## Understanding the numbers

- **tok/s**: generation speed reported by the engine. The live value covers the last 3 seconds.
- **prefill**: prompt-processing speed.
- **TTFT**: time to first token.
- **prefix / cached tokens**: prompt tokens reused from the previous request in the same slot.
  - llama.cpp: exact when LM Studio reports final stats. Otherwise estimated from the slot's prefix-similarity log line and marked ≈.
  - MLX: exact, from LM Studio's prompt-cache log.
- **context**: tokens currently held in the slot, compared with the slot's context size. With parallel slots, the pool is shared.
- **GPU budget**: the most memory macOS lets the GPU use on Apple Silicon (`recommendedMaxWorkingSetSize`). By default this is about 75% of RAM. You can raise it with `sudo sysctl iogpu.wired_limit_mb=<MB>`. The setting resets on reboot. Leaving too little for macOS causes swapping.
- **will swap**: the model plus its KV cache does not fit, so macOS will page memory to disk. Generation slows sharply.

## Troubleshooting

- **"LM Studio not running"**: open LM Studio.
- **Streams red or amber**: open the Debug view (ladybug icon) to see stream status and the last log lines.
- **`lms` not found**: run `~/.lmstudio/bin/lms bootstrap`, or set the path in Settings. The app falls back to tailing `~/.lmstudio/server-logs`.
- **No live per-slot detail for MLX models**: this is expected. MLX does not log per-slot progress. You still get prompt-processing percent, cached tokens and final stats.
- **Notifications do not work**: notifications only work from the installed .app.
- **Menu bar item missing**: on MacBooks with a notch, macOS hides status items that don't fit next to the frontmost app's menus. Switch to a different app or choose "Icon only" as the display mode.
- **Bug reports**: `/Applications/LMMonitor.app/Contents/MacOS/LMMonitor --snapshot ~/Desktop/lmm-shots` runs the monitor for 12 seconds and saves PNGs of every popover section with live data.
- **Quitting**: use the power button in the popover footer. If the app is force-quit, it cleans up its `lms log stream` helpers on the next launch.

## Project layout

- `Sources/LMMonitor/Core`: shared types, log parsers, state machine, alert rules, memory fit
- `Sources/LMMonitor/DataSources`: lms supervisor, log-file fallback, REST/lms poller, actions, optional proxy
- `Sources/LMMonitor/System`: CPU, GPU, memory, disk, process and power sampling
- `Sources/LMMonitor/App`: store, history, notifications, launch at login
- `Sources/LMMonitor/UI`: SwiftUI views
- `Sources/LMMonitor/SelfTest`: fixtures and tests run by `--selftest`
- `packaging/`: Info.plist, icon
- `build.command`: build script

## License

MIT. See [LICENSE](LICENSE).

---

## ⭐ Support

Please give stars and if possible Buy me a coffee (USDT-TRC20) - `TA216k3WgWTrKnUKxZrSDNGzSJj3eHtEcH`

Telegram: [@Cyberkyd](https://t.me/Cyberkyd)
