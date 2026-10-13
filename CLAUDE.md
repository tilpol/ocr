# Pi OCR Machine Monitor

Raspberry Pi CM5 system that captures the video output of gaming machines via an on-board capture chain,
OCRs specific screen regions, and will report readings to a central server. One Pi per machine.
Read `CONTEXT.md` for full background, hardware details, and open questions.

---

## Hardware

| Item            | Detail                                          |
| --------------- | ----------------------------------------------- |
| Board           | Custom Raspberry Pi CM5 (4GB RAM)               |
| OS              | Raspberry Pi OS (Debian 13, aarch64)            |
| Capture chain   | PC ─DP─► PS8652 splitter ─TX0─► external monitor; ─TX1─► PS176 (DP→HDMI) ─► MS2130 (HDMI→USB3) ─► `/dev/video0` |
| Capture card (history) | Earlier prototypes used a standalone MS2130 USB dongle (HDMI in) |
| Virtual device  | v4l2loopback → `/dev/video10`                   |
| Capture output  | YUYV 4:2:2, fixed 1920×1080 regardless of source |

---

## Key Files

| File                | Purpose                                                  |
| ------------------- | -------------------------------------------------------- |
| `stream.sh`         | Main tool — stream control, capture, benchmark, loop-test, validate |
| `ocr.sh`            | Standalone OCR — reads a `.conf`, prints `label: value` per region |
| `pi_server.py`      | HTTP server — `GET /status`, `POST /ocr` (used by Windows test tool) |
| `ps176_link.py`     | PS176 link status over I2C (+ CLI: `status`, `video`, `wait`, `toggle`) and the shared capture lock |
| `capture.conf`      | Capture settings shared by `stream.sh` and Python (mode, I2C bus, timeouts, settle, retries) |
| `test_regions.conf` | Test config with expected values (for validation only)   |
| `configs/`          | Per-machine region configs (no expected values in production) |
| `logs/`             | Loop test logs, auto-named `loop_test_YYYYMMDD_HHMMSS.log` |

The companion Windows test app lives in `ocr-test-tool/` — see its own `CLAUDE.md` there.

---

## Running Things

```bash
# Stream (loopback preferred — more reliable than on-demand)
./stream.sh start-5fps                              # ~45% CPU, ~200MB RAM
./stream.sh stop
./stream.sh status

# Capture
./stream.sh capture-loopback [out.png]              # ~530ms, needs stream running
./stream.sh capture-ondemand [out.png]              # ~1725ms, no stream needed

# OCR
./ocr.sh capture.png test_regions.conf              # prints label: value per region
./stream.sh validate [image.png] [config.conf]      # compare OCR to expected values

# Testing
./stream.sh loop-test 5fps test_regions.conf 5 0    # unlimited loopback loop-test
./stream.sh benchmark [config.conf]                 # compare all capture methods

# HTTP server (for Windows test tool)
python3 pi_server.py                                # listens on 0.0.0.0:8080
python3 pi_server.py --port 9090
```

---

## Link-Managed Capture (default)

`./stream.sh capture [out.png]` (and `capture_method: "managed"` in `pi_server.py`) starts the
loopback stream only for the duration of one capture:

1. take the lock (`flock` on `/tmp/capture.lock`, shared by `stream.sh` and `pi_server.py`)
2. start the 5fps ffmpeg stream (skipped if an always-on stream is already running)
3. poll the PS176 every 50 ms until **link up AND video valid** (timeout 15 s → one DP_HPD toggle → wait again → fail)
4. settle `SETTLE_MS` so the MS2130 has fresh frames
5. grab one frame from `/dev/video10`
6. re-check the link; if it dropped, discard and retry (max `CAPTURE_RETRIES`); blank/uniform frames also retry
7. stop the stream (trap/finally, also on Ctrl+C), release the lock

It prints/returns: link, settle, capture and total ms, source resolution, link rate/lanes, retries,
whether an HPD toggle was needed. `loop-test managed ...` logs these per iteration (`timing=` field)
and summarises time-to-link min/mean/max. Settings live in `capture.conf` (env vars override);
`CAPTURE_MODE=always-on` keeps the old always-running loopback behaviour.

**I2C requirement:** the user needs access to `/dev/i2c-6` (`i2c` group) and `python3-smbus2`.
Only the PS176 is read — **never touch the PS8652 over I2C from production code.**
All PS176 registers are on bus 6, 7-bit addresses `PS176_BASE` (0x48) + page:

| Page / offset | Meaning |
| --- | --- |
| 0x49 @0x02 | max lane count (2 on this board; 4 = PS176 just reset) |
| 0x49 @0x20 / 0x21 | link rate (0x06/0x0A/0x14/0x1E = 1.62/2.7/5.4/8.1 Gbps) / lane count set |
| 0x49 @0x32, 0x33 | lane status nibbles (`& 7 == 7` = locked) |
| 0x49 @0x34 / 0x35 | bit 0: inter-lane aligned / sink in sync |
| 0x48 @0x09,0x0D,0x0F,0x13,0x2D | h_total, h_active, v_total, v_active (16-bit LE), Mvid (24-bit LE) — stale unless link up |
| 0x4A @0xA1 bit 7 | PS176 DP_HPD output; clear 100 ms then set to force a PS8652 retrain (recovery only) |

I2C errors (`OSError`) mean the PS176 is asleep/resetting: treated as "down", never a crash.
**Never open `/dev/video0` except through the stream ffmpeg process** — even a brief `v4l2-ctl`
open/close toggles the MS2130's HPD and drops the link.

