/* =========================================================
 * 粒子音乐 · 主程序
 *  p5.js 负责画布与绘制，AudioEngine 提供频谱/波形，
 *  这里把两者接起来：节拍检测 → 冲击波，频谱 → 圆环，
 *  振幅 → 粒子亮度，波形 → 内圈曲线。
 * ========================================================= */
/* global p5, AudioEngine, ParticleField */

const CFG = {
  trail: 0.26,
  bars: AudioEngine.BARS,
};

const PALETTES = [
  { name: '极光', hueA: 165, hueB: 278, bg: { h: 232, s: 55, b: 5 } },
  { name: '熔岩', hueA: 4, hueB: 56, bg: { h: 12, s: 48, b: 4 } },
  { name: '霓虹', hueA: 318, hueB: 196, bg: { h: 252, s: 52, b: 4 } },
  { name: '深海', hueA: 188, hueB: 238, bg: { h: 222, s: 60, b: 4 } },
];

const TAU = Math.PI * 2;
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const wrapHue = (h) => ((h % 360) + 360) % 360;

const state = {
  engine: null,
  field: null,
  paletteIndex: 0,
  t: 0,
  beat: 0,
  hueShift: 0,
  started: false,
  paused: false,
  uiHidden: false,
  mouse: { x: 0, y: 0, active: false },
  slowStreak: 0,
  frames: 0,
};

const ui = {};
let toastTimer = 0;

const detector = {
  avg: 0.02,
  lastBeat: 0,
  update(bass, now) {
    this.avg = this.avg * 0.965 + bass * 0.035;
    const threshold = Math.max(0.15, this.avg * 1.32);
    if (bass > threshold && now - this.lastBeat > 150) {
      this.lastBeat = now;
      return clamp((bass - this.avg) * 2.2 + 0.25, 0.25, 1);
    }
    return 0;
  },
};

const palette = () => PALETTES[state.paletteIndex];

/* ---------------------------------------------------------
 * p5 生命周期
 * --------------------------------------------------------- */

function setup() {
  const cnv = createCanvas(windowWidth, windowHeight);
  cnv.parent('stage');
  pixelDensity(Math.min(2, window.devicePixelRatio || 1));
  colorMode(HSB, 360, 100, 100, 1);
  strokeCap(ROUND);
  noStroke();

  state.engine = new AudioEngine();
  state.field = new ParticleField();
  state.field.layout(width, height, false);

  initUI();
  handleQuery();
}

function draw() {
  const dt = Math.min(2.5, Math.max(0.2, deltaTime / 16.667));
  state.t += dt / 60;
  state.frames++;

  const a = state.engine.read();
  const pal = palette();

  // 空闲时给一点环境亮度，让启动页后面的粒子也是活的
  const ambient = state.engine.running ? 0 : 0.18 + 0.06 * Math.sin(state.t * 0.9);
  const visLevel = clamp(a.level + ambient, 0, 1);

  // 节拍检测 → 冲击波
  const hit = detector.update(a.bass, millis());
  if (hit > 0) {
    state.beat = Math.max(state.beat, hit);
    state.field.kick(hit, wrapHue(pal.hueA + 30 + state.hueShift));
    state.hueShift += (Math.random() - 0.5) * 5;
  }
  state.beat *= Math.pow(0.9, dt);
  state.hueShift = lerp(state.hueShift, a.treble * 24 - 5, 0.04);

  // 1. 半透明底色，留下拖尾
  blendMode(BLEND);
  noStroke();
  fill(pal.bg.h, pal.bg.s, pal.bg.b, CFG.trail);
  rect(0, 0, width, height);

  // 2. 中心辉光（用原生渐变，p5 的 HSB 不影响它）
  drawGlow(a, pal);

  // 3. 加色混合层
  blendMode(ADD);

  drawGuides(pal);
  drawSpectrum(a, pal);

  state.field.update({
    dt,
    bass: a.bass,
    mid: a.mid,
    treble: a.treble,
    level: visLevel,
    beat: state.beat,
    mouse: state.mouse,
    t: state.t,
    hueBase: pal.hueA + state.hueShift,
    hueSpan: pal.hueB - pal.hueA,
    spectrum: a.spectrum,
    bars: CFG.bars,
    barOffset: state.t * 0.05,
  });

  state.field.drawRings();
  state.field.drawParticles();
  state.field.drawSparks();

  drawCore(a, pal);
  drawWaveRing(a, pal);

  blendMode(BLEND);

  // 自适应降载：连续掉帧就少放一点粒子
  if (state.started && state.frames % 60 === 0) {
    if (frameRate() < 42) {
      state.slowStreak++;
    } else {
      state.slowStreak = Math.max(0, state.slowStreak - 1);
    }
    const f = state.field;
    if (state.slowStreak >= 3 && f.particles.length > f.minCount) {
      f.setCount(Math.round(f.particles.length * 0.82));
      state.slowStreak = 0;
    }
  }
}

