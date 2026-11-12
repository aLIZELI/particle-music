/* =========================================================
 * 音频引擎
 *  - 三个音源：麦克风 / 本地音频文件 / 内置程序化演奏
 *  - 所有声音都旁路到 AnalyserNode，向上层输出频率与波形数据
 *  - 不依赖 p5.sound，只用原生 Web Audio API
 * ========================================================= */
(function (global) {
  'use strict';

  const BARS = 96;          // 频谱柱数量
  const WAVE_POINTS = 256;  // 波形采样点
  const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
  const TAU = Math.PI * 2;

  /* ---------------------------------------------------------
   * 内置演奏：一段 96 BPM 的 A 小调五声音阶循环
   * 目的不是好听，而是让你一打开就有东西能对着看
   * --------------------------------------------------------- */
  class DemoSynth {
    constructor(engine) {
      this.engine = engine;
      this.ctx = engine.ctx;
      this.step = 0;
      this.nextTime = 0;
      this.timer = null;
      this.arpIndex = 0;

      this.bpm = 96;
      this.stepDur = 60 / this.bpm / 4; // 十六分音符时长

      this.out = this.ctx.createGain();
      this.out.gain.value = 0.7;
      this.out.connect(engine.master);

      // 一条简单的延迟，给拨弦一点空间感
      this.delay = this.ctx.createDelay(1);
      this.delay.delayTime.value = this.stepDur * 3;
      this.feedback = this.ctx.createGain();
      this.feedback.gain.value = 0.28;
      this.wet = this.ctx.createGain();
      this.wet.gain.value = 0.2;
      this.delay.connect(this.feedback);
      this.feedback.connect(this.delay);
      this.delay.connect(this.wet);
      this.wet.connect(this.out);

      this.noiseBuf = this.makeNoise();
      this.arpNotes = [440.0, 523.25, 587.33, 659.25, 783.99]; // A4 C5 D5 E5 G5
      this.bassNotes = [
        [0, 55.0],  // A1
        [6, 65.41], // C2
        [10, 82.41],// E2
        [16, 55.0],
        [22, 49.0], // G1
        [26, 65.41],
      ];
    }

    makeNoise() {
      const len = Math.floor(this.ctx.sampleRate);
      const buf = this.ctx.createBuffer(1, len, this.ctx.sampleRate);
      const data = buf.getChannelData(0);
      for (let i = 0; i < len; i++) data[i] = Math.random() * 2 - 1;
      return buf;
    }

    start() {
      this.nextTime = this.ctx.currentTime + 0.08;
      this.timer = setInterval(() => this.schedule(), 25);
    }

    stop() {
      if (this.timer) clearInterval(this.timer);
      this.timer = null;
      try { this.out.disconnect(); } catch (e) { /* 已断开 */ }
      try { this.delay.disconnect(); this.feedback.disconnect(); this.wet.disconnect(); } catch (e) { /* 已断开 */ }
    }

    schedule() {
      const horizon = this.ctx.currentTime + 0.16;
      while (this.nextTime < horizon) {
        this.playStep(this.step, this.nextTime);
        this.nextTime += this.stepDur;
        this.step = (this.step + 1) % 32;
      }
    }

    playStep(step, t) {
      // 四拍底鼓
      if (step === 0 || step === 8 || step === 16 || step === 22 || step === 24) {
        this.kick(t);
      }
      // 反拍镲片
      if (step % 2 === 0) this.hat(t, step % 4 === 2);
      // 2、4 拍军鼓
      if (step === 4 || step === 12 || step === 20 || step === 28) this.snare(t);
      // 贝斯
      for (let i = 0; i < this.bassNotes.length; i++) {
        if (this.bassNotes[i][0] === step) {
          this.bass(t, this.bassNotes[i][1], this.stepDur * 3.2);
        }
      }
      // 铺底和弦：A 小调 / G 大调交替
      if (step === 0) this.pad(t, [220.0, 261.63, 329.63]);
      if (step === 16) this.pad(t, [196.0, 246.94, 293.66]);

      // 拨弦琶音
      if ([0, 3, 6, 10, 12, 14, 18, 21, 24, 26, 30].indexOf(step) >= 0) {
        const note = this.arpNotes[this.arpIndex % this.arpNotes.length];
        this.arpIndex++;
        this.pluck(t, note);
      }
    }

    kick(t) {
      const osc = this.ctx.createOscillator();
      const gain = this.ctx.createGain();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(155, t);
      osc.frequency.exponentialRampToValueAtTime(45, t + 0.11);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.6, t + 0.005);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.34);
      osc.connect(gain);
      gain.connect(this.out);
      osc.start(t);
      osc.stop(t + 0.36);
    }

    hat(t, accent) {
      const src = this.ctx.createBufferSource();
      const hp = this.ctx.createBiquadFilter();
      const gain = this.ctx.createGain();
      src.buffer = this.noiseBuf;
      hp.type = 'highpass';
      hp.frequency.value = 7200;
      gain.gain.setValueAtTime(accent ? 0.1 : 0.05, t);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.05);
      src.connect(hp);
      hp.connect(gain);
      gain.connect(this.out);
      src.start(t, Math.random() * 0.4, 0.06);
    }

    snare(t) {
      const src = this.ctx.createBufferSource();
      const bp = this.ctx.createBiquadFilter();
      const gain = this.ctx.createGain();
      src.buffer = this.noiseBuf;
      bp.type = 'bandpass';
      bp.frequency.value = 1900;
      bp.Q.value = 0.9;
      gain.gain.setValueAtTime(0.18, t);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.16);
      src.connect(bp);
      bp.connect(gain);
      gain.connect(this.out);
      src.start(t, Math.random() * 0.4, 0.18);
    }

    bass(t, freq, dur) {
      const osc = this.ctx.createOscillator();
      const lp = this.ctx.createBiquadFilter();
      const gain = this.ctx.createGain();
      osc.type = 'triangle';
      osc.frequency.setValueAtTime(freq, t);
      lp.type = 'lowpass';
      lp.frequency.setValueAtTime(420, t);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.32, t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      osc.connect(lp);
      lp.connect(gain);
      gain.connect(this.out);
      osc.start(t);
      osc.stop(t + dur + 0.02);
    }

    pluck(t, freq) {
      const osc = this.ctx.createOscillator();
      const gain = this.ctx.createGain();
      osc.type = 'triangle';
      osc.frequency.setValueAtTime(freq, t);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.12, t + 0.008);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.42);
      osc.connect(gain);
      gain.connect(this.out);
      gain.connect(this.delay);
      osc.start(t);
      osc.stop(t + 0.45);
    }
    pad(t, notes) {
      const lp = this.ctx.createBiquadFilter();
      const gain = this.ctx.createGain();
      lp.type = 'lowpass';
      lp.frequency.setValueAtTime(620, t);
      lp.frequency.linearRampToValueAtTime(1300, t + 1.2);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.linearRampToValueAtTime(0.06, t + 0.7);
      gain.gain.setValueAtTime(0.06, t + 1.8);
      gain.gain.linearRampToValueAtTime(0.0001, t + 2.55);
      lp.connect(gain);
      gain.connect(this.out);

      for (let i = 0; i < notes.length; i++) {
        const osc = this.ctx.createOscillator();
        osc.type = 'triangle';
        osc.frequency.value = notes[i];
        osc.detune.value = (Math.random() - 0.5) * 8;
        osc.connect(lp);
        osc.start(t);
        osc.stop(t + 2.6);
      }
    }
  }

  /* ---------------------------------------------------------
   * AudioEngine
   * --------------------------------------------------------- */
  class AudioEngine {
    constructor() {
      this.ctx = null;
      this.analyser = null;
      this.master = null;   // 可听输出
      this.mute = null;     // 分析器的静音出口，保证节点被浏览器持续处理
      this.freq = null;
      this.time = null;
      this.bars = new Float32Array(BARS);
      this.wave = new Float32Array(WAVE_POINTS);
      this.barRanges = null;
      this.mode = 'idle';   // idle | demo | file | mic
      this.trackName = '';
      this.duration = 0;
      this.bufferSource = null;
      this.micSource = null;
      this.stream = null;
      this.demo = null;
      this.fake = false;
      this._t0 = performance.now();
    }

    /* 懒创建 AudioContext（必须在用户手势里调用） */
    async ensure() {
      if (this.ctx) {
        if (this.ctx.state === 'suspended') await this.ctx.resume();
        return this.ctx;
      }
      const Ctx = global.AudioContext || global.webkitAudioContext;
      if (!Ctx) throw new Error('这个浏览器不支持 Web Audio API，换 Chrome / Safari 试试');

      this.ctx = new Ctx();
      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 2048;
      this.analyser.smoothingTimeConstant = 0.78;
      this.analyser.minDecibels = -90;
      this.analyser.maxDecibels = -12;

      this.master = this.ctx.createGain();
      this.master.gain.value = 0.9;

      // 静音监听：analyser -> gain(0) -> destination
      this.mute = this.ctx.createGain();
      this.mute.gain.value = 0;

      this.master.connect(this.ctx.destination);
      this.master.connect(this.analyser);
      this.analyser.connect(this.mute);
      this.mute.connect(this.ctx.destination);

      this.freq = new Uint8Array(this.analyser.frequencyBinCount);
      this.time = new Float32Array(this.analyser.fftSize);
      this.computeBarRanges();

      if (this.ctx.state === 'suspended') await this.ctx.resume();
      return this.ctx;
    }

    computeBarRanges() {
      const nyquist = this.ctx.sampleRate / 2;
      const binCount = this.analyser.frequencyBinCount;
      const fmin = 36;
      const fmax = Math.min(17000, nyquist * 0.96);
      this.barRanges = [];
      for (let i = 0; i < BARS; i++) {
        const f0 = fmin * Math.pow(fmax / fmin, i / BARS);
        const f1 = fmin * Math.pow(fmax / fmin, (i + 1) / BARS);
        const a = Math.min(binCount - 1, Math.max(0, Math.floor((f0 / nyquist) * binCount)));
        const b = Math.min(binCount - 1, Math.max(a + 1, Math.ceil((f1 / nyquist) * binCount)));
        this.barRanges.push([a, b]);
      }
    }

    /* ---------- 音源 ---------- */

    async loadFile(file) {
      if (!file) throw new Error('没有选择文件');
      const looksAudio = /^audio\//.test(file.type) || /\.(mp3|wav|ogg|m4a|aac|flac|opus)$/i.test(file.name);
      if (!looksAudio) throw new Error('这看起来不是音频文件：' + file.name);

      await this.ensure();
      this.stopSources();

      const buffer = await file.arrayBuffer();
      let decoded;
      try {
        decoded = await this.ctx.decodeAudioData(buffer);
      } catch (err) {
        throw new Error('这个音频解码失败，试试 mp3 / wav / m4a');
      }

      const src = this.ctx.createBufferSource();
      src.buffer = decoded;
      src.loop = true;
      src.connect(this.master);
      src.start(0);
      if (this.ctx.state === 'suspended') await this.ctx.resume();

      this.bufferSource = src;
      this.mode = 'file';
      this.fake = false;
      this.trackName = file.name;
      this.duration = decoded.duration;
      return { name: file.name, duration: decoded.duration };
    }

    async startMic() {
      await this.ensure();
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error('这个浏览器不允许访问麦克风，需要 https 或 localhost 环境');
      }
      this.stopSources();

      let stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
          video: false,
        });
      } catch (err) {
        const name = err && err.name;
        if (name === 'NotAllowedError' || name === 'SecurityError') {
          throw new Error('麦克风被拒绝了。允许权限后重试；用 file:// 直接打开时可能受限，建议用本地服务器（见 README）。');
        }
        if (name === 'NotFoundError' || name === 'DevicesNotFoundError') {
          throw new Error('没有找到可用的麦克风设备。');
        }
        throw new Error('麦克风打开失败：' + (err && err.message ? err.message : err));
      }

      const src = this.ctx.createMediaStreamSource(stream);
      src.connect(this.analyser); // 只进分析器，不进扬声器，避免啸叫
      this.stream = stream;
      this.micSource = src;
      this.mode = 'mic';
      this.fake = false;
      this.trackName = '麦克风';
      return { name: this.trackName };
    }

    async startDemo() {
      await this.ensure();
      this.stopSources();
      this.demo = new DemoSynth(this);
      this.demo.start();
      this.mode = 'demo';
      this.fake = false;
      this.trackName = '内置演奏';
      return { name: this.trackName };
    }

    /* ---------- 生命周期 ---------- */

    stopSources() {
      if (this.bufferSource) {
        try { this.bufferSource.stop(); } catch (e) { /* 已经停了 */ }
        try { this.bufferSource.disconnect(); } catch (e) { /* 已经断开 */ }
        this.bufferSource = null;
      }
      if (this.micSource) {
        try { this.micSource.disconnect(); } catch (e) { /* 已经断开 */ }
        this.micSource = null;
      }
      if (this.stream) {
        this.stream.getTracks().forEach((t) => t.stop());
        this.stream = null;
      }
      if (this.demo) {
        this.demo.stop();
        this.demo = null;
      }
    }

    stop() {
      this.stopSources();
      this.mode = 'idle';
      this.trackName = '';
      this.duration = 0;
    }

    async togglePause() {
      if (!this.ctx) return true;
      if (this.ctx.state === 'running') {
        await this.ctx.suspend();
        return true;
      }
      await this.ctx.resume();
      return false;
    }

    get paused() {
      return !this.ctx || this.ctx.state === 'suspended';
    }

    get running() {
      return this.mode !== 'idle';
    }

    /* ---------- 分析数据 ---------- */

    band(f0, f1) {
      const nyquist = this.ctx.sampleRate / 2;
      const binCount = this.analyser.frequencyBinCount;
      let a = Math.floor((f0 / nyquist) * binCount);
      let b = Math.ceil((f1 / nyquist) * binCount);
      a = Math.max(0, Math.min(binCount - 1, a));
      b = Math.max(a + 1, Math.min(binCount, b));
      let sum = 0;
      for (let i = a; i < b; i++) sum += this.freq[i] / 255;
      return sum / (b - a);
    }

    read() {
      if (this.fake) return this.synthetic();
      if (!this.analyser || this.mode === 'idle') return this.silent();

      this.analyser.getByteFrequencyData(this.freq);
      this.analyser.getFloatTimeDomainData(this.time);

      let sumSq = 0;
      for (let i = 0; i < this.time.length; i++) {
        const v = this.time[i];
        sumSq += v * v;
      }
      const rms = Math.sqrt(sumSq / this.time.length);
      const level = clamp01(rms * 4.0);

      const step = this.time.length / WAVE_POINTS;
      for (let i = 0; i < WAVE_POINTS; i++) {
        this.wave[i] = this.time[Math.floor(i * step)] * 3.2;
      }

      for (let i = 0; i < BARS; i++) {
        const range = this.barRanges[i];
        let v = 0;
        for (let k = range[0]; k < range[1]; k++) {
          if (this.freq[k] > v) v = this.freq[k];
        }
        this.bars[i] = clamp01((v / 255) * (1.1 + (i / BARS) * 0.85));
      }

      return {
        level,
        bass: clamp01(this.band(30, 180) * 1.25),
        mid: clamp01(this.band(180, 1600) * 1.9),
        treble: clamp01(this.band(1600, 12000) * 3.0),
        spectrum: this.bars,
        wave: this.wave,
      };
    }

    silent() {
      this.bars.fill(0);
      this.wave.fill(0);
      return { level: 0, bass: 0, mid: 0, treble: 0, spectrum: this.bars, wave: this.wave };
    }

    /* 调试 / 截图用的假数据：无需声音也能看到完整效果 */
    synthetic() {
      const t = (performance.now() - this._t0) / 1000;
      const phase = (t * 1.75) % 1;
      const kick = Math.exp(-phase * 9);
      const level = clamp01(0.2 + kick * 0.45 + 0.05 * Math.sin(t * 1.3));

      for (let i = 0; i < BARS; i++) {
        const x = i / BARS;
        const v =
          0.16 +
          kick * Math.exp(-x * 4.0) * 0.85 +
          0.3 * Math.exp(-Math.pow((x - 0.22) * 9, 2)) * (0.6 + 0.4 * Math.sin(t * 2.1)) +
          0.22 * Math.exp(-Math.pow((x - 0.55) * 11, 2)) * (0.6 + 0.4 * Math.sin(t * 3.3 + 1)) +
          Math.random() * 0.06;
        this.bars[i] = clamp01(v);
      }
      for (let i = 0; i < WAVE_POINTS; i++) {
        const p = (i / WAVE_POINTS) * TAU;
        this.wave[i] = Math.sin(p * 3 + t * 4) * 0.55 + Math.sin(p * 7 - t * 2.4) * 0.25;
      }
      return {
        level,
        bass: clamp01(kick * 0.9 + 0.06),
        mid: clamp01(0.3 + 0.12 * Math.sin(t * 1.7)),
        treble: clamp01(0.22 + 0.14 * Math.sin(t * 2.9 + 2)),
        spectrum: this.bars,
        wave: this.wave,
      };
    }
  }

  AudioEngine.BARS = BARS;
  AudioEngine.DemoSynth = DemoSynth;
  AudioEngine.WAVE_POINTS = WAVE_POINTS;
  global.AudioEngine = AudioEngine;
})(window);
