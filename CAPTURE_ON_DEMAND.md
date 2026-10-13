# Task brief: link-aware on-demand capture

**For Claude Code.** Put this file in the root of the `ocr` repo, next to `stream.sh`, `pi_server.py` and `CLAUDE.md`. Then ask Claude Code to *"read CAPTURE_ON_DEMAND.md and implement it"*.

---

## 1. Goal

At the moment a capture needs the loopback stream (`./stream.sh start-5fps`) running **all the time**. Change this so that a capture:

1. **starts** the stream,
2. **waits until the video link into the PS176 is up** and a fresh frame is available,
3. **captures** the image,
4. **stops** the stream.

Why:
- We choose when the link is up instead of keeping it up permanently.
- The board uses less power between captures, because ffmpeg isn't running and the MS2130 and PS176 can idle.
- The PS176 is only under load for a few seconds per capture. It currently resets itself under sustained load; see section 3.

Keep the existing always-on loopback mode working. The new mode is an addition, chosen by a setting.

---

## 2. Hardware chain (new since CLAUDE.md was written)

The capture card is no longer a USB dongle. It's a custom CM5 board with the whole chain on it:

```
PC ──DP──► PS8652 splitter ──TX0──► external monitor (must never blank)
                 │
                 └──TX1──► PS176 (DP→HDMI) ──HDMI──► MS2130 (HDMI→USB3) ──USB──► CM5 /dev/video0
```

| Part | Role | Control from the CM5 |
|---|---|---|
| PS8652 | DP splitter. Custom Parade firmware `84 00 41`: the PC sees only one monitor | I2C bus 6, address 0x18 (sometimes 0x08). **Do not access it from production code** |
| PS176 | DP → HDMI converter | I2C bus 6, register pages 0x48–0x4F (its I2C_ADDR pin is high) |
| MS2130 | HDMI → USB3 UVC capture, `/dev/video0` | USB / V4L2 only |

### How the link comes up

1. ffmpeg opens `/dev/video0`. While a stream is open, the MS2130 raises HDMI HPD and enables its HDMI input termination.
2. The PS176 sees HDMI HPD, wakes up if it was asleep, and reads the MS2130's EDID.
3. The PS176 raises DP_HPD to the PS8652.
4. The PS8652 trains the TX1 DisplayPort link to the PS176. Firmware `84 00 41` retrains automatically whenever HPD goes low then high, and **TX0 (the external monitor) is not affected**.
5. Video flows from the PS176 over HDMI into the MS2130, and fresh frames appear on `/dev/video0` and the loopback.

**Stopping the stream reverses all of this.** The MS2130 drops HPD, the PS176 drops DP_HPD, and the TX1 link goes down. The PS176 may go into power-down after a while with no HDMI HPD. This is expected and is the point of the change.

> The "Video Splitter / Startup Order" section in CLAUDE.md said the stream must be started before the source and never stopped. That was true for the old dongle setup and the first PS8652 firmware. With firmware `84 00 41` and HPD wired PS176 → PS8652, the link should come back every time the stream restarts. **Section 7 includes a test that confirms this. Update CLAUDE.md once it passes.**

---

## 3. Known issues to design for

- **The PS176 resets itself under load.** This is a hardware issue under investigation (interposer PCB on the prototypes).
  - At 1440p60 it resets every 5–60 s; at 1080p60 it stays up for many minutes.
  - After a reset the link drops, the PS176 reboots in about 0.5 s, and the PS8652 retrains it automatically a few seconds later.
  - **A capture can therefore land during a drop.** The capture code must check that the link was up before and after grabbing the frame, and retry if not.
- **The MS2130 can serve a stale frame** for a short time after the stream (re)starts. Never use the first frames after link-up. See the settle time in section 5.
- Prototype boards may be on any source resolution up to 4K30. The MS2130 always outputs **1920×1080 YUYV** to the CM5 whatever the source resolution.

---

## 4. Reading link status from the PS176 (I2C)

The PS176 has no public register map. The meanings below were worked out during bring-up and checked against Parade's PS8652 DPCD layout. Use **only** these registers. Use `smbus2` (`python3-smbus2`) with single-byte `read_byte_data` / `write_byte_data`. The user running the code needs access to `/dev/i2c-6` (the `i2c` group, or root).

**Bus 6. All addresses are 7-bit.**

### Link state: page 0x49 (DPCD mirror)