/* ---------------------------------------------------------
 * 绘制细节
 * --------------------------------------------------------- */

function drawGlow(a, pal) {
  const { cx, cy, r0 } = state.field;
  const radius = r0 * (2.2 + a.bass * 0.8);
  const hue = wrapHue(pal.hueA + state.hueShift);
  const ctx = drawingContext;

  const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
  g.addColorStop(0, `hsla(${hue.toFixed(0)}, 90%, 58%, ${(0.045 + a.level * 0.1 + state.beat * 0.07).toFixed(3)})`);
  g.addColorStop(0.35, `hsla(${wrapHue(hue + 26).toFixed(0)}, 85%, 48%, ${(0.02 + a.level * 0.04).toFixed(3)})`);
  g.addColorStop(1, 'hsla(0, 0%, 0%, 0)');

  ctx.save();
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, width, height);
  ctx.restore();
}

function drawGuides(pal) {
  const { cx, cy, r0 } = state.field;
  noFill();
  strokeWeight(1);
  stroke(wrapHue(pal.hueA + 10), 32, 72, 0.07);
  ellipse(cx, cy, r0 * 2, r0 * 2);
  stroke(wrapHue(pal.hueB - 20), 32, 72, 0.04);
  ellipse(cx, cy, r0 * 2.4, r0 * 2.4);
  noStroke();
}

function drawSpectrum(a, pal) {
  const { cx, cy, r0 } = state.field;
  const n = CFG.bars;
  const inner = r0 * 1.16;
  const maxLen = r0 * 0.62;
  const offset = state.t * 0.05;

  // 两遍绘制：先用粗线打光晕，再用细线画亮芯
  for (let i = 0; i < n; i++) {
    const v = a.spectrum[i] || 0;
    const ang = Math.PI / 2 + (i / n) * TAU + offset;
    const len = (2 + v * maxLen) * (1 + state.beat * 0.15);
    const cos = Math.cos(ang);
    const sin = Math.sin(ang);
    const hue = wrapHue(pal.hueA + (i / n) * (pal.hueB - pal.hueA));
    const x1 = cx + cos * inner;
    const y1 = cy + sin * inner;
    const x2 = cx + cos * (inner + len);
    const y2 = cy + sin * (inner + len);

    stroke(hue, 88, 62, 0.03 + v * 0.1);
    strokeWeight(6);
    line(x1, y1, x2, y2);

    stroke(hue, 70, 82, 0.18 + v * 0.62);
    strokeWeight(2);
    line(x1, y1, x2, y2);
  }
  noStroke();
}

function drawCore(a, pal) {
  const { cx, cy, r0 } = state.field;
  const r = r0 * (0.12 + a.bass * 0.16 + state.beat * 0.05);
  const hue = wrapHue(pal.hueA + 24 + state.hueShift);

  noStroke();
  fill(hue, 55, 100, 0.03 + a.level * 0.04);
  ellipse(cx, cy, r * 3.4, r * 3.4);
  fill(hue, 40, 100, 0.05 + a.level * 0.07);
  ellipse(cx, cy, r * 1.8, r * 1.8);
  fill(hue, 16, 100, 0.34 + a.level * 0.26);
  ellipse(cx, cy, r * 0.85, r * 0.85);
}

