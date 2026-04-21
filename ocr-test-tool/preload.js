'use strict'
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  // ── File operations ──────────────────────────────────────────────────────
  openFileDialog:   ()                   => ipcRenderer.invoke('open-file-dialog'),
  openFolderDialog: ()                   => ipcRenderer.invoke('open-folder-dialog'),
  saveFileDialog:   (defaultName)        => ipcRenderer.invoke('save-file-dialog', defaultName),
  readFile:         (filePath)           => ipcRenderer.invoke('read-file', filePath),
  writeFile:        (filePath, content)  => ipcRenderer.invoke('write-file', filePath, content),
  listTestCases:    (dirPath)            => ipcRenderer.invoke('list-test-cases', dirPath),

  // ── Pi communication ─────────────────────────────────────────────────────
  checkPiStatus:   (ip, port)            => ipcRenderer.invoke('check-pi-status', ip, port),
  runTest:         (testCase)            => ipcRenderer.invoke('run-test', testCase),

  // ── Window management ────────────────────────────────────────────────────
  openEditor:       (testCase)           => ipcRenderer.invoke('open-editor', testCase),
  getDisplays:      ()                   => ipcRenderer.invoke('get-displays'),
  getDisplayModes:  ()                   => ipcRenderer.invoke('get-display-modes'),
  previewDisplay:   (testCase)           => ipcRenderer.invoke('preview-display', testCase),

  // ── Display window (used by display.html only) ───────────────────────────
  getSceneData:    ()   => ipcRenderer.invoke('get-scene-data'),
  closeDisplay:    ()   => ipcRenderer.invoke('close-display'),
  signalReady:     ()   => ipcRenderer.send('display-ready'),

  // ── Editor ↔ main-window sync ────────────────────────────────────────────
  onSceneData:       (cb) => ipcRenderer.on('scene-data',       (_, d) => cb(d)),
  notifyEditorSaved: (testCase) => ipcRenderer.send('editor-saved-to-main', testCase),
  onTestCaseLoaded:  (cb) => ipcRenderer.on('test-case-loaded', (_, d) => cb(d)),
  onEditorSaved:     (cb) => ipcRenderer.on('editor-saved',     (_, d) => cb(d)),
})
