'use strict'

// ─── Constants ────────────────────────────────────────────────────────────────
const SCENE_W = 1920
const SCENE_H = 1080

// ─── State ────────────────────────────────────────────────────────────────────
let testCase       = null
let selectedIndex  = -1    // index into testCase.regions
let filePath       = null
let scale          = 1     // canvas-to-scene scale factor

// ─── Canvas ───────────────────────────────────────────────────────────────────
const canvas = document.getElementById('preview-canvas')
const ctx    = canvas.getContext('2d')

function computeScale() {
  const wrap = canvas.parentElement
  const maxW = wrap.clientWidth  - 16
  const maxH = wrap.clientHeight - 16
  return Math.min(maxW / SCENE_W, maxH / SCENE_H, 1)
}

function resizeCanvas() {
  scale        = computeScale()
  canvas.width  = Math.floor(SCENE_W * scale)
  canvas.height = Math.floor(SCENE_H * scale)
  drawScene()
}

// ─── Drawing ──────────────────────────────────────────────────────────────────
function drawScene() {
  if (!testCase) return

  const sc = testCase.scene || {}
  ctx.fillStyle = sc.background || '#000000'
  ctx.fillRect(0, 0, canvas.width, canvas.height)

  testCase.regions.forEach((r, i) => {
    const sx = r.x * scale
    const sy = r.y * scale
    const sw = r.w * scale
    const sh = r.h * scale

    // Region background
    ctx.fillStyle = r.bg_color || '#ffffff'
    ctx.fillRect(sx, sy, sw, sh)

    // Text
    const fs = Math.max(6, (r.font_size || 48) * scale)
    ctx.font         = `${fs}px ${r.font_family || 'monospace'}`
    ctx.textAlign    = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillStyle    = r.text_color || '#000000'
    ctx.fillText(r.text || '', sx + sw / 2, sy + sh / 2)

    // Selection highlight
    if (i === selectedIndex) {
      ctx.strokeStyle = '#2563eb'
      ctx.lineWidth   = Math.max(1.5, 2 * scale)
      ctx.strokeRect(sx + 1, sy + 1, sw - 2, sh - 2)
    }
  })
}

// ─── Canvas click → select region ────────────────────────────────────────────
canvas.addEventListener('click', (e) => {
  if (!testCase) return
  const rect = canvas.getBoundingClientRect()
  const cx = (e.clientX - rect.left) * (canvas.width  / rect.width)  / scale
  const cy = (e.clientY - rect.top)  * (canvas.height / rect.height) / scale

  // Search in reverse so topmost (last drawn) wins
  for (let i = testCase.regions.length - 1; i >= 0; i--) {
    const r = testCase.regions[i]
    if (cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h) {
      selectRegion(i)
      return
    }
  }
  selectRegion(-1)
})

window.addEventListener('resize', resizeCanvas)

// ─── Region list ──────────────────────────────────────────────────────────────
function renderRegionList() {
  const list = document.getElementById('region-list')
  if (!testCase || testCase.regions.length === 0) {
    list.innerHTML = '<div style="font-size:11px;color:#94a3b8;padding:10px;text-align:center">No regions yet</div>'
    return
  }
  list.innerHTML = testCase.regions.map((r, i) => `
    <div class="region-item ${i === selectedIndex ? 'selected' : ''}" data-idx="${i}">
      <div class="ri-label">${escHtml(r.label || 'Untitled')}</div>
      <div class="ri-text">${escHtml(r.text || '(no text)')}</div>
      <div class="ri-pos">${r.x},${r.y} ${r.w}×${r.h}</div>
    </div>`).join('')

  list.querySelectorAll('.region-item').forEach(el => {
    el.addEventListener('click', () => selectRegion(parseInt(el.dataset.idx, 10)))
  })
}

// ─── Region selection ─────────────────────────────────────────────────────────
function selectRegion(idx) {
  selectedIndex = idx
  renderRegionList()
  drawScene()

  const empty = document.getElementById('props-empty')
  const props = document.getElementById('region-props')

  if (idx < 0 || !testCase || !testCase.regions[idx]) {
    empty.style.display = 'block'
    props.style.display = 'none'
    return
  }

  empty.style.display = 'none'
  props.style.display = 'block'
  populateProps(testCase.regions[idx])
}

