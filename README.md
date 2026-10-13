# Pi OCR Machine Monitor

A Raspberry Pi CM5 captures the video output of a gaming machine, reads numbers from fixed screen
regions with OCR, and returns them as text (or JSON over HTTP). One Pi per machine.

```
PC ──DP──► PS8652 splitter ──TX0──► external monitor
                 └──TX1──► PS176 (DP→HDMI) ──► MS2130 (HDMI→USB3) ──► CM5 /dev/video0
```

## Requirements

- Raspberry Pi OS (Debian 13, aarch64) on the custom CM5 board
- `ffmpeg`, `imagemagick`, `tesseract-ocr`, `python3`, `python3-smbus2`, `v4l2loopback`
- Access to the I2C bus: your user must be in the `i2c` group (`/dev/i2c-6`)
- `sudo` rights for `modprobe v4l2loopback` (only used if `/dev/video10` is missing)

## Quick start

```bash
./stream.sh capture out.png                       # capture one frame (stream runs only for this)
./ocr.sh out.png configs/mymachine.conf           # prints "label: value" per region
./stream.sh validate out.png test_regions.conf    # compare OCR to expected values
```

## Capture modes

Set `CAPTURE_MODE` in `capture.conf`.

| Mode | What happens | Typical time |
| --- | --- | --- |
| `managed` (default) | Start stream → wait for the video link → settle → capture → stop stream → wait for link to drop | ~5 s to image, ~8 s until ready for the next capture |
| `always-on` | Use a loopback stream you start yourself (`./stream.sh start-5fps`) | ~0.5 s |

Managed mode keeps ffmpeg, the MS2130 and PS176 idle between captures, which saves power and
reduces load on the PS176. If a capture lands during a link drop, or the frame is blank, it is
discarded and retried automatically. After the stream stops, the capture waits for the link to go
down (about 3 s) before releasing the lock, so the next capture always starts from a clean state.
Only one capture runs at a time (shared lock), so the shell tools and the HTTP server can be used
together safely.

A managed capture reports: link, settle, capture, stop (total), link down, and cycle (total + link
down = time from starting a capture until the next one can start), plus the saved image size and
the source resolution. The image is always 1920×1080; the source can differ (the MS2130 scales it).

For always-on use:

```bash
./stream.sh start-5fps
./stream.sh capture-loopback out.png
./stream.sh stop
```

## Commands (`./stream.sh`)

| Command | Purpose |
| --- | --- |
| `capture [out.png]` | Capture using `CAPTURE_MODE`; prints link/settle/capture/total ms, source resolution, retries |
| `link-status` | Show PS176 link state (exit code 0 = link up) |
| `status` | Stream status, link state, capture mode, memory |
| `start-5fps` / `stop` | Start / stop the always-on loopback stream |
| `capture-loopback [out.png]` | Grab a frame from a running stream |
| `capture-ondemand [out.png]` | Open the device directly (fails silently without signal) |
| `validate [img] [cfg]` | OCR an image and compare to expected values |
| `loop-test <method> <cfg> <secs> <n>` | Repeated capture + OCR with pass/fail and a log file |
| `read-loop <method> <cfg> <secs> <n>` | Repeated capture + OCR, values only |
| `benchmark [cfg]` | Compare all capture methods |

`method` is one of `managed`, `5fps`, `60fps`, `mjpeg`, `nice`, `ondemand`. `n = 0` runs until Ctrl+C.

Example: 100 managed captures, 15 s apart:

```bash
./stream.sh loop-test managed test_regions.conf 15 100
```

Logs are named `loop_test_YYYYMMDD_HHMMSS.log`. Managed runs add a `timing=` field per line
(`link_ms,settle_ms,capture_ms,total_ms,down_ms,cycle_ms,resolution,retries,hpd_toggle`) and the
summary shows time-to-link min / mean / max, link-down time and the mean full cycle.

## Settings (`capture.conf`)