function drawWaveRing(a, pal) {
  const { cx, cy, r0 } = state.field;
  const n = a.wave.length;
  const baseR = r0 * 0.56;
  const amp = r0 * 0.045 * (0.35 + a.level * 1.8);

  noFill();

  stroke(wrapHue(pal.hueA + 30), 40, 85, 0.08 + a.level * 0.06);
  strokeWeight(1);
  ellipse(cx, cy, baseR * 2, baseR * 2);

  stroke(wrapHue(pal.hueA + 54 + state.hueShift), 60, 90, 0.24 + a.level * 0.3);
  strokeWeight(1.3);
  beginShape();
  for (let i = 0; i < n; i++) {
    const ang = (i / n) * TAU - Math.PI / 2;
    const r = baseR + a.wave[i] * amp;
    vertex(cx + Math.cos(ang) * r, cy + Math.sin(ang) * r);
  }
  endShape(CLOSE);
  noStroke();
}

/* ---------------------------------------------------------
 * 交互
 * --------------------------------------------------------- */

function mouseMoved() {
  state.mouse.x = mouseX;
  state.mouse.y = mouseY;
  state.mouse.active = true;
}

function mouseDragged() {
  mouseMoved();
}

function mousePressed() {
  if (!state.started) return true;
  const pal = palette();
  state.field.burst(mouseX, mouseY, 26, wrapHue(pal.base + 40 + state.hueShift));
  return false;
}

function touchStarted() {
  if (!state.started) return true;
  const pal = palette();
  state.field.burst(mouseX, mouseY, 22, wrapHue(pal.base + 40 + state.hueShift));
  return false;
}

function keyPressed() {
  if (!state.started) return true;

  if (key === ' ') {
    togglePause();
    return false;
  }
  if (key >= '1' && key <= '4') {
    setPalette(Number(key) - 1);
    return false;
  }
  const k = key.toLowerCase();
  if (k === 's') {
    snapshot();
    return false;
  }
  if (k === 'f') {
    toggleFullscreen();
    return false;
  }
  if (k === 'h') {
    toggleUI();
    return false;
  }
  return true;
}

function windowResized() {
  resizeCanvas(windowWidth, windowHeight);
  state.field.layout(width, height, true);
}

/* ---------------------------------------------------------
 * UI 绑定
 * --------------------------------------------------------- */

function initUI() {
  ui.overlay = document.getElementById('overlay');
  ui.toolbar = document.getElementById('toolbar');
  ui.keys = document.getElementById('keys');
  ui.error = document.getElementById('error');
  ui.trackName = document.getElementById('track-name');
  ui.toast = document.getElementById('toast');
  ui.btnDemo = document.getElementById('btn-demo');
  ui.btnFile = document.getElementById('btn-file');
  ui.btnMic = document.getElementById('btn-mic');
  ui.fileInput = document.getElementById('file-input');
  ui.btnPause = ui.toolbar.querySelector('[data-act="pause"]');

  ui.btnDemo.addEventListener('click', () => {
    runButton(ui.btnDemo, '正在唤醒声音…', useDemo);
  });

  ui.btnFile.addEventListener('click', () => ui.fileInput.click());

  ui.fileInput.addEventListener('change', () => {
    const file = ui.fileInput.files && ui.fileInput.files[0];
    if (file) openFile(file);
    ui.fileInput.value = '';
  });

  ui.btnMic.addEventListener('click', () => {
    runButton(ui.btnMic, '等待麦克风授权…', useMic);
  });

  ui.toolbar.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-act]');
    if (btn) handleAction(btn.dataset.act);
  });

  // 拖拽换歌
  window.addEventListener('dragover', (e) => {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
  });
  window.addEventListener('dragenter', (e) => {
    e.preventDefault();
    ui.overlay.classList.add('is-dragging');
  });
  window.addEventListener('dragleave', (e) => {
    if (e.relatedTarget === null) ui.overlay.classList.remove('is-dragging');
  });
  window.addEventListener('drop', (e) => {
    e.preventDefault();
    ui.overlay.classList.remove('is-dragging');
    const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
    if (file) openFile(file);
  });

  document.addEventListener('fullscreenchange', updateFullscreenIcon);
}

async function runButton(btn, label, task) {
  const html = btn.innerHTML;
  btn.disabled = true;
  btn.textContent = label;
  try {
    await task();
  } catch (err) {
    showError(err && err.message ? err.message : String(err));
  } finally {
    btn.disabled = false;
    btn.innerHTML = html;
  }
}