// ─── Property panel ───────────────────────────────────────────────────────────
function populateProps(r) {
  setVal('p-label',    r.label     || '')
  setVal('p-text',     r.text      || '')
  setVal('p-x',        r.x         ?? 100)
  setVal('p-y',        r.y         ?? 100)
  setVal('p-w',        r.w         ?? 400)
  setVal('p-h',        r.h         ?? 100)
  setVal('p-fontsize', r.font_size  ?? 48)
  setVal('p-shave',    r.shave     || '0x0')
  setVal('p-whitelist',r.whitelist || '')

  setColor('p-bg', 'p-bg-hex', r.bg_color    || '#ffffff')
  setColor('p-fg', 'p-fg-hex', r.text_color  || '#000000')

  const font = r.font_family || 'monospace'
  const sel = document.getElementById('p-font')
  // Try to match or default
  sel.value = Array.from(sel.options).some(o => o.value === font) ? font : 'monospace'

  const opts = r.options || []
  setChip('p-invert',  'chip-invert',  opts.includes('invert'))
  setChip('p-scale2x', 'chip-scale2x', opts.includes('scale2x'))
  setChip('p-scale3x', 'chip-scale3x', opts.includes('scale3x'))
}

function setVal(id, val) {
  document.getElementById(id).value = val
}

function setColor(colorId, hexId, hex) {
  document.getElementById(colorId).value = hex
  document.getElementById(hexId).value   = hex
}

function setChip(checkId, chipId, active) {
  document.getElementById(checkId).checked = active
  document.getElementById(chipId).classList.toggle('active', active)
}

// ─── Sync property inputs → testCase ─────────────────────────────────────────
function syncPropsToRegion() {
  if (selectedIndex < 0 || !testCase) return
  const r = testCase.regions[selectedIndex]

  r.label      = getVal('p-label')
  r.text       = getVal('p-text')
  r.x          = clampInt('p-x', 0, SCENE_W)
  r.y          = clampInt('p-y', 0, SCENE_H)
  r.w          = clampInt('p-w', 10, SCENE_W)
  r.h          = clampInt('p-h', 10, SCENE_H)
  r.font_size  = clampInt('p-fontsize', 8, 200)
  r.shave      = getVal('p-shave') || '0x0'
  r.whitelist  = getVal('p-whitelist')
  r.bg_color   = getVal('p-bg-hex') || getVal('p-bg')
  r.text_color = getVal('p-fg-hex') || getVal('p-fg')
  r.font_family = document.getElementById('p-font').value

  const opts = []
  if (document.getElementById('p-invert').checked)  opts.push('invert')
  if (document.getElementById('p-scale2x').checked) opts.push('scale2x')
  if (document.getElementById('p-scale3x').checked) opts.push('scale3x')
  r.options = opts

  renderRegionList()
  drawScene()
}

function getVal(id) { return document.getElementById(id).value.trim() }
function clampInt(id, min, max) {
  return Math.min(max, Math.max(min, parseInt(getVal(id), 10) || min))
}

// Wire up all property inputs to syncPropsToRegion
['p-label','p-text','p-x','p-y','p-w','p-h','p-fontsize','p-shave','p-whitelist',
 'p-bg','p-bg-hex','p-fg','p-fg-hex','p-font',
 'p-invert','p-scale2x','p-scale3x'].forEach(id => {
  const el = document.getElementById(id)
  el.addEventListener('input', () => {
    // Keep color picker and hex in sync
    if (id === 'p-bg')     document.getElementById('p-bg-hex').value = el.value
    if (id === 'p-bg-hex') { try { document.getElementById('p-bg').value = el.value } catch {} }
    if (id === 'p-fg')     document.getElementById('p-fg-hex').value = el.value
    if (id === 'p-fg-hex') { try { document.getElementById('p-fg').value = el.value } catch {} }
    // Update chip active state for checkboxes
    if (id === 'p-invert')  document.getElementById('chip-invert').classList.toggle('active',  el.checked)
    if (id === 'p-scale2x') document.getElementById('chip-scale2x').classList.toggle('active', el.checked)
    if (id === 'p-scale3x') document.getElementById('chip-scale3x').classList.toggle('active', el.checked)
    syncPropsToRegion()
  })
})

// ─── Scene-level inputs ───────────────────────────────────────────────────────
function syncSceneInputs() {
  if (!testCase) return
  testCase.name          = getVal('s-name')
  testCase.scene         = testCase.scene || {}
  testCase.scene.background = getVal('s-bg-hex') || getVal('s-bg')
  testCase.pi_ip         = getVal('s-pi-ip')
  testCase.pi_port       = parseInt(getVal('s-pi-port'), 10) || 8080
  testCase.display_index = parseInt(getVal('s-display'), 10) || 0
  testCase.settle_ms     = parseInt(getVal('s-settle'), 10) || 1000

  const resVal = getVal('s-resolution') || '1920x1080'
  const [sw, sh] = resVal.split('x').map(Number)
  testCase.scene.width  = sw || 1920
  testCase.scene.height = sh || 1080

  document.getElementById('editor-title').textContent = testCase.name || 'Test Case Editor'
  document.getElementById('canvas-info').textContent =
    `Scene preview (${sw}×${sh}) — capture: 1920×1080`
  drawScene()
}

