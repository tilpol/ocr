# Project Context — Pi OCR Machine Monitor

## Overview

A Raspberry Pi 5 system that captures HDMI video output from gaming machines via a USB capture
card, OCR's specific regions of the screen, and reports the readings to a central server over
the network. One Pi per machine.

---

## Hardware

- **Pi model**: Custom Raspberry Pi CM5 (4GB RAM) based board
- **OS**: Raspberry Pi OS (Debian 13, aarch64)
- **Capture card**: Macrosilicon MS2130 HDMI to USB 3.0
- **Capture device**: `/dev/video0`
- **Source resolution**: Variable up to 4K
- **Capture resolution**: Want fixed 1920x1080 no matter source resolution

---

## Software Stack

| Tool                  | Package                         | Purpose                                    |
| --------------------- | ------------------------------- | ------------------------------------------ |
| ffmpeg 7.1.3          | ffmpeg                          | Video capture from V4L2 device             |
| ImageMagick (convert) | imagemagick                     | Crop and preprocess image regions          |
| Tesseract 5.x         | tesseract-ocr tesseract-ocr-eng | OCR text from regions                      |
| v4l2loopback          | v4l2loopback-dkms               | Virtual V4L2 device for loopback streaming |
| v4l-utils             | v4l-utils                       | Device inspection (v4l2-ctl)               |
| Python3 + Pillow      | python3 python3-pillow          | Image analysis utilities                   |

---

## Key Technical Findings

### MS2130 Capture Card Behaviour

- Currently Outputs **YUYV 4:2:2 at 1920x1080 @ 60fps** when negotiated correctly

### HDMI Signal Loss — Critical Production Issue

- If the MS2130 USB is unplugged and replugged, the host machine may not re-establish the
  HDMI signal automatically, resulting in a black screen
- Recovery procedure: Unplug and replug the DisplayPort/HDMI cable from the HOST machine
  (not the capture card USB). This forces the host to re-enumerate displays and re-establish
  the handshake with the MS2130
- Signal loss also occurs if the host machine activates a screensaver or display power saving
  — this caused on-demand test failures after exactly 5 minutes (matching a power save timeout)
- When signal is lost, ALL regions return empty OCR results and capture time increases ~200ms
- In production, host machines must have screensaver and display power saving disabled

### Working Capture Commands

**Loopback stream** — ffmpeg runs continuously feeding a v4l2loopback virtual device:

```bash
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture"
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
  -framerate 60 -i /dev/video0 \
  -vf "scale=1920:1080,format=yuv420p" \
  -r 5 -f v4l2 /dev/video10 -loglevel quiet &
# Snapshot from virtual device (instant, no warmup needed):
ffmpeg -f v4l2 -i /dev/video10 -vframes 1 -update 1 -y capture.png -loglevel quiet
```

**On-demand** — open device, skip 60 frames for warmup, grab frame, close:

```bash
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
  -framerate 60 -i /dev/video0 \
  -vf "select='gte(n,60)',scale=1920:1080,format=rgb24" \
  -vframes 1 -update 1 -y capture.png -loglevel quiet
```

### Capture Method Comparison

| Method         | Capture time | Idle CPU | Idle RAM | Notes                      |
| -------------- | ------------ | -------- | -------- | -------------------------- |
| Loopback 60fps | ~530ms       | ~46%     | ~200MB   | 790+ iterations no failure |
| Loopback 5fps  | ~530ms       | ~45%     | ~200MB   | Not long-term tested       |
| On-demand      | ~1725ms      | 0%       | 0MB      | Fails if HDMI signal lost  |

### OCR Preprocessing Pipeline

Raw captures have noise/grain from YUYV conversion. Required preprocessing:

```bash
convert capture.png \
  -crop WxH+X+Y +repage \     # crop to region of interest
  [-shave NxN] \               # optional: trim edges to remove border artefacts
  [-resize 200%] \             # optional: scale2x or scale3x for small text
  -colorspace Gray \           # convert to greyscale
  -normalize \                 # auto contrast stretch
  [-negate] \                  # invert if white/light text on dark background
  -threshold 40% \             # binarise
  region.png
tesseract region.png stdout --psm 7 [-c tessedit_char_whitelist=0123456789]
```

**Important notes**:

- Tesseract works best with black text on white background
- White-on-dark regions MUST use -negate before thresholding
- Use --psm 7 for single lines of text
- Use tessedit_char_whitelist for numeric-only or known character set regions
- Use GIMP to measure crop coordinates — hover for X,Y position, rectangle select for W,H

---

## Config File Format

Each machine has its own .conf file in ~/ocr/configs/, named after the machine.

```
# Format: label|crop_geometry|shave|whitelist|options|expected
#
# label         : descriptive name for this region
# crop_geometry : WxH+X+Y  (measured in GIMP on a 1920x1080 capture)
# shave         : NxN pixels to trim from all edges, use 0x0 for none
# whitelist     : allowed chars for tesseract, empty = all chars
# options       : invert, scale2x, scale3x (comma separated), empty = none
# expected      : expected OCR value for test/validation only, empty = skip
#
# Example (slot machine jackpot display):
Major Progressive|579x124+679+693|0x0||invert|$7,500.05
Minor Jackpot|257x79+554+897|0x0||invert|$50.00
Mini Jackpot|267x77+1118+898|0x0||invert|$10.00
```

Note: In production the expected field will be empty as values change continuously.
The expected field is only used for setup validation and testing.

---

## Project File Structure

