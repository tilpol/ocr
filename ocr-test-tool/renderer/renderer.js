'use strict'

// ─── State ────────────────────────────────────────────────────────────────────
let currentTestCase = null
let currentFilePath = null
let running         = false

// ─── DOM refs ─────────────────────────────────────────────────────────────────
const btnLoad     = document.getElementById('btn-load')
const btnNew      = document.getElementById('btn-new')
const btnEdit     = document.getElementById('btn-edit')
const btnRun      = document.getElementById('btn-run')
const btnCheckPi  = document.getElementById('btn-check-pi')
const btnPreview  = document.getElementById('btn-preview')
const piDot       = document.getElementById('pi-dot')
const piStatusTxt = document.getElementById('pi-status-text')
const streamDot   = document.getElementById('stream-dot')
const streamTxt   = document.getElementById('stream-status-text')
const tcPanel     = document.getElementById('test-case-panel')
const resultsArea = document.getElementById('results-area')
const logMsg      = document.getElementById('log-msg')
const timingEl    = document.getElementById('timing')

// ─── Logging ──────────────────────────────────────────────────────────────────
function log(msg) { logMsg.textContent = msg }

// ─── Test case panel ──────────────────────────────────────────────────────────
function renderTestCasePanel(tc) {
  if (!tc) {
    tcPanel.innerHTML = '<p class="test-case-empty">Load or create a test case<br>to get started.</p>'
    return
  }
  const regionCount = tc.regions?.length ?? 0
  tcPanel.innerHTML = `
    <div class="test-case-card">
      <h3>${escHtml(tc.name || 'Untitled')}</h3>
      <div class="pi-addr">${escHtml(tc.pi_ip || '—')}:${tc.pi_port || 8080}</div>
      <div class="region-count">${regionCount} region${regionCount !== 1 ? 's' : ''} &bull;
        Display ${tc.display_index ?? 0} &bull; settle ${tc.settle_ms ?? 1000}ms</div>
    </div>`
}

// ─── Results rendering ────────────────────────────────────────────────────────
function renderPlaceholder() {
  resultsArea.innerHTML = `
    <div class="results-placeholder" id="placeholder">
      <div class="icon">⬡</div>
      <div>Load a test case and click <strong>Run Test</strong></div>
    </div>`
}

function renderRunning() {
  resultsArea.innerHTML = `
    <div class="results-placeholder">
      <div><span class="spinner"></span></div>
      <div>Running test&hellip;</div>
      <div style="font-size:12px;color:var(--muted)">Displaying scene, capturing, OCR&hellip;</div>
    </div>`
}

function renderResults(response) {
  if (!response.success) {
    resultsArea.innerHTML = `
      <div class="results-placeholder">
        <div class="icon" style="color:var(--fail)">✕</div>
        <div>Test failed: ${escHtml(response.error || 'Unknown error')}</div>
      </div>`
    return
  }

  const results   = response.results || []
  const passCount = results.filter(r => r.pass).length
  const failCount = results.length - passCount
  const allPass   = failCount === 0
  const ts        = response.timestamp
    ? new Date(response.timestamp).toLocaleTimeString()
    : ''

  timingEl.textContent = response.capture_ms ? `${response.capture_ms}ms (${response.capture_method})` : ''

  const rows = results.map(r => `
    <tr>
      <td class="result-label">${escHtml(r.label)}</td>
      <td class="result-value">${escHtml(r.expected)}</td>
      <td class="result-value ${r.got ? '' : 'empty'}">${r.got ? escHtml(r.got) : '(empty)'}</td>
      <td><span class="result-badge ${r.pass ? 'pass' : 'fail'}">${r.pass ? 'PASS' : 'FAIL'}</span></td>
    </tr>`).join('')

  resultsArea.innerHTML = `
    <div class="results-header">
      <h2>Results</h2>
      <span class="results-meta">${ts}</span>
    </div>
    <div class="result-summary">
      <span class="summary-chip ${allPass ? 'pass-all' : 'fail-any'}">
        ${allPass ? '✓' : '✕'} ${passCount}/${results.length} PASS
      </span>
      ${failCount > 0 ? `<span class="summary-chip fail-any">${failCount} FAIL</span>` : ''}
    </div>
    <div class="results-table-wrap">
      <table class="results-table">
        <thead>
          <tr>
            <th>Region</th>
            <th>Expected</th>
            <th>Got</th>
            <th>Result</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`
}