['s-name','s-bg','s-bg-hex','s-pi-ip','s-pi-port','s-display','s-settle','s-resolution'].forEach(id => {
  document.getElementById(id).addEventListener('input', () => {
    if (id === 's-bg')     document.getElementById('s-bg-hex').value = document.getElementById(id).value
    if (id === 's-bg-hex') { try { document.getElementById('s-bg').value = document.getElementById(id).value } catch {} }
    syncSceneInputs()
  })
})

function populateSceneInputs(tc) {
  const sc = tc.scene || {}
  setVal('s-name',    tc.name           || '')
  setVal('s-pi-ip',   tc.pi_ip          || '192.168.1.50')
  setVal('s-pi-port', tc.pi_port        || 8080)
  setVal('s-display', tc.display_index  ?? 1)
  setVal('s-settle',  tc.settle_ms      || 1000)
  setColor('s-bg', 's-bg-hex', sc.background || '#1a1a2e')
  document.getElementById('editor-title').textContent = tc.name || 'Test Case Editor'

  // Set resolution dropdown — add option dynamically if not already present
  const resVal = `${sc.width || 1920}x${sc.height || 1080}`
  const sel    = document.getElementById('s-resolution')
  if (!Array.from(sel.options).some(o => o.value === resVal)) {
    const opt = document.createElement('option')
    opt.value       = resVal
    opt.textContent = resVal.replace('x', '×')
    sel.appendChild(opt)
  }
  sel.value = resVal

  document.getElementById('canvas-info').textContent =
    `Scene preview (${sc.width || 1920}×${sc.height || 1080}) — capture: 1920×1080`
}

// ─── Populate resolution dropdown from xrandr ─────────────────────────────────
async function loadDisplayModes() {
  const sel = document.getElementById('s-resolution')
  let modes
  try {
    modes = await window.api.getDisplayModes()
  } catch {
    modes = []
  }

  // Collect unique resolutions across all displays (already capped at 4K in main.js)
  const seen = new Set()
  const resolutions = []
  for (const display of modes) {
    for (const { w, h } of display.modes) {
      const key = `${w}x${h}`
      if (!seen.has(key)) {
        seen.add(key)
        resolutions.push({ w, h, key })
      }
    }
  }

  // Sort descending by pixel count
  resolutions.sort((a, b) => (b.w * b.h) - (a.w * a.h))

  // Always ensure 1920×1080 is present
  if (!seen.has('1920x1080')) resolutions.push({ w: 1920, h: 1080, key: '1920x1080' })

  // Rebuild options, preserving current selection
  const current = sel.value
  sel.innerHTML = ''
  for (const { w, h, key } of resolutions) {
    const opt = document.createElement('option')
    opt.value       = key
    opt.textContent = `${w}×${h}`
    sel.appendChild(opt)
  }

  // Restore selection if still available, else default to 1920x1080
  sel.value = Array.from(sel.options).some(o => o.value === current) ? current : '1920x1080'
}

// ─── Add/delete regions ───────────────────────────────────────────────────────
document.getElementById('btn-add-region').addEventListener('click', () => {
  if (!testCase) return
  const n = testCase.regions.length + 1
  testCase.regions.push({
    label:       `Region ${n}`,
    x:           100 + (n - 1) * 40,
    y:           100 + (n - 1) * 40,
    w:           400,
    h:           100,
    bg_color:    '#0d0d1a',
    text:        'Sample Text',
    text_color:  '#ffffff',
    font_size:   60,
    font_family: 'monospace',
    shave:       '0x0',
    whitelist:   '',
    options:     ['invert'],
  })
  selectRegion(testCase.regions.length - 1)
})

document.getElementById('btn-delete-region').addEventListener('click', () => {
  if (!testCase || selectedIndex < 0) return
  testCase.regions.splice(selectedIndex, 1)
  selectRegion(-1)
})

// ─── Save ─────────────────────────────────────────────────────────────────────
document.getElementById('btn-save').addEventListener('click', async () => {
  if (!testCase) return

  let savePath = filePath
  if (!savePath) {
    savePath = await window.api.saveFileDialog(`${testCase.name || 'test-case'}.json`)
    if (!savePath) return
    filePath = savePath
  }

  const content = JSON.stringify(testCase, null, 2)
  await window.api.writeFile(savePath, content)

  // Notify the main window so it reloads the updated test case
  window.api.notifyEditorSaved(testCase)

  alert('Test case saved.')
})

// ─── Preview fullscreen ───────────────────────────────────────────────────────
document.getElementById('btn-preview-fs').addEventListener('click', () => {
  if (!testCase) return
  window.api.previewDisplay(testCase)
})

// ─── Receive scene data from main ─────────────────────────────────────────────
window.api.onSceneData((data) => {
  testCase = data
  filePath = null
  populateSceneInputs(testCase)
  selectRegion(-1)
  resizeCanvas()
})

// ─── Initial render ───────────────────────────────────────────────────────────
window.addEventListener('DOMContentLoaded', () => {
  loadDisplayModes()
  resizeCanvas()
})

function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