```
~/ocr/
├── stream.sh          # Main script — capture, stream, benchmark, loop-test, validate
├── ocr.sh             # Standalone OCR script — reads config, outputs label: value pairs
├── CONTEXT.md         # This file
├── test_regions.conf  # Test config WITH expected values (for validation testing only)
├── configs/
│   └── machine1.conf  # Per-machine region config (no expected values in production)
└── logs/              # Loop test logs — auto-created, named loop_test_YYYYMMDD_HHMMSS.log
```

---

## stream.sh Command Reference

```bash
# Loopback stream management
./stream.sh start-60fps                           # Start loopback at 60fps (~46% CPU)
./stream.sh start-5fps                            # Start loopback at 5fps (~45% CPU)
./stream.sh start-mjpeg                           # Start loopback MJPEG (unreliable at 1080p)
./stream.sh start-nice                            # Start loopback 5fps, nice 19 (low priority)
./stream.sh stop                                  # Stop loopback stream
./stream.sh status                                # Show stream CPU/memory stats

# Capture
./stream.sh capture-loopback [output.png]         # Grab frame from running loopback (~530ms)
./stream.sh capture-ondemand [output.png]         # Grab frame on-demand (~1725ms, no stream)

# OCR validation
./stream.sh validate [image.png] [config.conf]    # OCR image, compare to expected values

# Testing
./stream.sh benchmark [config.conf]               # Benchmark all capture methods with OCR
./stream.sh loop-test [method] [config] [secs] [n]
#   method: 60fps | 5fps | mjpeg | nice | ondemand
#   secs:   interval between captures (default: 5)
#   n:      iterations, 0 = unlimited (default: 0)
#
# Examples:
./stream.sh loop-test 60fps test_regions.conf 5 0     # Unlimited loopback test
./stream.sh loop-test ondemand test_regions.conf 5 0  # Unlimited on-demand test
```

## ocr.sh Command Reference

```bash
./ocr.sh [image.png] [config.conf]
# Reads config, OCR's each region, outputs:
#   Label               : value
```

---

## Loop Test Log Format

```
iter|timestamp|capture_ms|pass|fail|label=result[STATUS]|label=result[STATUS]|...
# STATUS is PASS, FAIL, or SKIP
# Example failure:
40|2026-04-15 16:32:13|1923|0|3|Region 1=[FAIL]|Region 2=[FAIL]|Region 3=[FAIL]|
```

---

## Reliability Test Results

| Method         | Iterations | Duration | Failures       | Notes                               |
| -------------- | ---------- | -------- | -------------- | ----------------------------------- |
| Loopback 60fps | 790+       | ~80 mins | 0              | Stable, high CPU                    |
| On-demand      | 39         | ~5 mins  | All at iter 40 | Host display power saving triggered |

**On-demand failure pattern**: All regions return empty simultaneously, capture time
increases ~200ms. Root cause is HDMI signal loss from host, not a software bug.

---

## What Works

- [x] Clean 1920x1080 frame capture from MS2130
- [x] Loopback streaming (60fps and 5fps)
- [x] On-demand capture with frame-skip warmup
- [x] OCR with preprocessing pipeline (crop, greyscale, normalize, threshold)
- [x] Invert support for white-on-dark text regions
- [x] Per-machine config files with region definitions
- [x] Pass/fail validation against expected values
- [x] Loop testing with per-iteration stats, CPU/memory monitoring, timestamped log files
- [x] Benchmark tool comparing all capture methods

---

## Next Steps — To Be Developed

- [ ] Frame quality check — detect blank/corrupt captures before OCR, retry or alert
- [ ] HDMI signal loss detection — detect when all regions return empty, trigger alert
- [ ] Machine identity — use hostname or config-defined ID to identify each Pi
- [ ] Network reporting — send OCR results to central server after each capture cycle
- [ ] Decide network protocol — HTTP REST, MQTT, TCP socket, or direct DB write
- [ ] Production loop script — clean standalone script separate from test/benchmark tooling
- [ ] Local result queuing — queue readings locally if network unavailable, retry later
- [ ] Central server — receive and store readings from all Pis
- [ ] Host power saving fix — disable screensaver/display sleep on all host machines
- [ ] Deployment strategy — how configs and scripts are pushed to each Pi (TBD)
- [ ] Production test strategy

---

## Open Questions

1. Network protocol — HTTP REST, MQTT, TCP socket, or direct database write?
2. Central server — what OS/stack is it running? Existing API or new?
3. Capture frequency — how often to read values? (TBD — currently testing at 5s interval)
4. Data schema — minimum fields: machine_id, timestamp, label, value
5. Error handling — discard bad reads silently, flag for review, or send with error status?
6. Signal loss alerting — who gets notified and how when HDMI signal is lost?
7. Deployment — how are configs and script updates pushed to each Pi?
8. Host machine config — need to disable screensaver/display power saving on all hosts

---

## Recovery Procedures

### HDMI Signal Lost (black screen or corrupt capture)

1. Check host machine screen is displaying normally
2. If host screen is fine but capture is corrupt:
   - Unplug the DisplayPort/HDMI cable from the HOST machine (not the capture card)
   - Wait 2 seconds
   - Replug the DisplayPort/HDMI cable to the host machine
   - Wait 5 seconds for signal to re-establish
   - Verify: ./stream.sh capture-ondemand test.png && eog test.png
3. Do NOT unplug the MS2130 USB cable — this makes recovery harder

### Device Busy / Two Processes Competing

1. Check what has the device open: lsof /dev/video0
2. Stop any loopback stream: ./stream.sh stop
3. Kill any other processes using the device
4. Wait 2 seconds before capturing again
