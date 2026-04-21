'use strict'
const { app, BrowserWindow, ipcMain, dialog, screen } = require('electron')
const path            = require('path')
const fs              = require('fs')
const http            = require('http')
const { execSync }    = require('child_process')

// ─── Window references ────────────────────────────────────────────────────────
let mainWindow    = null
let editorWindow  = null
let displayWindow = null

// ─── xrandr — display resolution management ───────────────────────────────────

// Map of outputName → original mode string ('1920x1080'), saved before any change
const savedResolutions = new Map()

// Parse `xrandr --query` output.
// Returns [{ displayIndex, outputName, currentMode, modes: [{w,h}] }]
// Returns [] if xrandr is unavailable or fails (Wayland, etc.)
function getXrandrInfo() {
  let raw
  try {
    raw = execSync('xrandr --query', { encoding: 'utf8' })
  } catch {
    return []
  }

  const displays = screen.getAllDisplays()
  const results  = []
  let current    = null

  for (const line of raw.split('\n')) {
    // Output line: "HDMI-1 connected primary 1920x1080+0+0 ..."
    const outMatch = line.match(/^(\S+)\s+connected\s+(?:primary\s+)?(\d+)x(\d+)\+(\d+)\+(\d+)/)
    if (outMatch) {
      const [, name, , , ox, oy] = outMatch
      // Match to Electron display by top-left corner position
      const idx = displays.findIndex(
        d => d.bounds.x === parseInt(ox, 10) && d.bounds.y === parseInt(oy, 10)
      )
      current = {
        displayIndex: idx >= 0 ? idx : results.length,
        outputName:   name,
        currentMode:  `${outMatch[2]}x${outMatch[3]}`,
        modes:        [],
      }
      results.push(current)
      continue
    }

    // Mode line: "   1920x1080     60.00*+  50.00  ..."
    if (current) {
      const modeMatch = line.match(/^\s+(\d+)x(\d+)\s/)
      if (modeMatch) {
        const w = parseInt(modeMatch[1], 10)
        const h = parseInt(modeMatch[2], 10)
        // Cap at 4K
        if (w <= 3840 && h <= 2160) {
          // Avoid duplicates (multiple refresh rates share same WxH)
          if (!current.modes.some(m => m.w === w && m.h === h)) {
            current.modes.push({ w, h })
          }
        }
      }
    }
  }

  return results
}

function setXrandrResolution(outputName, currentMode, w, h) {
  if (!savedResolutions.has(outputName)) {
    savedResolutions.set(outputName, currentMode)
  }
  try {
    execSync(`xrandr --output ${outputName} --mode ${w}x${h}`)
  } catch (err) {
    console.error(`xrandr set failed: ${err.message}`)
  }
}

function restoreXrandrResolution(outputName) {
  const saved = savedResolutions.get(outputName)
  if (!saved) return
  savedResolutions.delete(outputName)
  try {
    execSync(`xrandr --output ${outputName} --mode ${saved}`)
  } catch (err) {
    console.error(`xrandr restore failed: ${err.message}`)
  }
}

// ─── App lifecycle ────────────────────────────────────────────────────────────

app.whenReady().then(createMainWindow)

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createMainWindow()
})

// ─── Window factories ─────────────────────────────────────────────────────────

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width:  1100,
    height: 720,
    minWidth:  800,
    minHeight: 560,
    title: 'OCR Test Tool',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'))
  mainWindow.on('closed', () => { mainWindow = null })
}

function createEditorWindow(testCase) {
  if (editorWindow) {
    editorWindow.focus()
    return
  }
  editorWindow = new BrowserWindow({
    width:  1200,
    height: 800,
    minWidth:  900,
    minHeight: 600,
    title: 'Test Case Editor',
    parent: mainWindow,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })
  editorWindow.loadFile(path.join(__dirname, 'editor', 'editor.html'))
  editorWindow.webContents.on('did-finish-load', () => {
    editorWindow.webContents.send('scene-data', testCase)
  })
  editorWindow.on('closed', () => { editorWindow = null })
}

function createDisplayWindow(testCase) {
  if (displayWindow) displayWindow.close()

  const displayIdx = testCase.display_index ?? 0
  const sceneW     = (testCase.scene || {}).width  || 1920
  const sceneH     = (testCase.scene || {}).height || 1080

  // Attempt to set the target display to the requested resolution via xrandr.
  // This is a no-op if xrandr is unavailable (Wayland / non-Linux).
  let xrandrOutput = null
  const xrandrInfo = getXrandrInfo()
  const xrandrEntry = xrandrInfo.find(e => e.displayIndex === displayIdx)
  if (xrandrEntry) {
    xrandrOutput = xrandrEntry.outputName
    const [cw, ch] = xrandrEntry.currentMode.split('x').map(Number)
    if (cw !== sceneW || ch !== sceneH) {
      // Only change if the mode is actually available
      if (xrandrEntry.modes.some(m => m.w === sceneW && m.h === sceneH)) {
        setXrandrResolution(xrandrOutput, xrandrEntry.currentMode, sceneW, sceneH)
        // Give the display server time to apply the mode change
        execSync('sleep 0.3')
      }
    }
  }

  // Re-query displays after possible resolution change
  const displays   = screen.getAllDisplays()
  const targetDisp = displays[displayIdx] || displays[displays.length - 1]
  const { x, y, width, height } = targetDisp.bounds

  displayWindow = new BrowserWindow({
    x, y, width, height,
    frame:       false,
    alwaysOnTop: true,
    skipTaskbar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })
  displayWindow.loadFile(path.join(__dirname, 'display', 'display.html'))
  displayWindow.webContents.on('did-finish-load', () => {
    displayWindow.webContents.send('scene-data', testCase)
  })
  displayWindow.on('closed', () => {
    // Restore display resolution if we changed it
    if (xrandrOutput) restoreXrandrResolution(xrandrOutput)
    displayWindow = null
  })
  return displayWindow
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function httpGet(ip, port, path_) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: ip, port: parseInt(port, 10), path: path_, method: 'GET' },
      (res) => {
        let data = ''
        res.on('data', chunk => { data += chunk })
        res.on('end', () => {
          try { resolve(JSON.parse(data)) }
          catch (e) { reject(new Error('Invalid JSON response')) }
        })
      }
    )
    req.on('error', reject)
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('Connection timed out')) })
    req.end()
  })
}

