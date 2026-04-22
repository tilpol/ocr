# OCR Test Tool — Electron App

Cross-platform desktop app (Ubuntu Linux / Windows) for validating the Pi HDMI capture + OCR
pipeline. The test machine connects via HDMI to the Pi's MS2130 capture card. This app generates
a known test image at a selected resolution, displays it fullscreen on that HDMI output, tells
the Pi to capture and OCR it, then receives the results and evaluates pass/fail.

The Pi-side HTTP server that this app talks to lives at `../pi_server.py` — see `../CLAUDE.md`
for the Pi project context.

---

## Running

```bash
npm install    # first time only — installs Electron
npm start      # launches the app (runs electron . --no-sandbox)
```

Requires Node.js. No other dependencies.

**Must run in an X11 session** (not Wayland). On Ubuntu 22.04+, select "Ubuntu on Xorg" at the
GDM login screen. On Wayland, `$DISPLAY` is not set and Electron will not start.

**Display resolution** is not changed by the app. Before running a test, manually set the HDMI
monitor (display_index) to the resolution matching `scene.width × scene.height` in the test
case. If the resolution doesn't match, the test will fail immediately with a clear error.

---

## File Structure

```
ocr-test-tool/
├── main.js              # Electron main process — all IPC, HTTP, window management
├── preload.js           # Context bridge — exposes window.api to all renderer windows
├── renderer/
│   ├── index.html       # Main window UI
│   ├── renderer.js      # Main window logic — single test + suite runner
│   └── styles.css       # Shared styles
├── editor/
│   ├── editor.html      # Test case editor window
│   └── editor.js        # Editor logic — canvas preview, region property panel
├── display/
│   ├── display.html     # Fullscreen scene renderer (opens on capture monitor)
│   └── display.js       # Scene rendering logic (external file, required by CSP)
├── logs/                # Suite run logs — auto-named suite_YYYY-MM-DDTHH-MM-SS.log
└── test-cases/
    ├── example.json     # Example test case with 3 OCR scenarios
    ├── 720p/            # 10 pre-built 720p (1280×720) test cases
    ├── 900p/            # 10 pre-built 900p (1600×900) test cases
    ├── 1080p/           # 10 pre-built 1080p (1920×1080) test cases
    └── 2K/              # 10 pre-built 2K (2560×1440) test cases
        ├── 01-single-dark-currency.json
        ├── 02-single-white-on-black.json
        └── ...
```

---

## Architecture

**Three windows, all using the same `preload.js`:**

1. **Main window** (`renderer/`) — load test cases, check Pi status, run single test or suite
2. **Editor window** (`editor/`) — build and edit test case JSON with a live canvas preview
3. **Display window** (`display/`) — frameless, fullscreen, renders the scene to `<canvas>`

**IPC rule:** All Pi HTTP calls and file I/O happen in `main.js` (main process). Renderer
windows only send/receive data — they never do networking or disk access directly.

**`preload.js` exposes `window.api`** to all windows via `contextBridge`. Any new IPC channel
needs a handler in both `main.js` (ipcMain.handle/on) and `preload.js` (contextBridge).

**CSP note:** `display.html` and `editor.html` have a strict Content Security Policy that blocks
inline scripts. All JavaScript must live in external `.js` files (e.g. `display.js`, `editor.js`).

**Scene data flow:** `main.js` stores the pending test case in `pendingSceneData` before opening
the display window. The display window calls `window.api.getSceneData()` on `DOMContentLoaded`
to pull it — no push/timing race.

**Pi IP persistence:** `renderer.js` saves `pi_ip` and `pi_port` to `localStorage` whenever a
test case is loaded. On startup, if a saved IP exists, the Pi is checked automatically and the
status bar shows the IP. The **Check Pi** button works even without a loaded test case by
using the saved IP.

---

## Test Case JSON Format

```json
{
  "name":          "Jackpot Display — Dark Background",
  "pi_ip":         "192.168.1.166",
  "pi_port":       8080,
  "display_index": 1,
  "settle_ms":     1000,
  "scene": {
    "width": 1920, "height": 1080, "background": "#1a1a2e"
  },
  "regions": [
    {
      "label":       "Major Progressive",
      "x": 679, "y": 693, "w": 579, "h": 124,
      "bg_color":    "#0d0d1a",
      "text":        "$7,500.05",
      "text_color":  "#ffffff",
      "font_size":   72,
      "font_family": "monospace",
      "shave":       "0x0",
      "whitelist":   "",
      "options":     ["invert"]
    }
  ]
}
```

**Key design:** `x, y, w, h` are always in **1920×1080 capture-space coordinates** — the
coordinate system of the image the MS2130 delivers, regardless of display scene resolution.
When sending to the Pi, `main.js` derives crop geometry directly: `"{w}x{h}+{x}+{y}"`.

