# Screen Capture Tool

`capture.sh` captures the video output of the gaming machine connected to this board so you
can run your own OCR (e.g. Tesseract) on it. It offers two modes:

- **Managed capture** – grab a single frame on demand.
- **Continuous stream** – a 5fps video stream you read frames from yourself.

## Files

Keep these three together in one directory:

| File             | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| `capture.sh`     | The tool                                             |
| `ps176_link.py`  | Reads DisplayPort link status over I2C               |
| `capture.conf`   | Timing/retry settings (defaults are fine)            |

## Requirements

- `ffmpeg`, `imagemagick` (`convert`, `identify`), `python3`, `python3-smbus2`
- `v4l2loopback` kernel module (the script loads it if `/dev/video10` is missing; needs `sudo`)
- Your user must be in the `i2c` group (access to `/dev/i2c-6`)

## Commands

```bash
./capture.sh capture [out.png]   # single capture (default: capture.png)
./capture.sh start               # start the continuous 5fps stream
./capture.sh stop                # stop the stream
./capture.sh status              # stream and link state
```

### Managed capture

`capture` starts the stream, waits for the DisplayPort link and a valid video signal, lets
the capture card settle, saves one frame, checks the link stayed up (and the frame isn't
blank), then stops the stream. Failed grabs are retried automatically. Expect **about 5–6
seconds** per capture. Only one capture runs at a time.

If you already ran `start`, `capture` takes the frame from the running stream (about
1 second) and leaves the stream running.

Exit code is 0 on success and non-zero on failure.

### Continuous stream

`start` runs a 5fps stream to the virtual video device `/dev/video10`. Read it from your own
software, for example:

```bash
# one frame with ffmpeg
ffmpeg -f v4l2 -i /dev/video10 -vframes 1 -y frame.png
```

```python
# OpenCV
import cv2
cap = cv2.VideoCapture(10)
ok, frame = cap.read()
```

Use `stop` when you're finished. Start the stream before powering on the source machine if
you can.

## Frame format

The output is always **1920×1080**, regardless of the source resolution (the source is
scaled). The stream device delivers YUV 4:2:0; saved captures are PNG.

## Important

- **Do not open `/dev/video0` yourself.** Even a brief open/close drops the link. Always
  read from `/dev/video10` (via `start`) or use `capture`.
- **Disable screensaver and display sleep on the source machine.** If it sleeps, the capture
  card loses signal and captures fail or come back blank. Recovery is to replug the
  DisplayPort cable at the source machine.
- Settings in `capture.conf` (e.g. `SETTLE_MS`, `CAPTURE_RETRIES`) can be overridden with
  environment variables of the same name.

## Tesseract tips

Tesseract wants black text on a white background. Typically: crop the region, convert to
grey, normalise, invert if the text is light-on-dark, threshold (around 40%), then run
`tesseract region.png stdout --psm 7` for single-line values (optionally with
`-c tessedit_char_whitelist=0123456789.$,`).

```bash
convert capture.png -crop 579x124+679+693 +repage -colorspace Gray -normalize \
  -negate -threshold 40% region.png
tesseract region.png stdout --psm 7
```