**Measured on the CM5 (2560×1440 source, 2026-10-13):** time-to-link ≈ 2.5 s after the stream starts;
managed capture ≈ 5–6 s total; the link stays up for a few seconds after the stream stops, so
back-to-back captures can see link_ms ≈ 0; with `SETTLE_MS=1000` the first grab was blank every time
(auto-retried) — 1500 ms and above gave no retries in 4/4 runs each. **Freshness (stale-frame) testing
with changing screen content is still outstanding**, so `SETTLE_MS` default is unchanged.

---

## Config File Format

Pipe-delimited, one region per line. File is read by `ocr.sh`, `stream.sh validate/loop-test`,
and `pi_server.py`.

```
# label|crop_geometry|shave|whitelist|options|expected
Major Progressive|579x124+679+693|0x0||invert|$7,500.05
Minor Jackpot|257x79+554+897|0x0||invert|$50.00
Mini Jackpot|267x77+1118+898|0x0||invert|$10.00
```

- **crop_geometry**: `WxH+X+Y` — measure in GIMP (hover for X,Y; rectangle select for W,H)
- **shave**: trim N pixels from all edges; `0x0` to skip
- **whitelist**: restrict Tesseract chars, e.g. `0123456789.$`; empty = all chars
- **options**: comma-separated — `invert`, `scale2x`, `scale3x`; empty = none
- **expected**: only used for validation/testing; empty in production configs

---

## OCR Preprocessing Pipeline

Implemented in both `ocr.sh` and `pi_server.py` (Python subprocess calls). Must be kept in sync.

```bash
convert source.png \
  -crop WxH+X+Y +repage \   # crop to region
  [-shave NxN] \             # optional: trim edges
  [-resize 200% or 300%] \   # optional: scale2x / scale3x
  -colorspace Gray \         # greyscale
  -normalize \               # auto contrast stretch
  [-negate] \                # invert — required for white/light text on dark backgrounds
  -threshold 40% \           # binarise
  region.png

tesseract region.png stdout --psm 7 [-c tessedit_char_whitelist=CHARS]
```

**Critical rules:**
- Tesseract expects black text on white background — always apply threshold
- White-on-dark regions MUST use `-negate` before threshold (use `invert` option)
- `--psm 7` = single line of text — always use this
- Threshold is 40% — do not change without retesting across all regions

---

## pi_server.py — HTTP API

Zero new dependencies (Python 3 stdlib only).

**`GET /status`** — returns:
```json
{ "ok": true, "streaming": true, "device_present": true,
  "capture_device": "/dev/video0", "loopback_device": "/dev/video10" }
```

**`POST /ocr`** — request:
```json
{
  "capture_method": "auto",
  "regions": [
    { "label": "Major Progressive", "crop": "579x124+679+693",
      "shave": "0x0", "whitelist": "", "options": ["invert"] }
  ]
}
```
`capture_method`: `"loopback"` | `"ondemand"` | `"auto"` (auto picks loopback if stream is running).

**`POST /ocr`** — response:
```json
{ "success": true, "capture_ms": 530, "capture_method": "loopback",
  "timestamp": "2026-04-16T14:30:00Z",
  "results": [{ "label": "Major Progressive", "value": "$7,500.05" }] }
```

---

## Critical Known Issues

### HDMI Signal Loss
- If the host gaming machine activates screensaver or display sleep, the MS2130 loses signal
- Symptom: **all** regions return empty strings simultaneously; capture time increases ~200ms
- Recovery: unplug/replug the **HDMI/DisplayPort cable from the host machine** (not the capture card USB)
- Do NOT unplug the MS2130 USB — that makes recovery harder
- Production fix: disable screensaver and display power saving on all host machines

### Video Splitter / Startup Order
> **Superseded for the custom board (pending acceptance tests):** with the PS8652 firmware `84 00 41`
> and HPD wired PS176 → PS8652, the link is expected to retrain on every stream restart, which is
> what managed capture relies on. This section still applies to the old dongle + external splitter
> setup. Update it once the repeatability/asleep/TX0-monitor tests in `CAPTURE_ON_DEMAND.md` §7 pass.

- If an HDMI splitter is used between the source machine and the MS2130, the splitter only
  passes signal when it detects an active downstream sink
- **Stopping the ffmpeg stream drops the sink** — the splitter cuts its output, and the
  MS2130 buffers a stale frame. Restarting the stream will serve that stale frame until
  the splitter re-establishes signal (requires unplugging/replugging the source HDMI cable)
- **Fix:** start the loopback stream (`./stream.sh start-5fps`) **before** powering on the
  source machine, so the splitter always sees an active sink and never drops the signal

### On-Demand vs Loopback
- On-demand capture (`/dev/video0` direct) **fails silently** when HDMI signal is lost
- Loopback stream from `/dev/video10` is far more reliable — use it in production
- Both methods have been tested; loopback 790+ iterations with zero failures

---

## What's Done / What's Next

**Done:**
- Frame capture (loopback and on-demand), OCR pipeline, config system
- Validation, loop testing with logging, benchmark tool
- `pi_server.py` HTTP server for the Windows test tool

**To build next:**
- Frame quality check — detect blank/corrupt captures, retry or alert
- HDMI signal loss detection — detect all-empty results, trigger alert
- Machine identity — hostname or config-defined ID per Pi
- Network reporting — POST OCR results to central server after each cycle
- Production loop script — clean script separate from the test/benchmark tooling
- Local result queuing — queue locally if network unavailable, retry
- Central server — receive and store readings from all Pis

See `CONTEXT.md` for open questions (network protocol, server stack, data schema, etc.).
