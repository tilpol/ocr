'use strict'

// ─── State ────────────────────────────────────────────────────────────────────
let currentTestCase = null
let currentFilePath = null
let running         = false
let suiteRunning    = false
let suiteStopFlag   = false

// ─── DOM refs ─────────────────────────────────────────────────────────────────
const saveImagesCb  = document.getElementById('save-images-cb')
const btnLoad       = document.getElementById('btn-load')
const btnNew        = document.getElementById('btn-new')
const btnEdit       = document.getElementById('btn-edit')
const btnRun        = document.getElementById('btn-run')
const btnCheckPi    = document.getElementById('btn-check-pi')
const btnPreview    = document.getElementById('btn-preview')
const btnRunSuite    = document.getElementById('btn-run-suite')
const btnStopSuite   = document.getElementById('btn-stop-suite')
const suiteIterInput = document.getElementById('suite-iterations')
const suitePanel    = document.getElementById('suite-panel')
const suiteStatusTx = document.getElementById('suite-status-text')
const suitePassCnt  = document.getElementById('suite-pass-count')
const suiteFileList = document.getElementById('suite-file-list')
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

  const savedDirHtml = response.saved_images_dir
    ? `<div class="saved-images-note">Images saved on Pi: <code>${escHtml(response.saved_images_dir)}</code></div>`
    : ''

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
    ${savedDirHtml}
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
  const savedIp = localStorage.getItem('pi_ip') || ''
  const ipLabel = savedIp ? ` (${savedIp})` : ''
  if (!status) {
    piDot.className = 'status-dot'
    piStatusTxt.textContent = `Pi${ipLabel} — not connected`
    streamDot.className = 'status-dot'
    streamTxt.textContent = 'Stream — unknown'
    return
  }
  if (status.ok) {
    piDot.className = 'status-dot ok'
    piStatusTxt.textContent = `Pi${ipLabel} — connected`
    streamDot.className = `status-dot ${status.streaming ? 'stream' : 'error'}`
    streamTxt.textContent  = `Stream — ${status.streaming ? 'running' : 'stopped'}`
  } else {
    piDot.className = 'status-dot error'
    piStatusTxt.textContent = `Pi${ipLabel} — ${status.error || 'unreachable'}`
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
  if (tc.pi_ip) {
    localStorage.setItem('pi_ip',   tc.pi_ip)
    localStorage.setItem('pi_port', String(tc.pi_port || 8080))
  }
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
  const ip   = currentTestCase?.pi_ip   || localStorage.getItem('pi_ip')
  const port = currentTestCase?.pi_port || parseInt(localStorage.getItem('pi_port') || '8080', 10)
  if (!ip) { log('No Pi IP configured — load a test case first'); return }
  log(`Checking Pi at ${ip}…`)
  const status = await window.api.checkPiStatus(ip, port)
  setPiStatus(status)
  log(status.ok ? `Pi connected (${ip})` : `Pi unreachable: ${status.error}`)
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
    const result = await window.api.runTest(currentTestCase, { save_images: saveImagesCb.checked })
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

// ─── Suite runner ─────────────────────────────────────────────────────────────

function appendSuiteRow(filePath, state, detail) {
  const name = filePath.split('/').pop()
  const row  = document.createElement('div')
  row.className = `suite-row suite-row-${state}`
  const labelMap = { running: 'Running', pass: 'PASS', fail: 'FAIL' }
  row.innerHTML = `
    <span class="suite-badge">${labelMap[state]}</span>
    <span class="suite-row-filename">${escHtml(name)}</span>
    ${detail ? `<span class="suite-row-detail">${escHtml(detail)}</span>` : ''}
  `
  suiteFileList.appendChild(row)
  suiteFileList.scrollTop = suiteFileList.scrollHeight
  return row
}

function appendSuiteDivider(passNum, maxIter) {
  const div = document.createElement('div')
  div.className = 'suite-pass-divider'
  div.textContent = maxIter > 0
    ? `— Pass ${passNum} / ${maxIter} complete —`
    : `— Pass ${passNum} complete —`
  suiteFileList.appendChild(div)
  suiteFileList.scrollTop = suiteFileList.scrollHeight
}

// ─── Suite log helpers ────────────────────────────────────────────────────────
function fmtDateTime(d = new Date()) {
  return d.toISOString().replace('T', ' ').slice(0, 19)
}
function fmtTime(d = new Date()) {
  return d.toISOString().slice(11, 19)
}
function buildTestLogEntry(filename, result, err) {
  const time = fmtTime()
  if (err) {
    return `[${time}] ERROR ${filename}\n           ${err}\n`
  }
  if (!result.success) {
    return `[${time}] ERROR ${filename}\n           ${result.error || 'Unknown error'}\n`
  }
  const allPass  = result.results.every(r => r.pass)
  const capture  = result.capture_ms ? `${result.capture_ms}ms, ${result.capture_method}` : ''
  let entry = `[${time}] ${allPass ? 'PASS' : 'FAIL'}  ${filename}${capture ? `  (${capture})` : ''}\n`
  for (const r of result.results) {
    entry += `           ${r.label}: expected "${r.expected}" → got "${r.got}" ${r.pass ? '✓' : '✗'}\n`
  }
  return entry
}

btnStopSuite.addEventListener('click', () => {
  suiteStopFlag = true
  log('Stopping after current test…')
})

btnRunSuite.addEventListener('click', async () => {
  if (suiteRunning) return

  const dirPath = await window.api.openFolderDialog()
  if (!dirPath) return

  const files = await window.api.listTestCases(dirPath)
  if (!files.length) { log('No JSON files found in folder'); return }

  const maxIter = Math.max(0, parseInt(suiteIterInput.value, 10) || 0)

  suiteRunning  = true
  suiteStopFlag = false
  btnRunSuite.disabled = true
  btnRun.disabled      = true
  btnStopSuite.style.display = ''
  suitePanel.style.display   = ''
  suiteFileList.innerHTML    = ''

  // ── Log setup ──────────────────────────────────────────────────────────────
  let logPath    = null
  let logContent = ''
  try {
    logPath = await window.api.newSuiteLogPath()
    logContent  = `Suite Log\n`
    logContent += `Folder:     ${dirPath}\n`
    logContent += `Started:    ${fmtDateTime()}\n`
    logContent += `Iterations: ${maxIter}  (${maxIter === 0 ? 'loop forever' : `${maxIter} pass${maxIter !== 1 ? 'es' : ''}`})\n`
    await window.api.writeFile(logPath, logContent)
  } catch { logPath = null }

  const appendLog = async (text) => {
    if (!logPath) return
    logContent += text
    try { await window.api.writeFile(logPath, logContent) } catch {}
  }

  let totalRuns = 0
  let totalPass = 0
  let passNum   = 0

  const updateCount = () => {
    suitePassCnt.textContent = `${totalPass} passed / ${totalRuns} run`
  }

  outer: while (!suiteStopFlag && (maxIter === 0 || passNum < maxIter)) {
    passNum++
    await appendLog(`\n=== Pass ${passNum}${maxIter > 0 ? ' / ' + maxIter : ''} ===\n\n`)

    for (const filePath of files) {
      if (suiteStopFlag) break outer

      const filename = filePath.split('/').pop()
      let testCase
      try {
        const raw = await window.api.readFile(filePath)
        testCase  = JSON.parse(raw)
      } catch (e) {
        appendSuiteRow(filePath, 'fail', `Load error: ${e.message}`)
        await appendLog(`[${fmtTime()}] ERROR ${filename}\n           Load error: ${e.message}\n`)
        suiteStopFlag = true
        break outer
      }

      suiteStatusTx.textContent = maxIter > 0
        ? `Pass ${passNum} / ${maxIter} — ${testCase.name || filename}`
        : `Pass ${passNum} — ${testCase.name || filename}`
      const runningRow = appendSuiteRow(filePath, 'running', '')
      totalRuns++
      updateCount()

      let result
      try {
        result = await window.api.runTest(testCase)
      } catch (e) {
        runningRow.className = 'suite-row suite-row-fail'
        runningRow.querySelector('.suite-badge').textContent = 'FAIL'
        runningRow.querySelector('.suite-row-detail')?.remove()
        runningRow.insertAdjacentHTML('beforeend',
          `<span class="suite-row-detail">${escHtml(e.message)}</span>`)
        await appendLog(`[${fmtTime()}] FAIL  ${filename}\n           ${e.message}\n`)
        suiteStopFlag = true
        break outer
      }

      if (!result.success) {
        runningRow.className = 'suite-row suite-row-fail'
        runningRow.querySelector('.suite-badge').textContent = 'FAIL'
        runningRow.insertAdjacentHTML('beforeend',
          `<span class="suite-row-detail">${escHtml(result.error || 'Unknown error')}</span>`)
        await appendLog(`[${fmtTime()}] FAIL  ${filename}\n           ${result.error || 'Unknown error'}\n`)
        suiteStopFlag = true
        break outer
      }

      const failed = result.results.find(r => !r.pass)
      if (failed) {
        runningRow.className = 'suite-row suite-row-fail'
        runningRow.querySelector('.suite-badge').textContent = 'FAIL'
        runningRow.insertAdjacentHTML('beforeend',
          `<span class="suite-row-detail">"${escHtml(failed.label)}": expected "${escHtml(failed.expected)}" got "${escHtml(failed.got)}"</span>`)
        await appendLog(buildTestLogEntry(filename, result))
        suiteStopFlag = true
        break outer
      }

      runningRow.className = 'suite-row suite-row-pass'
      runningRow.querySelector('.suite-badge').textContent = 'PASS'
      totalPass++
      updateCount()
      await appendLog(buildTestLogEntry(filename, result))
    }

    if (!suiteStopFlag) {
      await appendLog(`\n— Pass ${passNum} complete —\n`)
      appendSuiteDivider(passNum, maxIter)
    }
  }

  suiteRunning = false
  btnStopSuite.style.display = 'none'
  btnRunSuite.disabled = false
  btnRun.disabled = !currentTestCase

  const reason = suiteStopFlag && totalRuns > 0 && !suiteFileList.querySelector('.suite-row-fail')
    ? 'Suite stopped by user'
    : suiteFileList.querySelector('.suite-row-fail')
      ? 'Suite failed — see above'
      : 'Suite complete'
  suiteStatusTx.textContent = reason

  await appendLog(`\n${reason}\nCompleted:  ${fmtDateTime()}\nSummary:    ${totalPass} passed / ${totalRuns - totalPass} failed / ${totalRuns} run\n`)

  const logName = logPath ? logPath.split('/').pop() : null
  log(`${reason} — ${totalPass} passed / ${totalRuns} run${logName ? ` — log: ${logName}` : ''}`)
})

// ─── Editor saved callback ────────────────────────────────────────────────────
window.api.onEditorSaved((tc) => {
  loadTestCase(tc, currentFilePath)
  log(`Test case updated: ${tc.name || 'Untitled'}`)
})

// ─── Startup Pi check ─────────────────────────────────────────────────────────
;(function startupPiCheck() {
  const savedIp   = localStorage.getItem('pi_ip')
  const savedPort = parseInt(localStorage.getItem('pi_port') || '8080', 10)
  if (!savedIp) return
  log(`Checking Pi at ${savedIp}…`)
  window.api.checkPiStatus(savedIp, savedPort)
    .then(status => {
      setPiStatus(status)
      log(status.ok ? `Pi connected (${savedIp})` : `Pi unreachable: ${status.error}`)
    })
    .catch(() => {})
})()