async function useDemo() {
  const info = await state.engine.startDemo();
  enterStage(info.name);
  toast('内置演奏：低音鼓点会推开粒子');
}

async function useMic() {
  const info = await state.engine.startMic();
  enterStage(info.name);
  toast('对着麦克风说话、放歌，粒子会跟着动');
}

async function openFile(file) {
  try {
    const info = await state.engine.loadFile(file);
    enterStage(info.name);
    toast('正在播放：' + info.name);
  } catch (err) {
    showError(err && err.message ? err.message : String(err));
  }
}

function enterStage(name) {
  ui.overlay.classList.add('is-hidden');
  ui.toolbar.hidden = false;
  ui.keys.hidden = false;
  ui.error.hidden = true;
  ui.trackName.textContent = name;
  state.started = true;
  state.paused = false;
  setPauseIcon(false);
}

function showOverlay() {
  ui.overlay.classList.remove('is-hidden');
  ui.toolbar.hidden = true;
  ui.keys.hidden = true;
  ui.error.hidden = true;
  state.started = false;
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
}

function handleAction(act) {
  if (act === 'pause') togglePause();
  else if (act === 'palette') setPalette(state.paletteIndex + 1);
  else if (act === 'snapshot') snapshot();
  else if (act === 'fullscreen') toggleFullscreen();
  else if (act === 'change') {
    state.engine.stop();
    state.beat = 0;
    showOverlay();
    toast('换一个音源');
  }
}

async function togglePause() {
  if (!state.engine.running) return;
  const paused = await state.engine.togglePause();
  state.paused = paused;
  setPauseIcon(paused);
  toast(paused ? '已暂停（空格继续）' : '继续');
}

function setPauseIcon(paused) {
  if (ui.btnPause) ui.btnPause.textContent = paused ? '▶' : '❚❚';
}

function setPalette(index) {
  state.paletteIndex = ((index % PALETTES.length) + PALETTES.length) % PALETTES.length;
  toast('配色：' + palette().name);
}

function snapshot() {
  const canvasEl = document.querySelector('#stage canvas');
  if (!canvasEl) return;
  canvasEl.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = '粒子音乐-' + Date.now() + '.png';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    toast('画面已保存');
  }, 'image/png');
}

function toggleFullscreen() {
  if (document.fullscreenElement) {
    document.exitFullscreen();
  } else if (document.documentElement.requestFullscreen) {
    document.documentElement.requestFullscreen();
  }
}

function updateFullscreenIcon() {
  const btn = ui.toolbar.querySelector('[data-act="fullscreen"]');
  if (btn) btn.textContent = document.fullscreenElement ? '⤢' : '⛶';
}

function toggleUI() {
  state.uiHidden = !state.uiHidden;
  ui.toolbar.classList.toggle('ui-hidden', state.uiHidden);
  ui.keys.classList.toggle('ui-hidden', state.uiHidden);
}

function showError(msg) {
  if (ui.overlay.classList.contains('is-hidden')) {
    toast(msg, 5200);
  } else {
    ui.error.textContent = msg;
    ui.error.hidden = false;
  }
}

function toast(msg, ms) {
  if (!ui.toast) return;
  ui.toast.textContent = msg;
  ui.toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ui.toast.classList.remove('show'), ms || 2400);
}

/* ---------------------------------------------------------
 * 启动参数：?demo=1 自动演奏，?fake=1 用假信号（截图/调试）
 * --------------------------------------------------------- */

function handleQuery() {
  const params = new URLSearchParams(location.search);
  if (params.get('fake') === '1') {
    state.engine.fake = true;
    enterStage('调试信号');
    return;
  }
  if (params.get('demo') === '1') {
    state.engine.startDemo()
      .then((info) => enterStage(info.name))
      .catch((err) => showError(err && err.message ? err.message : String(err)));
  }
}

/* 调试入口，方便在控制台里玩 */
window.__pm = {
  state,
  engine: () => state.engine,
  startDemo: useDemo,
  setFake: (v) => { state.engine.fake = !!v; },
  setPalette,
};
