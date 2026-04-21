'use strict'

const CAPTURE_W = 1920
const CAPTURE_H = 1080

const canvas = document.getElementById('display-canvas')
const ctx    = canvas.getContext('2d')
const warn   = document.getElementById('warn')

function renderScene(testCase) {
  const sc = testCase.scene || {}
  const w  = sc.width  || CAPTURE_W
  const h  = sc.height || CAPTURE_H

  canvas.width  = w
  canvas.height = h

  const scaleX = w / CAPTURE_W
  const scaleY = h / CAPTURE_H

  ctx.fillStyle = sc.background || '#000000'
  ctx.fillRect(0, 0, w, h)

  for (const r of (testCase.regions || [])) {
    const rx = r.x * scaleX
    const ry = r.y * scaleY
    const rw = r.w * scaleX
    const rh = r.h * scaleY

    ctx.fillStyle = r.bg_color || '#ffffff'
    ctx.fillRect(rx, ry, rw, rh)

    const fs = (r.font_size || 48) * Math.min(scaleX, scaleY)
    ctx.font         = `${fs}px ${r.font_family || 'monospace'}`
    ctx.textAlign    = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillStyle    = r.text_color || '#000000'
    ctx.fillText(r.text || '', rx + rw / 2, ry + rh / 2)
  }

  const dpr = window.devicePixelRatio || 1
  const sw = Math.round(window.screen.width  * dpr)
  const sh = Math.round(window.screen.height * dpr)
  if (sw !== w || sh !== h) {
    warn.textContent = `Warning: screen ${sw}×${sh} ≠ scene ${w}×${h} — crop coords may be offset`
    warn.style.display = 'block'
  }
}

document.addEventListener('DOMContentLoaded', async () => {
  const testCase = await window.api.getSceneData()
  if (testCase) renderScene(testCase)
  window.api.signalReady()
})

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') window.api.closeDisplay()
})