function httpPost(ip, port, path_, body) {
  const payload = JSON.stringify(body)
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: ip,
        port:     parseInt(port, 10),
        path:     path_,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/json',
          'Content-Length': Buffer.byteLength(payload),
        },
      },
      (res) => {
        let data = ''
        res.on('data', chunk => { data += chunk })
        res.on('end', () => {
          try { resolve(JSON.parse(data)) }
          catch (e) { reject(new Error('Invalid JSON response')) }
        })
      }
    )
    req.on('error', reject)
    req.setTimeout(60000, () => { req.destroy(); reject(new Error('OCR request timed out')) })
    req.write(payload)
    req.end()
  })
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

// ─── IPC — file operations ────────────────────────────────────────────────────

ipcMain.handle('open-file-dialog', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title:       'Open Test Case',
    filters:     [{ name: 'JSON Test Case', extensions: ['json'] }],
    properties:  ['openFile'],
  })
  return result.canceled ? null : result.filePaths[0]
})

ipcMain.handle('save-file-dialog', async (_, defaultName) => {
  const result = await dialog.showSaveDialog(mainWindow, {
    title:       'Save Test Case',
    defaultPath: defaultName || 'test-case.json',
    filters:     [{ name: 'JSON Test Case', extensions: ['json'] }],
  })
  return result.canceled ? null : result.filePath
})

ipcMain.handle('read-file', async (_, filePath) => {
  return fs.readFileSync(filePath, 'utf8')
})

ipcMain.handle('write-file', async (_, filePath, content) => {
  fs.writeFileSync(filePath, content, 'utf8')
  return true
})

// ─── IPC — Pi communication ───────────────────────────────────────────────────

ipcMain.handle('check-pi-status', async (_, ip, port) => {
  try {
    return await httpGet(ip, port, '/status')
  } catch (err) {
    return { ok: false, error: err.message }
  }
})

// ─── IPC — run test ───────────────────────────────────────────────────────────

ipcMain.handle('run-test', async (_, testCase) => {
  // 1. Open display window and wait for it to signal ready
  const dispWin = createDisplayWindow(testCase)

  const displayReady = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Display window did not respond')), 10000)
    ipcMain.once('display-ready', (event) => {
      if (event.sender === dispWin.webContents) {
        clearTimeout(timeout)
        resolve()
      }
    })
  })

  try {
    await displayReady
  } catch (err) {
    dispWin.close()
    return { success: false, error: err.message }
  }

  // 2. Wait for HDMI to settle
  const settleMs = testCase.settle_ms ?? 1000
  await sleep(settleMs)

  // 3. Build OCR region list — derive crop geometry from x/y/w/h
  const ocrRegions = testCase.regions.map(r => ({
    label:     r.label,
    crop:      `${r.w}x${r.h}+${r.x}+${r.y}`,
    shave:     r.shave     || '0x0',
    whitelist: r.whitelist || '',
    options:   r.options   || [],
  }))

  // 4. POST to Pi
  let piResponse
  try {
    piResponse = await httpPost(
      testCase.pi_ip,
      testCase.pi_port,
      '/ocr',
      { capture_method: 'auto', regions: ocrRegions }
    )
  } catch (err) {
    dispWin.close()
    return { success: false, error: `Pi unreachable: ${err.message}` }
  } finally {
    dispWin.close()
  }

  // 5. Attach expected values and compute pass/fail
  const results = piResponse.results.map(r => {
    const region   = testCase.regions.find(reg => reg.label === r.label)
    const expected = region ? region.text : ''
    return {
      label:    r.label,
      expected,
      got:      r.value,
      pass:     r.value.trim() === expected.trim(),
    }
  })

  return {
    success:        true,
    capture_ms:     piResponse.capture_ms,
    capture_method: piResponse.capture_method,
    timestamp:      piResponse.timestamp,
    results,
  }
})

// ─── IPC — window management ──────────────────────────────────────────────────

ipcMain.handle('open-editor', (_, testCase) => {
  createEditorWindow(testCase)
})

ipcMain.handle('get-displays', () => {
  return screen.getAllDisplays().map((d, i) => ({
    index:      i,
    label:      `Display ${i + 1} (${d.bounds.width}×${d.bounds.height})`,
    bounds:     d.bounds,
    isPrimary:  d.id === screen.getPrimaryDisplay().id,
  }))
})

ipcMain.handle('get-display-modes', () => getXrandrInfo())

ipcMain.handle('preview-display', (_, testCase) => {
  createDisplayWindow(testCase)
})

// ─── IPC — editor saved ───────────────────────────────────────────────────────
// When the editor saves a test case it sends this to main, which forwards
// the updated test case to the main window so it can reload without a file dialog.

ipcMain.on('editor-saved-to-main', (_, testCase) => {
  if (mainWindow) mainWindow.webContents.send('editor-saved', testCase)
})
