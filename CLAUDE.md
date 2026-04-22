# Pi OCR Machine Monitor

Raspberry Pi CM5 system that captures HDMI output from gaming machines via a USB capture card,
OCRs specific screen regions, and will report readings to a central server. One Pi per machine.
Read `CONTEXT.md` for full background, hardware details, and open questions.

---

## Hardware

| Item            | Detail                                          |
| --------------- | ----------------------------------------------- |
| Board           | Custom Raspberry Pi CM5 (4GB RAM)               |
| OS              | Raspberry Pi OS (Debian 13, aarch64)            |
| Capture card    | Macrosilicon MS2130 HDMI→USB 3.0 → `/dev/video0` |
| Virtual device  | v4l2loopback → `/dev/video10`                   |
| Capture output  | YUYV 4:2:2, fixed 1920×1080 regardless of source |

---

## Key Files

| File                | Purpose                                                  |
| ------------------- | -------------------------------------------------------- |
| `stream.sh`         | Main tool — stream control, capture, benchmark, loop-test, validate |
| `ocr.sh`            | Standalone OCR — reads a `.conf`, prints `label: value` per region |
| `pi_server.py`      | HTTP server — `GET /status`, `POST /ocr` (used by Windows test tool) |
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
  "save_images": false,
  "regions": [
    { "label": "Major Progressive", "crop": "579x124+679+693",
      "shave": "0x0", "whitelist": "", "options": ["invert"] }
  ]
}
```
`capture_method`: `"loopback"` | `"ondemand"` | `"auto"` (auto picks loopback if stream is running).
`save_images`: if `true`, saves `capture.png` + one processed PNG per region to
`/tmp/ocr_captures/<timestamp>/` and returns `saved_images_dir` in the response.

**`POST /ocr`** — response:
```json
{ "success": true, "capture_ms": 530, "capture_method": "loopback",
  "timestamp": "2026-04-16T14:30:00Z",
  "saved_images_dir": "/tmp/ocr_captures/20260416_143000",
  "results": [{ "label": "Major Progressive", "value": "$7,500.05" }] }
```
`saved_images_dir` is only present when `save_images` was `true`.

---

## Critical Known Issues

### HDMI Signal Loss
- If the host gaming machine activates screensaver or display sleep, the MS2130 loses signal
- Symptom: **all** regions return empty strings simultaneously; capture time increases ~200ms
- Recovery: unplug/replug the **HDMI/DisplayPort cable from the host machine** (not the capture card USB)
- Do NOT unplug the MS2130 USB — that makes recovery harder
- Production fix: disable screensaver and display power saving on all host machines

### Video Splitter / Startup Order
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
