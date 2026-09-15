/* ==========================================================================
   Display Master — 官网脚本
   --------------------------------------------------------------------------
   四件小事，都不依赖任何第三方库：
     1. 明暗主题切换（记住用户选择）
     2. 自动读取 GitHub Release：版本号 / 体积 / 日期 / 下载次数，顺便填
        首页「版本更新」列表里每个版本的发布日期和下载量
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
     2. Release 数据（版本号 / 体积 / 日期 / 下载次数）
     页面里凡是带这些属性的元素都会被自动填上：
       data-rel="version"       → v1.4.0
       data-rel="size"          → 2.9 MB
       data-rel="date"          → 2026-09-15
       data-rel="download"      → 优先 .dmg 的直链（写成 a 标签的 href）
       data-rel="download-zip"  → 强制取 .zip 的直链
       data-rel="dl-dmg"        → 所有版本的 .dmg 累计被下载次数
       data-rel="dl-zip"        → 所有版本的 .zip 累计被下载次数

     首页那块「版本更新」列表（结构由 Tools/gen-changelog.py 生成）也在这里补数字。
     只有最新版和钉住的版本（见生成器里的 PINNED_DOWNLOADS）才带下载入口，
     其余版本生成的是静态的「此版本不提供下载」，不归这段 JS 管：
       [data-ver="1.4.1"] 里面
         [data-ver-date]    → 发布日期（所有版本都填）
         [data-ver-dl]      → 这一版的安装包被下载次数（仅可下载的版本有此元素）
         [data-ver-rel]     → 有对应 Release 时显示「下载此版本」并指向它
         [data-ver-norel]   → 没有对应 Release 时显示「未单独发布安装包」

     这些数字元素默认都带 hidden，取到数据才摘掉 —— 拿不到就什么都不显示，
     不会在页面上留一排「—」。同理，取不到网络数据时静态文字/链接继续有效。
     每次访问只发一个请求，结果在 localStorage 里存 30 分钟：既少打 API
     （未认证的额度是每小时 60 次），被限流时也能退回上次的数据。
     ---------------------------------------------------------------------- */

  var RELEASES_KEY = 'dm-releases';
  var RELEASES_TTL = 30 * 60 * 1000;

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

  /* 1234 → "1,234" */
  function humanCount(n) {
    try { return Number(n).toLocaleString('zh-CN'); }
    catch (e) { return String(n); }
  }

  /* 按扩展名在资产列表里挑一个 */
  function pickAsset(assets, ext) {
    assets = assets || [];
    for (var i = 0; i < assets.length; i++) {
      if (String(assets[i].name || '').toLowerCase().slice(-ext.length) === ext) {
        return assets[i];
      }
    }
    return null;
  }

  /* 一个 Release 里所有资产被下载的次数之和 */
  function sumDownloads(release) {
    var assets = (release && release.assets) || [];
    var n = 0;
    for (var i = 0; i < assets.length; i++) n += Number(assets[i].download_count) || 0;
    return n;
  }

  /* 所有 Release 里某一类文件的累计下载次数 */
  function sumByExt(releases, ext) {
    var n = 0;
    releases.forEach(function (r) {
      var a = pickAsset(r.assets, ext);
      if (a) n += Number(a.download_count) || 0;
    });
    return n;
  }

  /* 只留用得上的字段再缓存，别把整个 API 响应塞进 localStorage */
  function trimReleases(list) {
    return (list || []).map(function (r) {
      return {
        tag_name: r.tag_name,
        published_at: r.published_at,
        html_url: r.html_url,
        draft: !!r.draft,
        prerelease: !!r.prerelease,
        assets: (r.assets || []).map(function (a) {
          return {
            name: a.name,
            size: a.size,
            download_count: a.download_count,
            browser_download_url: a.browser_download_url
          };
        })
      };
    });
  }

  function readCache() {
    try {
      var raw = localStorage.getItem(RELEASES_KEY);
      if (!raw) return null;
      var obj = JSON.parse(raw);
      if (!obj || !obj.list || !obj.list.length) return null;
      return obj;
    } catch (e) { return null; }   // 隐私模式 / 存坏了
  }

  function writeCache(list) {
    try {
      localStorage.setItem(RELEASES_KEY, JSON.stringify({ ts: Date.now(), list: list }));
    } catch (e) {}
  }

  function fetchReleases() {
    var cached = readCache();
    if (cached && Date.now() - cached.ts < RELEASES_TTL) {
      return Promise.resolve(cached.list);
    }
    return fetch('https://api.github.com/repos/' + REPO + '/releases?per_page=100', {
      headers: { Accept: 'application/vnd.github+json' }
    })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (list) {
        var trimmed = trimReleases(list);
        if (trimmed.length) writeCache(trimmed);
        return trimmed;
      })
      .catch(function () {
        // 限流或离线：有旧数据就用旧的，一点都没有才放弃
        if (cached) return cached.list;
        throw new Error('no release data');
      });
  }

  /* 把下载次数写进按钮上的小胶囊 */
  function fillCount(kind, text, title) {
    document.querySelectorAll('[data-rel="' + kind + '"]').forEach(function (el) {
      if (!text) return;
      el.textContent = text;
      if (title) el.setAttribute('title', title);
      el.hidden = false;
    });
  }

  /* 把数字填进「版本更新」列表 */
  function fillChangelog(releases) {
    var byVersion = {};
    releases.forEach(function (r) {
      byVersion[String(r.tag_name || '').replace(/^v/, '')] = r;
    });

    document.querySelectorAll('[data-ver]').forEach(function (item) {
      var ver = item.getAttribute('data-ver');
      var rel = byVersion[ver];
      var dateEl = item.querySelector('[data-ver-date]');
      var dlEl = item.querySelector('[data-ver-dl]');
      var relEl = item.querySelector('[data-ver-rel]');
      var noneEl = item.querySelector('[data-ver-norel]');

      // 只改了 CHANGELOG、没单独出安装包的版本号（例如 1.1.0）
      if (!rel) {
        if (noneEl) noneEl.hidden = false;
        return;
      }

      if (dateEl && rel.published_at) {
        dateEl.textContent = shortDate(rel.published_at);
        dateEl.hidden = false;
      }

      var n = sumDownloads(rel);
      if (dlEl && n > 0) {
        dlEl.textContent = humanCount(n) + ' 次下载';
        dlEl.hidden = false;
      }

      if (relEl) {
        if (rel.html_url) relEl.setAttribute('href', rel.html_url);
        relEl.hidden = false;
      }
    });

    // 底部那行「下载此版本」可能整行都没内容（例如没有对应 Release 的版本号），
    // 留着会白占一行高度 —— 空了就把它自己收起来。
    document.querySelectorAll('.cl-foot').forEach(function (foot) {
      var visible = false;
      Array.prototype.forEach.call(foot.children, function (child) {
        if (!child.hidden) visible = true;
      });
      if (!visible) foot.hidden = true;
    });
  }

  function initRelease() {
    var targets = document.querySelectorAll('[data-rel]');
    if (!targets.length) return;

    // 打不开 API 也要保证页面可用：所有链接先指向 releases/latest 这个稳定跳转
    document.querySelectorAll('[data-rel="download"], [data-rel="download-zip"]').forEach(function (el) {
      if (el.tagName === 'A' && !el.getAttribute('href')) {
        el.setAttribute('href', REPO_URL + '/releases/latest');
      }
    });

    fetchReleases()
      .then(function (list) {
        // GitHub 的这个列表按时间倒序，所以第一个正式版就是「最新版」
        var releases = list.filter(function (r) { return !r.draft && !r.prerelease; });
        if (!releases.length) return;

        var latest = releases[0];
        var tag = String(latest.tag_name || '').replace(/^v/, '');
        var assets = latest.assets || [];
        // 主推 .dmg：挂载后把图标拖进「应用程序」就装完了，比解压 zip 再拖更省事。
        // 没有 .dmg 时退回第一个资产（老版本 Release 只有 zip）。
        var main = pickAsset(assets, '.dmg') || assets[0] || null;
        var zip = pickAsset(assets, '.zip');

        targets.forEach(function (el) {
          var kind = el.getAttribute('data-rel');
          if (kind === 'version') {
            el.textContent = 'v' + tag;
          } else if (kind === 'size' && main) {
            el.textContent = humanSize(main.size);
          } else if (kind === 'date') {
            el.textContent = shortDate(latest.published_at);
          } else if (kind === 'download' && main) {
            el.setAttribute('href', main.browser_download_url);
          } else if (kind === 'download-zip' && zip) {
            el.setAttribute('href', zip.browser_download_url);
          }
        });

        // 按钮上的「下载次数」：按文件类型统计所有版本，说明的是这个文件本身
        // 一共被下过多少次。0 次就先不显示，别给人一个「0 次下载」的第一印象。
        var dmgTotal = sumByExt(releases, '.dmg');
        fillCount('dl-dmg', dmgTotal > 0 ? humanCount(dmgTotal) + ' 次下载' : '',
                  '所有版本的 .dmg 累计被下载 ' + humanCount(dmgTotal) + ' 次（GitHub 统计）');
        var zipTotal = sumByExt(releases, '.zip');
        fillCount('dl-zip', zipTotal > 0 ? humanCount(zipTotal) + ' 次下载' : '',
                  '所有版本的 .zip 累计被下载 ' + humanCount(zipTotal) + ' 次（GitHub 统计）');

        fillChangelog(releases);
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