// ─── Pi status ────────────────────────────────────────────────────────────────
function setPiStatus(status) {
  if (!status) {
    piDot.className = 'status-dot'
    piStatusTxt.textContent = 'Pi — not connected'
    streamDot.className = 'status-dot'
    streamTxt.textContent = 'Stream — unknown'
    return
  }
  if (status.ok) {
    piDot.className = 'status-dot ok'
    piStatusTxt.textContent = `Pi — connected`
    streamDot.className = `status-dot ${status.streaming ? 'stream' : 'error'}`
    streamTxt.textContent  = `Stream — ${status.streaming ? 'running' : 'stopped'}`
  } else {
    piDot.className = 'status-dot error'
    piStatusTxt.textContent = `Pi — ${status.error || 'unreachable'}`
    streamDot.className = 'status-dot'
    streamTxt.textContent = 'Stream — unknown'
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function loadTestCase(tc, filePath) {
  currentTestCase = tc
  currentFilePath = filePath
  renderTestCasePanel(tc)
  renderPlaceholder()
  btnEdit.disabled = false
  btnRun.disabled  = false
  btnPreview.disabled = false
  log(`Loaded: ${tc.name || 'Untitled'}`)
  timingEl.textContent = ''
}

// ─── Button handlers ──────────────────────────────────────────────────────────

btnLoad.addEventListener('click', async () => {
  const filePath = await window.api.openFileDialog()
  if (!filePath) return
  try {
    const raw = await window.api.readFile(filePath)
    const tc  = JSON.parse(raw)
    loadTestCase(tc, filePath)
  } catch (e) {
    log(`Error loading file: ${e.message}`)
  }
})

btnNew.addEventListener('click', () => {
  const blank = {
    name:          'New Test Case',
    pi_ip:         '192.168.1.50',
    pi_port:       8080,
    display_index: 1,
    settle_ms:     1000,
    scene:         { width: 1920, height: 1080, background: '#1a1a2e' },
    regions:       [],
  }
  window.api.openEditor(blank)
})

btnEdit.addEventListener('click', () => {
  if (currentTestCase) window.api.openEditor(currentTestCase)
})

btnCheckPi.addEventListener('click', async () => {
  if (!currentTestCase) { log('Load a test case first'); return }
  log('Checking Pi…')
  const status = await window.api.checkPiStatus(currentTestCase.pi_ip, currentTestCase.pi_port)
  setPiStatus(status)
  log(status.ok ? 'Pi connected' : `Pi unreachable: ${status.error}`)
})

btnPreview.addEventListener('click', () => {
  if (!currentTestCase) { log('Load a test case first'); return }
  window.api.previewDisplay(currentTestCase)
  log('Display preview opened')
})

btnRun.addEventListener('click', async () => {
  if (!currentTestCase || running) return
  running = true
  btnRun.disabled = true
  log('Running test…')
  renderRunning()
  timingEl.textContent = ''

  try {
    const result = await window.api.runTest(currentTestCase)
    renderResults(result)
    if (result.success) {
      const pass = result.results.filter(r => r.pass).length
      const total = result.results.length
      log(`Test complete — ${pass}/${total} passed`)
    } else {
      log(`Test failed: ${result.error}`)
    }
  } catch (e) {
    log(`Unexpected error: ${e.message}`)
    renderResults({ success: false, error: e.message })
  } finally {
    running = false
    btnRun.disabled = false
  }
})

// ─── Editor saved callback ────────────────────────────────────────────────────
window.api.onEditorSaved((tc) => {
  loadTestCase(tc, currentFilePath)
  log(`Test case updated: ${tc.name || 'Untitled'}`)
})
