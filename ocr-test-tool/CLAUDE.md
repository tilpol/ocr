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
npm start      # launches the app
```

Requires Node.js. No other dependencies.

**Linux display resolution changing** requires an **X11 session** (not Wayland). On Ubuntu
22.04+, select "Ubuntu on Xorg" at the GDM login screen. The app uses `xrandr` to change
the monitor resolution before opening the display window and restores it automatically
afterwards. On Wayland, the resolution dropdown still populates but the `xrandr` change
is silently skipped — the window opens at native resolution.

---

## File Structure

```
ocr-test-tool/
├── main.js              # Electron main process — all IPC, HTTP, window management
├── preload.js           # Context bridge — exposes window.api to all renderer windows
├── renderer/
│   ├── index.html       # Main window UI
│   ├── renderer.js      # Main window logic
│   └── styles.css       # Shared styles
├── editor/
│   ├── editor.html      # Test case editor window
│   └── editor.js        # Editor logic — canvas preview, region property panel
├── display/
│   └── display.html     # Fullscreen scene renderer (opens on capture monitor)
└── test-cases/
    └── example.json     # Example test case with 3 OCR scenarios
```

---

## Architecture

**Three windows, all using the same `preload.js`:**

1. **Main window** (`renderer/`) — load test cases, check Pi status, run tests, view results
2. **Editor window** (`editor/`) — build and edit test case JSON with a live canvas preview
3. **Display window** (`display/`) — frameless, fullscreen, renders the scene to `<canvas>`

**IPC rule:** All Pi HTTP calls and file I/O happen in `main.js` (main process). Renderer
windows only send/receive data — they never do networking or disk access directly. This avoids
CORS issues and keeps renderer code simple.

**`preload.js` exposes `window.api`** to all windows via `contextBridge`. Any new IPC channel
needs a handler in both `main.js` (ipcMain.handle/on) and `preload.js` (contextBridge).

---

## Test Case JSON Format

```json
{
  "name":          "Jackpot Display — Dark Background",
  "pi_ip":         "192.168.1.50",
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

## Display Resolution Flow

When a test runs or a preview is opened:

1. `main.js` reads `testCase.scene.width/height` (default 1920×1080)
2. Calls `xrandr --query` to find the output name for `display_index` and its available modes
3. If the requested resolution differs from current and is available, runs
   `xrandr --output <name> --mode <WxH>` and waits 300ms for the mode change to settle
4. Opens the display window fullscreen at the new bounds
5. `display.html` canvas renders at scene resolution, with regions scaled up from capture space
6. On display window close, `main.js` restores the original resolution via xrandr

---

## Test Flow (run-test IPC)

1. `renderer.js` calls `window.api.runTest(testCase)` → `main.js ipcMain.handle('run-test')`
2. `main.js` sets display resolution via xrandr if needed, opens display window
3. `display.html` renders scene to canvas (scaling regions from 1920×1080 capture space),
   calls `window.api.signalReady()`
4. `main.js` receives `display-ready` signal, waits `settle_ms`
5. `main.js` POSTs to `http://{pi_ip}:{pi_port}/ocr` with region list (no expected values)
6. Pi captures HDMI feed at 1920×1080, OCRs each region using the original crop coords
7. `main.js` closes display window (xrandr restores resolution), attaches expected values,
   computes pass/fail
8. Returns result to `renderer.js` which renders the results table

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
  "regions": [
    { "label": "Major Progressive", "crop": "579x124+679+693",
      "shave": "0x0", "whitelist": "", "options": ["invert"] }
  ]
}
```

**`POST /ocr`** — response:
```json
{
  "success": true, "capture_ms": 530, "capture_method": "loopback",
  "timestamp": "2026-04-16T14:30:00Z",
  "results": [{ "label": "Major Progressive", "value": "$7,500.05" }]
}
```

The HTTP client in `main.js` uses Node's built-in `http` module — no external npm packages
for networking.

---

## Editor Canvas

- Region coordinates are always in **1920×1080 capture space** — the coordinate system of
  the MS2130 output image, regardless of scene resolution
- The editor canvas is scaled down to fit the window (scale factor ~0.5)
- Drawing uses `coord * scale`; click-to-select converts back: `clickCoord / scale`
- `display.html` renders the canvas at the full scene resolution (`scene.width × scene.height`)
  and scales all region coordinates by `(scene_w/1920, scene_h/1080)` before drawing
- The "Scene Size" dropdown in the editor is populated from `xrandr` available modes (up to 4K)

---

## OCR Options Reference

These come from the Pi's preprocessing pipeline — `options` in the region definition maps
directly to ImageMagick flags applied before Tesseract:

| Option   | Effect                          | When to use                         |
| -------- | ------------------------------- | ------------------------------------ |
| `invert` | Negate image before threshold   | White or light text on dark background |
| `scale2x`| Resize to 200% before OCR       | Small text (font size < ~40px)      |
| `scale3x`| Resize to 300% before OCR       | Very small text                     |

`whitelist`: restrict Tesseract to specific characters, e.g. `"0123456789.$"` for currency.
`shave`: trim N pixels from all edges of the cropped region, e.g. `"5x5"`. Use `"0x0"` to skip.

---

## Adding a New Feature

1. If it needs data from disk or the network — add an `ipcMain.handle` in `main.js` and
   expose it via `preload.js`
2. If it's UI-only — add it directly in the renderer HTML/JS file for that window
3. If it adds a new property to the test case JSON — update the editor property panel
   (`editor.js`), the display renderer (`display.html`), and the `run-test` IPC handler
   in `main.js` where crop geometry is derived