Environment variables of the same name override the file, e.g. `SETTLE_MS=2000 ./stream.sh capture`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `CAPTURE_MODE` | `managed` | `managed` or `always-on` |
| `I2C_BUS` | 6 | I2C bus the PS176 is on |
| `PS176_BASE` | 0x48 | PS176 base address (pages 0x48 / 0x49 / 0x4A) |
| `LINK_TIMEOUT` | 15 | Seconds to wait for the link before one HPD toggle, then failure |
| `SETTLE_MS` | 1500 | Wait after link-up so the MS2130 delivers fresh frames |
| `LINK_DOWN_TIMEOUT` | 15 | Seconds to wait for the link to drop after the stream stops |
| `CAPTURE_RETRIES` | 3 | Re-captures if the link dropped or the frame was blank |
| `POLL_MS` | 50 | PS176 poll interval |
| `LOCK_FILE` | `/tmp/capture.lock` | Shared capture lock |

> `SETTLE_MS=1000` produced a blank first frame on every capture during testing (it was retried
> automatically); 1500 ms avoided the retry. Check that captures always show current screen
> content before shortening it.

## Region config files

One region per line, pipe-delimited:

```
# label|crop_geometry|shave|whitelist|options|expected
Major Progressive|579x124+679+693|0x0||invert|$7,500.05
```

- **crop_geometry** `WxH+X+Y`: measure in GIMP (hover for X,Y; rectangle select for W,H)
- **shave**: pixels trimmed from all edges (`0x0` = none)
- **whitelist**: restrict Tesseract characters, e.g. `0123456789.$` (empty = all)
- **options**: comma-separated `invert` (needed for light text on dark), `scale2x`, `scale3x`
- **expected**: used only for validation; leave empty in production configs in `configs/`

## HTTP server

```bash
python3 pi_server.py            # listens on 0.0.0.0:8080
python3 pi_server.py --port 9090
```

`GET /status` returns stream/device state plus `ps176_present`, `link_up`, `source_resolution`,
`link_rate_gbps` and `lanes`.

`POST /ocr`:

```json
{
  "capture_method": "managed",
  "regions": [
    { "label": "Major Progressive", "crop": "579x124+679+693",
      "shave": "0x0", "whitelist": "", "options": ["invert"] }
  ]
}
```

`capture_method` is `managed` (default), `loopback`, `ondemand` or `auto` (loopback if an
always-on stream is running, otherwise managed). The response contains `results` plus a timing
breakdown: `capture_ms`, `link_ms`, `settle_ms`, `total_ms`, `link_down_ms`, `cycle_ms`, `retries`,
`hpd_toggle_used`, `source_resolution` (what the PC outputs) and `image_resolution` (the saved
image). `cycle_ms` is the time until the next capture can start.

The server handles one request at a time, so `/status` can wait for a capture in progress.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `PS176 not answering` | Normal when idle (it sleeps). If it persists during a capture: check `i2c` group membership and `I2C_BUS` |
| `link did not come up` | No video source, or the PC's display is asleep. Check the cable and the PC's display settings; managed mode already tried one HPD toggle |
| All regions empty at once | Signal loss on the source; disable screensaver and display sleep on the host machine |
| Capture is slower than expected | Managed mode waits ~2.5 s for the link, the settle time, and ~3 s for the link to drop; use `always-on` if speed matters more than power |
| Stream left running after a crash | `./stream.sh stop` |

Rules to keep the link healthy:

- Never open `/dev/video0` yourself (e.g. `v4l2-ctl`) while using managed mode; it drops the link.
  Only the stream's ffmpeg should open it.
- Don't access the PS8652 splitter over I2C.

## Files

| File | Purpose |
| --- | --- |
| `stream.sh` | Main tool: capture, stream control, validation, tests |
| `ocr.sh` | Standalone OCR for one image and config |
| `ps176_link.py` | PS176 link status (`status`, `video`, `wait`, `toggle`) and capture lock |
| `pi_server.py` | HTTP API for the Windows test tool |
| `capture.conf` | Capture settings |
| `configs/` | Per-machine region configs |
| `test_regions.conf` | Test config with expected values |
| `ocr-test-tool/` | Windows companion app (has its own docs) |
| `CLAUDE.md`, `CONTEXT.md` | Developer notes and background |
