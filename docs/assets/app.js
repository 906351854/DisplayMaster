/* ==========================================================================
   Display Master — 官网脚本
   --------------------------------------------------------------------------
   四件小事，都不依赖任何第三方库：
     1. 明暗主题切换（记住用户选择）
     2. 自动读取 GitHub 最新 Release，把版本号/体积/日期填进页面
     3. 代码块「复制」按钮
     4. 移动端导航开合
   ========================================================================== */

(function () {
  'use strict';

  /* 项目信息：换仓库只需要改这两行 */
  var REPO = '906351854/DisplayMaster';
  var REPO_URL = 'https://github.com/' + REPO;

  /* ----------------------------------------------------------------------
     1. 主题切换
     默认深色（和应用图标的黑底霓虹统一）；用户手动切过就以他的选择为准。
     ---------------------------------------------------------------------- */

  var THEME_KEY = 'dm-theme';

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    var btn = document.querySelector('.theme-btn');
    if (btn) {
      var toLight = theme === 'dark';
      btn.setAttribute('aria-label', toLight ? '切换到浅色模式' : '切换到深色模式');
      btn.setAttribute('title', toLight ? '切换到浅色模式' : '切换到深色模式');
      // 深色时显示太阳（点击变亮），浅色时显示月亮
      btn.innerHTML = toLight
        ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.5v2M12 19.5v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M2.5 12h2M19.5 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 14.5A8.5 8.5 0 1 1 9.5 3.5a7 7 0 0 0 11 11Z"/></svg>';
    }
  }

  function initTheme() {
    // 提前把主题定下来，避免页面闪一下白
    var saved = null;
    try { saved = localStorage.getItem(THEME_KEY); } catch (e) { /* 隐私模式下会抛错 */ }
    applyTheme(saved === 'light' ? 'light' : 'dark');

    var btn = document.querySelector('.theme-btn');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      applyTheme(next);
      try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
    });
  }

  /* ----------------------------------------------------------------------
     2. 最新 Release
     页面里凡是带这些属性的元素都会被自动填上：
       data-rel="version"   → 1.0.0
       data-rel="size"      → 12.3 MB
       data-rel="date"      → 2026-09-14
       data-rel="download"  → zip 直链（写成 a 标签的 href）
     拿不到网络数据时静默放弃，页面上原有的静态文字/链接继续有效。
     ---------------------------------------------------------------------- */

  /* 把字节数变成人看的体积 */
  function humanSize(bytes) {
    if (!bytes && bytes !== 0) return '';
    var mb = bytes / 1048576;
    if (mb >= 1) return mb.toFixed(1) + ' MB';
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }

  /* 2026-09-14T10:00:00Z → 2026-09-14 */
  function shortDate(iso) {
    if (!iso) return '';
    return String(iso).slice(0, 10);
  }

  function initRelease() {
    var targets = document.querySelectorAll('[data-rel]');
    if (!targets.length) return;

    // 打不开 API 也要保证页面可用：所有链接先指向 releases/latest 这个稳定跳转
    document.querySelectorAll('[data-rel="download"]').forEach(function (el) {
      if (el.tagName === 'A' && !el.getAttribute('href')) {
        el.setAttribute('href', REPO_URL + '/releases/latest');
      }
    });

    fetch('https://api.github.com/repos/' + REPO + '/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' }
    })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (rel) {
        var tag = String(rel.tag_name || '').replace(/^v/, '');
        var asset = (rel.assets || [])[0] || null;

        targets.forEach(function (el) {
          var kind = el.getAttribute('data-rel');
          if (kind === 'version') {
            el.textContent = 'v' + tag;
          } else if (kind === 'size' && asset) {
            el.textContent = humanSize(asset.size);
          } else if (kind === 'date') {
            el.textContent = shortDate(rel.published_at);
          } else if (kind === 'download' && asset) {
            // 直接给 zip 直链，省得用户再进 release 页面点一次
            el.setAttribute('href', asset.browser_download_url);
          }
        });
      })
      .catch(function () {
        /* 离线或触发速率限制：保持静态占位文字，不打扰用户 */
      });
  }

  /* ----------------------------------------------------------------------
     3. 代码块复制按钮
     只要给 .code 加一个 <div class="code-head">标题</div>，按钮会自动补上。
     ---------------------------------------------------------------------- */

  var COPY_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';

  function initCopyButtons() {
    document.querySelectorAll('.code').forEach(function (box) {
      var codeEl = box.querySelector('code');
      var head = box.querySelector('.code-head');
      if (!codeEl || !head) return;

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'copy-btn';
      btn.innerHTML = COPY_ICON + '<span>复制</span>';
      head.appendChild(btn);

      btn.addEventListener('click', function () {
        var text = codeEl.textContent;
        var done = function () {
          btn.classList.add('done');
          btn.querySelector('span').textContent = '已复制';
          setTimeout(function () {
            btn.classList.remove('done');
            btn.querySelector('span').textContent = '复制';
          }, 1600);
        };

        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done).catch(fallback);
        } else {
          fallback();
        }

        // 老浏览器 / 非 https 环境下的兜底方案
        function fallback() {
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); done(); } catch (e) {}
          document.body.removeChild(ta);
        }
      });
    });
  }

  /* ----------------------------------------------------------------------
     3.5 给 Shell 代码块里的 # 注释降一级颜色
     只在代码块是纯文本（没有特殊标签）时才处理，避免破坏已标记的内容。
     ---------------------------------------------------------------------- */

  function initCommentDimming() {
    document.querySelectorAll('.code code').forEach(function (codeEl) {
      if (codeEl.children.length) return;              // 已经有子标签，跳过
      if (!/^\s*#/m.test(codeEl.textContent)) return;   // 没有注释行，跳过

      var lines = codeEl.textContent.split('\n');
      codeEl.textContent = '';
      lines.forEach(function (line, i) {
        if (i) codeEl.appendChild(document.createTextNode('\n'));
        if (/^\s*#/.test(line)) {
          var span = document.createElement('span');
          span.className = 'cmt';
          span.textContent = line;
          codeEl.appendChild(span);
        } else {
          codeEl.appendChild(document.createTextNode(line));
        }
      });
    });
  }

  /* ----------------------------------------------------------------------
     4. 移动端导航
     ---------------------------------------------------------------------- */

  function initNav() {
    var toggle = document.querySelector('.nav-toggle');
    var links = document.querySelector('.nav-links');
    if (!toggle || !links) return;

    toggle.addEventListener('click', function () {
      links.classList.toggle('open');
    });

    // 点了链接就把抽屉收起来
    links.querySelectorAll('a').forEach(function (a) {
      a.addEventListener('click', function () { links.classList.remove('open'); });
    });
  }

  /* ----------------------------------------------------------------------
     5. 高亮当前页面对应的导航项
     静态站点没有路由，就按文件名比对。
     ---------------------------------------------------------------------- */

  function initActiveNav() {
    var here = location.pathname.split('/').pop() || 'index.html';
    document.querySelectorAll('.nav-links a, .doc-side a').forEach(function (a) {
      var href = a.getAttribute('href');
      if (!href || href.indexOf('http') === 0 || href.indexOf('#') === 0) return;
      if (href === here) a.classList.add('active');
    });
  }

  /* ----------------------------------------------------------------------
     启动
     ---------------------------------------------------------------------- */

  function boot() {
    initTheme();
    initNav();
    initActiveNav();
    initCopyButtons();
    initCommentDimming();
    initRelease();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