| Offset | Meaning | "Link up" condition |
|---|---|---|
| `0x02` | DPCD 002, max lane count supported (bits 4:0) | 2 on this board (strap). **4 = the PS176 has just reset** (power-on default) |
| `0x20` | DPCD 100, link rate (0x06/0x0A/0x14/0x1E = 1.62/2.7/5.4/8.1 Gbps) | non-zero |
| `0x21` | DPCD 101, lane count set, bits 4:0 | `n` = 1, 2 or 4 |
| `0x32` | DPCD 202, lane 0 status (bits 3:0) and lane 1 status (bits 7:4) | each active lane's nibble has bits 0–2 set (`& 0x7 == 0x7`) |
| `0x33` | DPCD 203, lanes 2/3 status | same, if `n == 4` |
| `0x34` | DPCD 204, bit 0 = inter-lane aligned | `1` |
| `0x35` | DPCD 205, bit 0 = sink in sync | `1` |

**Link up** = PS176 answers I2C, and `n > 0`, and all `n` lanes locked, and aligned, and in sync.

**PS176 not answering I2C** (the read raises `OSError`) means it's asleep, resetting or not powered. Treat it as "down", not as a crash.

### Video present: page 0x48 (main stream attributes)

16-bit little-endian values: `h_total` @0x09, `h_active` @0x0D, `v_total` @0x0F, `v_active` @0x13. 24-bit little-endian `Mvid` @0x2D.

**Video valid** = link up, and `Mvid != 0`, and `0 < h_active < h_total`, and `0 < v_active < v_total`. These registers hold stale values (e.g. 640×480) when there's no stream, so only trust them while the link is up. Log `h_active × v_active` with each capture; it's the source resolution.

### Optional: force a retrain (Parade method): page 0x4A, offset 0xA1

Bit 7 is the PS176's DP_HPD output (normally reads `0x91`). Read the register, clear bit 7, wait 100 ms, then set bit 7 again, changing nothing else. That makes the PS8652 retrain TX1. Use it only as a recovery step if the link hasn't come up within the timeout (section 5). Always restore bit 7 to 1, including on error.

### Reference implementation

`chain_status.py` (in `~/debug` on the CM5) already contains tested code:
- `PS176Fast` / `_uptime_state()` for the link check;
- `decode_ps176()` for video timing;
- `PS176Reg` / `hpd_toggle()` for the retrain.

Copy what's needed into a **small standalone module** (e.g. `ps176_link.py`). Don't import the whole debug tool into production code. `chain_status.py --uptime` is also the best way to watch the link while testing this work.

---

## 5. Capture sequence to implement

```
lock (flock /tmp/capture.lock)           # only one capture at a time
if stream already running (always-on mode): skip start/stop, just do steps 3–6
1. start loopback stream (same ffmpeg command as start-5fps)
2. wait for link:
      poll PS176 every 50 ms until  link_up AND video_valid
      timeout LINK_TIMEOUT (default 15 s)
      on timeout: one HPD toggle (0x4A:A1), wait up to LINK_TIMEOUT again, then fail
3. settle: wait SETTLE_MS after link-up (default 1000 ms) so the MS2130 has fresh frames
4. grab one frame from /dev/video10 (existing capture-loopback ffmpeg command)
5. re-check link_up: if it dropped since step 2 → discard, go back to step 2
      (max CAPTURE_RETRIES, default 3)
6. basic frame check: file exists, size > 0, not a uniform/black image
      (e.g. ImageMagick: convert img -format "%[fx:standard_deviation]" info: > small threshold)
7. stop stream (always, via trap/finally, also on error/Ctrl+C)
unlock
```

Return or log:
- time to link up (ms);
- settle (ms);
- capture (ms);
- total (ms);
- source resolution (from page 0x48);
- link rate and lane count;
- number of retries;
- whether an HPD toggle was needed.

Make the timings visible: the user wants to know how long a link-managed capture takes compared with the old always-on loopback capture (~530 ms).

### Settings

Put these in one place (top of `stream.sh` and a constants block in Python, or a shared config file):

| Setting | Default | Notes |
|---|---|---|
| `CAPTURE_MODE` | `managed` | `managed` = start/wait/capture/stop. `always-on` = existing loopback behaviour |
| `I2C_BUS` | 6 | |
| `PS176_BASE` | 0x48 | Pages at base+0 (0x48 MSA), +1 (0x49 DPCD), +2 (0x4A HPD) |
| `LINK_TIMEOUT` | 15 s | Measure the real time-to-link and tune |
| `SETTLE_MS` | 1000 | Measure the shortest that never gives a stale frame, then add margin |
| `CAPTURE_RETRIES` | 3 | |
| `POLL_MS` | 50 | |