`scene.width` / `scene.height`: the resolution at which the test image is displayed. The
display canvas scales all region positions and sizes by `(scene_w/1920, scene_h/1080)` so
they map correctly after the MS2130 downsamples to 1920×1080. Defaults to 1920×1080.

`display_index`: which monitor to open the display window on (0 = primary). Set this to
whichever monitor is connected via HDMI to the Pi's capture card.

`settle_ms`: how long to wait after the display window renders before sending the OCR request
to the Pi. 1000ms is usually enough for the HDMI signal to stabilise.

---

## Test Flow (run-test IPC)

1. `renderer.js` calls `window.api.runTest(testCase, options)` → `main.js ipcMain.handle('run-test')`
2. `main.js` checks display resolution via `xrandr --query` — returns error immediately if
   `display_index` resolution ≠ `scene.width × scene.height`
3. `main.js` opens the display window fullscreen on `display_index`
4. `display.js` pulls scene data via `getSceneData()`, renders canvas, calls `signalReady()`
5. `main.js` receives `display-ready` signal, waits `settle_ms`
6. `main.js` POSTs to `http://{pi_ip}:{pi_port}/ocr` with region list (no expected values);
   if `options.save_images` is true, `save_images: true` is included in the POST body
7. Pi captures HDMI feed at 1920×1080, OCRs each region using the original crop coords
8. `main.js` closes display window, attaches expected values, computes pass/fail
9. Returns result to `renderer.js` which renders the results table; if `saved_images_dir` is
   present in the Pi response, it is shown below the results header

---

## Suite Runner

The **Run Suite** button opens a folder picker. All `.json` files in the chosen folder are run
in alphabetical order. The toolbar has two controls next to the button:

- **Passes input** (number, default 0): how many complete passes to run; `0` loops forever
- **Save images checkbox**: if checked, passes `save_images: true` to the Pi on every test —
  the Pi saves `capture.png` + processed region images to `/tmp/ocr_captures/<timestamp>/`
  and returns the path; it is shown below the results header

Suite behaviour:

- Each file gets a PASS/FAIL row in the suite panel with failure detail if OCR doesn't match
- A divider row marks the end of each complete pass (shows `Pass N / M` when a limit is set)
- On failure the suite stops immediately and shows which region failed and what was expected vs got
- A timestamped log file is written to `logs/suite_<timestamp>.log` with per-test PASS/FAIL
  lines, per-region detail, and a summary at the end
- `test-cases/2K/`, `test-cases/1080p/`, `test-cases/900p/`, and `test-cases/720p/` each
  contain 10 pre-built cases covering 1–5 regions, varied contrast, and scale2x/scale3x options

---

## Pi Server API (what this app calls)

**`GET /status`**
```json
{ "ok": true, "streaming": true, "device_present": true }
```

**`POST /ocr`** — body:
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
`save_images`: if `true`, the Pi saves `capture.png` + one processed PNG per region to
`/tmp/ocr_captures/<timestamp>/` and includes `saved_images_dir` in the response.

**`POST /ocr`** — response:
```json
{
  "success": true, "capture_ms": 530, "capture_method": "loopback",
  "timestamp": "2026-04-16T14:30:00Z",
  "saved_images_dir": "/tmp/ocr_captures/20260416_143000",
  "results": [{ "label": "Major Progressive", "value": "$7,500.05" }]
}
```
`saved_images_dir` is only present when `save_images` was `true` in the request.

The HTTP client in `main.js` uses Node's built-in `http` module — no external npm packages
for networking.

---

## OCR Options Reference

| Option   | Effect                          | When to use                            |
| -------- | ------------------------------- | -------------------------------------- |
| `invert` | Negate image before threshold   | White or light text on dark background |
| `scale2x`| Resize to 200% before OCR       | Small text (font size < ~40px)         |
| `scale3x`| Resize to 300% before OCR       | Very small text                        |

`whitelist`: restrict Tesseract to specific characters, e.g. `"0123456789.$"` for currency.
`shave`: trim N pixels from all edges of the cropped region, e.g. `"5x5"`. Use `"0x0"` to skip.

---

## Adding a New Feature

1. If it needs data from disk or the network — add an `ipcMain.handle` in `main.js` and
   expose it via `preload.js`
2. If it's UI-only — add it directly in the renderer HTML/JS file for that window
3. If it adds a new property to the test case JSON — update the editor property panel
   (`editor.js`), the display renderer (`display.js`), and the `run-test` IPC handler
   in `main.js` where crop geometry is derived
4. Never put `<script>` blocks inline in HTML files — the CSP will block them
