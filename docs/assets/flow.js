/* ==========================================================================
   Display Master — 首页动态流光背景
   --------------------------------------------------------------------------
   一块铺满视口的 WebGL 画布，跑一个自定义片元着色器：
     多层 value noise 做域扭曲（domain warping），把几条横向光带揉成流体形态，
     颜色取应用图标的霓虹渐变 —— 青 #22d3ee → 紫 #a855f7 → 粉 #e879f9，
     和页面上「下载最新版」按钮用的是同一组色。

   交互：鼠标移动会推开/吸引流体，光标附近额外加一层辉光，全部带缓动跟随。

   设计约束（都是有意为之，改之前先看一眼）：
     · 纯原生 WebGL1，不加载任何库，不请求任何外部资源 —— 官网本身零依赖。
     · 视口上半部分亮、往下迅速衰减，保证正文区域的对比度不被背景吃掉。
     · 明暗主题各一套参数：浅色下降低强度，避免彩色糊成一片。
     · 尊重「减少动效」：不循环渲染，只画一帧静态图。
     · 页面切到后台就停掉 RAF，不白烧 GPU/电。
     · 拿不到 WebGL 上下文时静默退出，交给 CSS 兜底背景。
   ========================================================================== */

(function () {
  'use strict';

  var canvas = document.querySelector('canvas.fx');
  if (!canvas) return;

  /* 「减少动效」下只渲染一帧，见后面的 uMotion */
  var reduceMotion = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ----------------------------------------------------------------------
     1. 着色器
     ---------------------------------------------------------------------- */

  var VERT = [
    'attribute vec2 aPos;',
    'void main() { gl_Position = vec4(aPos, 0.0, 1.0); }'
  ].join('\n');

  var FRAG = [
    'precision highp float;',
    '',
    'uniform vec2  uRes;      // 画布像素尺寸',
    'uniform float uTime;     // 秒',
    'uniform vec2  uMouse;    // 光标位置，0..1（左上为原点，已转成 y 向上）',
    'uniform float uTheme;    // 1 = 深色，0 = 浅色',
    'uniform float uMotion;   // 1 = 动画，0 = 静态帧',
    '',
    /* ---- 噪声工具 ---- */
    'float hash(vec2 p) {',
    '  p = fract(p * vec2(123.34, 456.21));',
    '  p += dot(p, p + 45.32);',
    '  return fract(p.x * p.y);',
    '}',
    '',
    'float vnoise(vec2 p) {',
    '  vec2 i = floor(p);',
    '  vec2 f = fract(p);',
    '  f = f * f * (3.0 - 2.0 * f);',
    '  float a = hash(i);',
    '  float b = hash(i + vec2(1.0, 0.0));',
    '  float c = hash(i + vec2(0.0, 1.0));',
    '  float d = hash(i + vec2(1.0, 1.0));',
    '  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);',
    '}',
    '',
    'float fbm(vec2 p) {',
    '  float v = 0.0;',
    '  float a = 0.5;',
    '  mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);',
    '  for (int i = 0; i < 5; i++) {',
    '    v += a * vnoise(p);',
    '    p = rot * p * 2.03;',
    '    a *= 0.5;',
    '  }',
    '  return v;',
    '}',
    '',
    /* 一条光丝：v 是场值，c 是等值线位置，w 是丝宽。
       细芯 + 宽辉光两层叠加，看起来才像「发光」而不是画了一条硬线。 */
    'float silk(float v, float c, float w) {',
    '  float d = (v - c) / w;',
    '  float core = exp(-d * d);',
    '  float halo = exp(-d * d * 0.13);',
    '  return core + 0.14 * halo;',
    '}',
    '',
    'void main() {',
    '  vec2 uv = (gl_FragCoord.xy - 0.5 * uRes) / uRes.y;   // y 方向归一，横竖屏都不变形',
    '  float aspect = uRes.x / uRes.y;',
    '  float t = uTime * uMotion;',
    '',
    /* ---- 光标：轻轻把流体推开 + 一圈涟漪，鼠标划过去能看见「被拨动」 ---- */
    '  vec2 m = (uMouse - 0.5) * vec2(aspect, 1.0);',
    '  float md = length(uv - m);',
    '  float infl = exp(-md * 1.25);',
    '  vec2 dir = (uv - m) / max(md, 1e-4);',
    /* 位移幅度小、且在光标正中心收敛到 0，否则坐标梯度爆掉会抠出一个黑洞 */
    '  vec2 p = uv - dir * 0.07 * infl * smoothstep(0.0, 0.22, md)',
    '              + vec2(0.0, 0.022 * sin(md * 6.0 - t * 1.5) * infl);',
    '',
    /* ---- 一层低频域扭曲：把直线揉弯，同时保住丝的连续性 ---- */
    '  vec2 q = p + 0.20 * vec2(',
    '    fbm(p * 1.15 + vec2(t * 0.15, -t * 0.09)) - 0.48,',
    '    fbm(p * 1.15 + vec2(-t * 0.11, t * 0.13) + 7.30) - 0.48',
    '  );',
    '',
    /* ---- 斜置 + 单轴压缩：把噪声拉成斜向的长丝 ---- */
    '  float ca = cos(0.50);',
    '  float sa = sin(0.50);',
    '  vec2 r = vec2(q.x * ca - q.y * sa, (q.x * sa + q.y * ca) * 2.90);',
    '',
    '  float f1 = fbm(r * 0.95 + vec2(t * 0.19, -t * 0.06));',
    '  float f2 = fbm(r * 1.85 - vec2(t * 0.27, t * 0.15) + 3.10);',
    '  float field = f1 + 0.32 * f2;',
    '',
    /* ---- 三条等值线 = 三股流光 ---- */
    '  float l1 = silk(field, 0.560, 0.030);',
    '  float l2 = silk(field, 0.690, 0.026);',
    '  float l3 = silk(field, 0.818, 0.033);',
    '  float lum = l1 + 0.92 * l2 + 0.84 * l3;',
    '',
    /* 用同一个低频场给丝调制明暗：同一条丝上一段亮一段暗，像光在里面流。
       底下留一点点基数，不然整片就全黑了 */
    '  lum *= 0.02 + 1.35 * f1;',
    '',
    /* ---- 色相沿屏幕横向平滑过渡：青 → 紫 → 粉，和按钮渐变同序 ---- */
    '  float gx = clamp(0.5 + (uv.x + 0.30 * sin(uv.y * 1.6 + t * 0.32)) / (aspect * 0.85), 0.0, 1.0);',
    '  vec3 cCyan   = vec3(0.133, 0.827, 0.933);   // #22d3ee',
    '  vec3 cViolet = vec3(0.659, 0.333, 0.969);   // #a855f7',
    '  vec3 cPink   = vec3(0.910, 0.475, 0.976);   // #e879f9',
    '  vec3 tint = mix(cCyan, cViolet, smoothstep(0.02, 0.60, gx));',
    '  tint = mix(tint, cPink, smoothstep(0.52, 0.98, gx));',
    '',
    /* ---- 垂直分布：亮度集中在首屏中上部，往下迅速收干，正文区保持干净 ---- */
    '  float vy = (uv.y - 0.20) / 0.36;',
    '  lum *= exp(-vy * vy);',
    '  lum *= 0.50 + 0.50 * smoothstep(1.55, 0.30, abs(uv.x));',
    '  lum *= 1.0 + 0.90 * infl;          // 光标附近整体提亮',
    '',
    '  float amt = clamp(lum, 0.0, 1.6);',
    '',
    /* ---- 底色与主题强度 ---- */
    '  vec3 bgDark  = vec3(0.031, 0.031, 0.047);   // #08080c',
    '  vec3 bgLight = vec3(0.984, 0.984, 0.992);   // #fbfbfd',
    '  vec3 bg = mix(bgLight, bgDark, uTheme);',
    '',
    /* 强度压得比较低：这是背景，不能和正文抢对比度 */
    '  float strength = mix(0.54, 0.80, uTheme);',
    '  vec3 col = mix(bg, tint, clamp(amt * strength, 0.0, 1.0));',
    '',
    /* 深色下压点暗角，视觉重心收到中间 */
    '  float vign = 1.0 - 0.30 * length(uv * vec2(0.70, 1.00));',
    '  col *= mix(1.0, vign, uTheme * 0.85);',
    '',
    /* 抖动掉 8bit 渐变里的色带 */
    '  col += (hash(gl_FragCoord.xy + fract(uTime) * 137.0) - 0.5) / 255.0;',
    '',
    '  gl_FragColor = vec4(col, 1.0);',
    '}'
  ].join('\n');

  /* ----------------------------------------------------------------------
     2. 建上下文（失败就交给 CSS 兜底）
     ---------------------------------------------------------------------- */

  var gl = null;
  var opts = { alpha: false, antialias: false, depth: false, stencil: false,
               powerPreference: 'low-power', preserveDrawingBuffer: true };

  try {
    gl = canvas.getContext('webgl', opts) || canvas.getContext('experimental-webgl', opts);
  } catch (e) { gl = null; }

  if (!gl) { document.documentElement.classList.add('fx-off'); return; }

  function compile(type, src) {
    var sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      if (window.console) console.warn('[flow] shader 编译失败：' + gl.getShaderInfoLog(sh));
      return null;
    }
    return sh;
  }

  var vs = compile(gl.VERTEX_SHADER, VERT);
  var fs = compile(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) { document.documentElement.classList.add('fx-off'); return; }

  var prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    if (window.console) console.warn('[flow] 着色器链接失败');
    document.documentElement.classList.add('fx-off');
    return;
  }
  gl.useProgram(prog);

  /* 一整块铺满的四边形 */
  var buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);

  var aPos = gl.getAttribLocation(prog, 'aPos');
  gl.enableVertexAttribArray(aPos);
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

  var uRes = gl.getUniformLocation(prog, 'uRes');
  var uTime = gl.getUniformLocation(prog, 'uTime');
  var uMouse = gl.getUniformLocation(prog, 'uMouse');
  var uTheme = gl.getUniformLocation(prog, 'uTheme');
  var uMotion = gl.getUniformLocation(prog, 'uMotion');

  /* ----------------------------------------------------------------------
     3. 尺寸与分辨率
     背景会被 CSS 再高斯模糊一层（见 style.css 里的 canvas.fx），
     所以没必要按满 DPR 渲染 —— 1.15 倍就够，GPU 开销省掉一半以上。
     画布比视口大 10%（CSS 里也是 110%），模糊边缘撑到屏幕外。
     ---------------------------------------------------------------------- */

  var scale = 1;

  function resize() {
    var cssW = window.innerWidth * 1.1;
    var cssH = window.innerHeight * 1.1;
    var dpr = Math.min(window.devicePixelRatio || 1, 1.15);
    if (window.innerWidth < 760) dpr = Math.min(dpr, 1.0);   // 手机再降一档

    var w = Math.max(1, Math.round(cssW * dpr));
    var h = Math.max(1, Math.round(cssH * dpr));
    if (canvas.width === w && canvas.height === h) return;

    canvas.width = w;
    canvas.height = h;
    scale = dpr;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(uRes, w, h);
  }

  /* 画一帧。抽出来是因为除了动画循环，主题切换、尺寸变化、外部强制重绘都要用它 */
  function drawAt(t) {
    resize();
    gl.uniform1f(uTime, t);
    gl.uniform2f(uMouse, cur.x, cur.y);
    gl.uniform1f(uTheme, theme);
    gl.uniform1f(uMotion, reduceMotion ? 0 : 1);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  /* ----------------------------------------------------------------------
     4. 光标：目标值 + 缓动，避免鼠标一动流体就跳
     ---------------------------------------------------------------------- */

  var target = { x: 0.5, y: 0.62 };   // 静置时略偏下，正好压在标题区
  var cur = { x: target.x, y: target.y };

  function onPointer(e) {
    target.x = e.clientX / window.innerWidth;
    // 着色器里 y 向上，浏览器事件 y 向下，这里翻一下
    target.y = 1 - e.clientY / window.innerHeight;
  }
  window.addEventListener('pointermove', onPointer, { passive: true });
  window.addEventListener('touchmove', function (e) {
    if (e.touches && e.touches.length) onPointer(e.touches[0]);
  }, { passive: true });

  /* ----------------------------------------------------------------------
     5. 主题（跟随 <html data-theme>，由 app.js 切换，这里只读）
     ---------------------------------------------------------------------- */

  var theme = 1;

  function readTheme() {
    theme = document.documentElement.getAttribute('data-theme') === 'light' ? 0 : 1;
  }
  readTheme();

  /* app.js 改的是 html 上的属性，所以监听属性变化就够了，两边零耦合 */
  if (window.MutationObserver) {
    new MutationObserver(readTheme).observe(document.documentElement, {
      attributes: true, attributeFilter: ['data-theme']
    });
  }

  /* ----------------------------------------------------------------------
     6. 渲染循环
     ---------------------------------------------------------------------- */

  var start = performance.now();
  var raf = 0;
  var running = false;

  /* 背景流得很慢，没必要跟着显示器满帧跑。
     限到 30fps 左右，配合 CSS 那层模糊，视觉上看不出差别，GPU 占用直接减半。 */
  var lastDraw = 0;
  var MIN_INTERVAL = 1000 / 30;

  function frame(now) {
    raf = requestAnimationFrame(frame);

    var elapsed = now - lastDraw;
    if (elapsed < MIN_INTERVAL) return;

    /* 缓动跟随光标。补一下漏掉的时间，免得限帧后跟随变迟钝 */
    var k = Math.min(0.055 * (elapsed / (1000 / 60)), 0.5);
    lastDraw = now;

    cur.x += (target.x - cur.x) * k;
    cur.y += (target.y - cur.y) * k;

    drawAt(((now - start) / 1000) % 3600);
  }

  function play() {
    if (running) return;
    running = true;
    raf = requestAnimationFrame(frame);
  }

  function pause() {
    if (!running) return;
    running = false;
    cancelAnimationFrame(raf);
  }

  /* 切到后台就停：省电，也避免回来时时间跳变 */
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { pause(); } else { play(); }
  });

  /* 窗口尺寸变了要重算画布，静态帧模式下也得重画一次 */
  var resizeTimer = 0;
  window.addEventListener('resize', function () {
    resize();
    if (reduceMotion) { frameOnce(); return; }
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { resize(); }, 120);
  });

  /* 画一帧静图：给「减少动效」模式和主题切换用 */
  function frameOnce() { drawAt(12.0); }

  /* 主题切换后立刻按新参数重画（动画模式下下一帧自然会跟上） */
  if (window.MutationObserver) {
    new MutationObserver(function () {
      readTheme();
      if (!running) frameOnce();
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  }

  /* 画布尺寸要在第一次绘制前就设对，所以这里不能等 rAF：
     首帧被推迟的场合（离屏渲染、窗口刚创建、标签页在后台）会一直停在 300×150 的默认尺寸。 */
  resize();

  if (reduceMotion) {
    frameOnce();                 // 只画一帧静图，不循环
  } else {
    play();
  }

  /* 页面是用 bfcache 回来的话，重新开跑 */
  window.addEventListener('pageshow', function (e) {
    if (e.persisted && !reduceMotion) play();
  });

  /* 对外的小接口：调试用，也给离线截图验证用（离屏窗口不产生 rAF，得手动驱动） */
  window.DisplayMasterFx = {
    pause: pause,
    play: play,
    render: drawAt,
    /* x / y 都是 0..1，y 向上（和着色器一致） */
    setPointer: function (x, y) { target.x = cur.x = x; target.y = cur.y = y; },
    get scale() { return scale; }
  };
})();
