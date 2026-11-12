/* =========================================================
 * 粒子系统
 *  Particle   —— 围绕环形轨道漂浮的光点，亮度跟着对应频谱柱走
 *  Spark      —— 节拍/点击时迸出的短命火花
 *  Ring       —— 向外扩散的冲击波圆环
 * ========================================================= */
(function (global) {
  'use strict';

  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);

  class Particle {
    constructor(field) {
      this.field = field;
      this.reset();
    }

    reset() {
      const f = this.field;
      const ang = Math.random() * TAU;
      const rad = f.r0 * (0.6 + Math.pow(Math.random(), 0.8) * 0.6);
      this.x = f.cx + Math.cos(ang) * rad;
      this.y = f.cy + Math.sin(ang) * rad;
      this.vx = (Math.random() - 0.5) * 0.4;
      this.vy = (Math.random() - 0.5) * 0.4;
      this.orbit = 0.6 + Math.pow(Math.random(), 0.8) * 0.6; // 目标轨道（相对 r0）
      this.size = 1.3 + Math.random() * 2.1;
      this.spin = Math.random() < 0.5 ? -1 : 1;
      this.hueF = Math.random();
      this.seed = Math.random() * 100;
      this.glow = 0;
      this.band = 0;
      this.hue = 200;
      this.dist = rad;
    }

    update(p) {
      const dx = this.x - p.cx;
      const dy = this.y - p.cy;
      this.dist = Math.hypot(dx, dy) || 0.001;
      const nx = dx / this.dist;
      const ny = dy / this.dist;

      // 1. 轨道弹簧：拉回自己的轨道，低音让整圈向外膨胀
      const target = p.r0 * this.orbit * (1 + p.bass * 0.12);
      const pull = (target - this.dist) * 0.012;
      this.vx += nx * pull * p.dt;
      this.vy += ny * pull * p.dt;

      // 2. 切向旋转，中频越强转得越快
      const swirl = (0.1 + p.mid * 0.34) * this.spin;
      this.vx += -ny * swirl * p.dt;
      this.vy += nx * swirl * p.dt;

      // 3. 噪声流场：让圆环不规则地呼吸
      const na = noise(this.seed * 0.05, p.t * 0.2) * TAU * 2;
      this.vx += Math.cos(na) * 0.07 * p.dt;
      this.vy += Math.sin(na) * 0.07 * p.dt;

      // 4. 节拍冲击：向外炸开
      if (p.beat > 0.01) {
        const k = p.beat * (0.8 + this.hueF * 1.7) * 2.4;
        this.vx += nx * k * p.dt;
        this.vy += ny * k * p.dt;
      }

      // 5. 高频抖动：碎钻一样的闪
      if (p.treble > 0.12) {
        const j = (p.treble - 0.12) * 2.6 * p.dt;
        this.vx += (Math.random() - 0.5) * j;
        this.vy += (Math.random() - 0.5) * j;
      }

      // 6. 鼠标引力
      if (p.mouse && p.mouse.active) {
        const mx = this.x - p.mouse.x;
        const my = this.y - p.mouse.y;
        const md = Math.hypot(mx, my);
        if (md < 260 && md > 2) {
          const force = (1 - md / 260) * 0.5;
          this.vx -= (mx / md) * force * p.dt;
          this.vy -= (my / md) * force * p.dt;
        }
      }

      const damp = Math.pow(0.962, p.dt);
      this.vx *= damp;
      this.vy *= damp;
      this.x += this.vx * p.dt;
      this.y += this.vy * p.dt;

      // 根据角度找到对应的频谱柱，让光点和柱子同呼吸
      let idx = Math.floor((((Math.atan2(dy, dx) - Math.PI / 2 - p.barOffset) / TAU) * p.bars) % p.bars);
      if (idx < 0) idx += p.bars;
      this.band = p.spectrum[idx] || 0;

      const speed = Math.hypot(this.vx, this.vy);
      this.glow = clamp(
        0.1 + p.level * 0.55 + speed * 0.08 + p.beat * 0.2 + this.band * 0.95,
        0,
        1
      );
      this.hue = p.hueBase + this.hueF * p.hueSpan;

      // 跑太远就重新投放到轨道上
      if (this.dist > Math.max(width, height) * 0.8) this.reset();
    }

    draw() {
      const hue = ((this.hue % 360) + 360) % 360;
      const size = this.size * (1 + this.band * 2.4 + this.glow * 0.5);
      noStroke();

      if (this.glow > 0.5) {
        fill(hue, 92, 70, 0.07);
        ellipse(this.x, this.y, size * 4, size * 4);
      }
      fill(hue, 78, 58 + this.glow * 38, 0.3 + this.glow * 0.5);
      ellipse(this.x, this.y, size, size);
    }
  }

  class Spark {
    constructor(x, y, angle, speed, hue, life, size) {
      this.x = x;
      this.y = y;
      this.vx = Math.cos(angle) * speed;
      this.vy = Math.sin(angle) * speed;
      this.hue = hue;
      this.life = life;
      this.maxLife = life;
      this.size = size || 2;
    }

    update(dt) {
      this.vx *= Math.pow(0.955, dt);
      this.vy *= Math.pow(0.955, dt);
      this.x += this.vx * dt;
      this.y += this.vy * dt;
      this.life -= dt;
    }

    draw() {
      if (this.life <= 0) return;
      const a = clamp(this.life / this.maxLife, 0, 1);
      fill(((this.hue % 360) + 360) % 360, 90, 88, a * 0.85);
      ellipse(this.x, this.y, this.size * a, this.size * a);
    }
  }

  class Ring {
    constructor(x, y, startR, speed, hue, strength) {
      this.x = x;
      this.y = y;
      this.r = startR;
      this.speed = speed;
      this.hue = hue;
      this.life = 1;
      this.strength = strength || 0.5;
    }

    update(dt) {
      this.r += this.speed * dt;
      this.life -= 0.014 * dt;
    }

    draw() {
      if (this.life <= 0) return;
      stroke(((this.hue % 360) + 360) % 360, 60, 82, this.life * 0.42);
      strokeWeight(1 + this.life * 2.2);
      noFill();
      ellipse(this.x, this.y, this.r * 2, this.r * 2);
    }
  }

  class ParticleField {
    constructor() {
      this.particles = [];
      this.sparks = [];
      this.rings = [];
      this.cx = 0;
      this.cy = 0;
      this.r0 = 200;
      this.maxCount = 1400;
      this.minCount = 280;
    }

    layout(w, h, rescale) {
      const oldR = this.r0;
      const oldCx = this.cx;
      const oldCy = this.cy;

      this.cx = w / 2;
      this.cy = h / 2;
      this.r0 = Math.min(w, h) * 0.25;

      if (rescale && this.particles.length && oldR > 0) {
        const k = this.r0 / oldR;
        for (let i = 0; i < this.particles.length; i++) {
          const pt = this.particles[i];
          pt.x = this.cx + (pt.x - oldCx) * k;
          pt.y = this.cy + (pt.y - oldCy) * k;
          pt.vx *= k;
          pt.vy *= k;
        }
      }

      const target = Math.round(clamp((w * h) / 1200, this.minCount, this.maxCount));
      this.setCount(target);
    }

    setCount(n) {
      n = Math.round(n);
      while (this.particles.length < n) this.particles.push(new Particle(this));
      if (this.particles.length > n) this.particles.length = n;
    }

    kick(strength, hue) {
      const s = clamp(strength, 0.2, 1);
      this.rings.push(new Ring(this.cx, this.cy, this.r0 * 0.9, 3 + s * 7, hue, s));

      const count = Math.round(8 + s * 26);
      for (let i = 0; i < count; i++) {
        const a = Math.random() * TAU;
        const r = this.r0 * (0.85 + Math.random() * 0.25);
        this.sparks.push(new Spark(
          this.cx + Math.cos(a) * r,
          this.cy + Math.sin(a) * r,
          a,
          1.5 + s * 5,
          hue + (Math.random() - 0.5) * 50,
          30 + Math.random() * 40,
          1.5 + Math.random() * 2
        ));
      }
    }

    burst(x, y, count, hue) {
      for (let i = 0; i < count; i++) {
        const a = Math.random() * TAU;
        this.sparks.push(new Spark(
          x,
          y,
          a,
          1 + Math.random() * 5,
          hue + (Math.random() - 0.5) * 60,
          30 + Math.random() * 45,
          1.5 + Math.random() * 2.5
        ));
      }
    }

    update(p) {
      const params = {
        dt: p.dt,
        cx: this.cx,
        cy: this.cy,
        r0: this.r0,
        bass: p.bass,
        mid: p.mid,
        treble: p.treble,
        level: p.level,
        beat: p.beat,
        mouse: p.mouse,
        t: p.t,
        hueBase: p.hueBase,
        hueSpan: p.hueSpan,
        spectrum: p.spectrum,
        bars: p.bars,
        barOffset: p.barOffset,
      };

      for (let i = 0; i < this.particles.length; i++) {
        this.particles[i].update(params);
      }

      for (let i = this.sparks.length - 1; i >= 0; i--) {
        const s = this.sparks[i];
        s.update(p.dt);
        if (s.life <= 0) this.sparks.splice(i, 1);
      }

      for (let i = this.rings.length - 1; i >= 0; i--) {
        const r = this.rings[i];
        r.update(p.dt);
        if (r.life <= 0 || r.r > Math.max(width, height)) this.rings.splice(i, 1);
      }
    }

    drawRings() {
      for (let i = 0; i < this.rings.length; i++) this.rings[i].draw();
      noStroke();
    }

    drawParticles() {
      for (let i = 0; i < this.particles.length; i++) {
        this.particles[i].draw();
      }
    }

    drawSparks() {
      noStroke();
      for (let i = 0; i < this.sparks.length; i++) this.sparks[i].draw();
    }
  }

  global.ParticleField = ParticleField;
})(window);