---

## 6. Changes to existing files

### New: `ps176_link.py`

Small module plus CLI. Functions:
- `read_link()`: returns a dict with up, rate, lanes, lane status, aligned, sync, caps, and present (answered I2C).
- `read_video()`: returns h_active, v_active, refresh, and valid.
- `wait_for_link(timeout, poll)`: returns timings, or raises on timeout.
- `hpd_toggle(low_ms=100)`.

CLI:
- `python3 ps176_link.py status` prints a one-line state; exit code 0 means up.
- `python3 ps176_link.py wait --timeout 15` exits 0 when the link is up and prints JSON timings. `stream.sh` can call this.

### `stream.sh`

- Add a `capture` command, e.g. `./stream.sh capture [out.png]`, that runs the managed sequence in section 5. Factor the 5 fps ffmpeg start into a function shared with `start-5fps`.
- Add `link-status`, which calls `ps176_link.py status`.
- Extend `status` to show the link state too.
- `loop-test` and `benchmark` must accept the new method (e.g. `managed`) so they can be compared with `5fps` and `ondemand`. The loop-test log must include the per-capture link timings.
- Use `trap` so the stream is always stopped and the lock released on exit.

### `pi_server.py`

- `capture_method` accepts `"managed"`. Make it the default; `"auto"` should pick `managed` when no always-on stream is running.
- Use `ps176_link.py` directly (import), not subprocess-to-bash, for the wait and check.
- `GET /status` adds `link_up`, `source_resolution`, `link_rate_gbps`, `lanes` and `ps176_present`.
- `POST /ocr` response adds the timing breakdown (`link_ms`, `settle_ms`, `capture_ms`, `retries`, `hpd_toggle_used`).
- Use the same lock file as `stream.sh` so a server request and a shell capture can't collide.

### `CLAUDE.md`

- Update the Hardware table: the custom board replaces the USB dongle (keep the dongle note for history).
- Add a short section on link-managed capture, with the I2C requirement and the register summary from section 4.
- Revise "Video Splitter / Startup Order" and "On-Demand vs Loopback" once the tests in section 7 pass.

---

## 7. Tests (acceptance)

Run on the CM5 with the test PC connected, a static test image on screen, and `chain_status.py --uptime` running in a second terminal to watch the link.

1. **Basic:** `./stream.sh capture out.png` gives a correct image and leaves no ffmpeg running afterwards (check `./stream.sh status`). The link goes down after the capture.
2. **Repeatability:** run 100 managed captures in a loop with a 10–30 s gap (`loop-test managed …`).
   - Every capture succeeds, and OCR results match `test_regions.conf`.
   - Record time-to-link min/mean/max.
3. **Freshness:** change what's on the test PC's screen between captures (e.g. a clock or counter). Every capture must show the current content, never the previous one. Use this to set `SETTLE_MS`.
4. **PS176 asleep:** leave the system idle for 2+ minutes so the PS176 powers down, then capture. It must still work; record the longer time-to-link.
5. **External monitor:** watch the monitor on TX0 during tests 2–4. It must **never** blink or blank when the CM5 starts or stops streaming.
6. **Drop during capture:** at 1440p60 (frequent PS176 resets), run 50 captures. Retries should cover the drops; there must be no stale or black images.
7. **Power (optional):** measure board current idle vs streaming, to quantify the saving.
8. **Regression:** the always-on mode (`start-5fps` + `capture-loopback`) still works unchanged.

---

## 8. Constraints and gotchas

- **Never open `/dev/video0` except through the stream ffmpeg process.** Opening and closing it briefly (e.g. `v4l2-ctl`) toggles the MS2130's HPD and knocks the link down.
- **Don't touch the PS8652 over I2C from production code.** It uses windowed 32-bit access with single-byte reads only, and a wrong probe corrupts its pointer. Only the PS176 is needed.
- PS176 I2C reads can fail transiently (`OSError`) during a reset. Catch it, treat it as "down", and keep polling.
- Keep the OCR preprocessing identical in `ocr.sh` and `pi_server.py` (existing rule).
- Don't change the 40% threshold or `--psm 7` (existing rule).
- `chain_status.py` and its README are debug tools. Leave them in `~/debug`, not in this repo, unless the user asks otherwise.
