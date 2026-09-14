# 官网部署指南

这份文档写给第一次部署网站的人。目标：**不买域名、不租服务器**，用托管平台送的免费子域名，
把 Display Master 的官网挂到公网上。

站点文件已经在 `docs/` 目录里准备好了，你现在要做的只是「打开开关」。

---

## 目录

1. [选哪个平台](#1-选哪个平台)
2. [上线：GitHub Pages 完整流程](#2-上线github-pages-完整流程)
3. [上线后怎么验证](#3-上线后怎么验证)
4. [以后怎么改内容](#4-以后怎么改内容)
5. [想要更短的域名](#5-想要更短的域名)
6. [以后买域名了怎么绑](#6-以后买域名了怎么绑)
7. [出问题怎么查](#7-出问题怎么查)

---

## 1. 选哪个平台

三个都免费、都送子域名、都不用买服务器。**先看结论：选 GitHub Pages。**

| 平台 | 免费子域名长什么样 | 要不要配置构建 | 评价 |
|---|---|---|---|
| **GitHub Pages** | `906351854.github.io/DisplayMaster` | 不用 | ✅ 推荐。仓库和网站一体，推上去就等于发布 |
| Cloudflare Pages | `display-master.pages.dev` | 不用（可选） | 域名更短更好看，但要注册 Cloudflare 账号、连一次 Git |
| Vercel | `display-master.vercel.app` | 不用（可选） | 一样，界面偏现代，免费额度对个人项目够用 |
| Netlify | `display-master.netlify.app` | 不用（可选） | 一样，老牌，支持拖拽文件夹上传 |

几个关键点，新手容易踩：

- **GitHub Pages 的免费子域名里一定带用户名**，因为它是「用户/组织站点」的命名规则。
  想要 `display-master.xxx` 这种不带用户名的，得换 Cloudflare Pages 那一类。
- **这些都自带 HTTPS**（自动签证书），不用自己折腾。
- **本站点所有链接和资源都写成相对路径**，所以无论放哪个平台、无论挂在
  `example.com/DisplayMaster/` 还是根目录 `example.com/`，都不需要改一行代码。
- 当前 `docs/` 里是**纯静态文件**：没有构建步骤、没有第三方依赖。
  推上去是什么样，线上就是什么样。这也是为什么不推荐一开始就上静态站点生成器（Hugo / VitePress 等）——
  多一层构建就多一堆出错的地方，等内容多到手工维护不过来再换也不迟。

---

## 2. 上线：GitHub Pages 完整流程

### 前提

- 仓库是 **public**（私有仓库的 Pages 要付费）
- 你在这台电脑上有仓库的推送权限

### 第 1 步：确认站点文件就位

```bash
cd ~/DisplayMaster
ls docs/
```

应该看到：

```
.nojekyll    build.html   faq.html    icon.png
assets/      index.html   install.html   usage.html
```

> **`.nojekyll` 是干什么的？**
> GitHub Pages 默认会用 Jekyll（一个 Ruby 静态站点工具）处理你的文件。
> Jekyll 会忽略掉所有以 `_` 开头的文件/目录。放一个空的 `.nojekyll` 文件，
> 等于告诉它「别处理，原样发布」——既能避免 Jekyll 构建偶发失败，也保证文件按原样送出。

### 第 2 步：本地先看一眼

别直接推。先在本地起个服务确认没问题：

```bash
cd ~/DisplayMaster/docs
python3 -m http.server 8899
```

然后浏览器打开 <http://127.0.0.1:8899/>。

> 为什么不直接双击 `index.html`？因为那样是 `file://` 协议，
> 有些浏览器会拦掉 JavaScript 读取 GitHub API 的请求，你看不到「自动填版本号」的效果。
> 用本地服务器最接近真实环境。

看完按 `Ctrl` + `C` 停掉服务。

### 第 3 步：提交并推送

```bash
cd ~/DisplayMaster
git add docs
git commit -m "新增官网站点（GitHub Pages）"
git push
```

### 第 4 步：打开 Pages 开关

**这是唯一一个必须做的配置动作。**

#### 方式 A：网页操作（推荐新手）

1. 打开 <https://github.com/906351854/DisplayMaster/settings/pages>
2. 「**Source**」选 **Deploy from a branch**
3. 「**Branch**」选 **`main`**，右边目录选 **`/docs`**
4. 点 **Save**

#### 方式 B：命令行（需要装了 `gh`）

```bash
gh api -X POST repos/906351854/DisplayMaster/pages --input - <<'JSON'
{
  "source": {
    "branch": "main",
    "path": "/docs"
  }
}
JSON
```

想确认有没有开成功：

```bash
gh api repos/906351854/DisplayMaster/pages
```

返回的 JSON 里会有 `"html_url"` 和 `"status"`，`status` 是 `built` 就说明构建完成了。

### 第 5 步：等一两分钟

第一次发布要跑一次构建，通常 **30 秒到 2 分钟**。构建状态可以在仓库的
**Actions** 标签页里看到，任务名叫 `pages build and deployment`。

然后访问：

```
https://906351854.github.io/DisplayMaster/
```

---

## 3. 上线后怎么验证

按这个顺序检查，哪一步不对就照 [第 7 节](#7-出问题怎么查)排查：

```bash
# 1. 首页能不能通（-I 只看响应头，看状态码）
curl -I https://906351854.github.io/DisplayMaster/

# 2. 样式表能不能通（这一步不过，页面就是没样式的裸 HTML）
curl -I https://906351854.github.io/DisplayMaster/assets/style.css

# 3. 文档页能不能通
curl -I https://906351854.github.io/DisplayMaster/install.html
```

三条都返回 `HTTP/2 200` 就成功了。

再打开浏览器确认这几件事：

- [ ] 首页图标、渐变标题、按钮都正常显示（不是没有样式的纯文字）
- [ ] 点「下载最新版」能跳到 GitHub Releases
- [ ] 右上角主题按钮能切换明暗，刷新后选择还在
- [ ] 页面打开后，下载区块会出现真实的版本号和文件大小
- [ ] 手机上打开也正常（导航会收成汉堡菜单）

---

## 4. 以后怎么改内容

站点就是普通的 HTML/CSS，**不需要任何工具链，改完推送就生效**（等半分钟左右）。

### 改文字

直接编辑 `docs/` 下对应的 `.html`，文字都在标签里，找到就改：

```bash
# 用你顺手的编辑器，比如 VS Code
code docs/index.html
```

改完照旧：

```bash
git add docs && git commit -m "更新官网文案" && git push
```

### 改配色

所有颜色都收在 `docs/assets/style.css` 最上面的 `:root` 里，改这几个变量就能全站换色：

```css
:root {
  --accent-cyan: #22d3ee;      /* 渐变起点 */
  --accent-violet: #a855f7;    /* 渐变中间 */
  --accent-pink: #e879f9;      /* 渐变终点 */
  --gradient: linear-gradient(120deg, var(--accent-cyan), var(--accent-violet) 55%, var(--accent-pink));
}
```

深色和浅色两套底色分别在同文件的 `:root[data-theme="dark"]` 和 `:root[data-theme="light"]` 里。

### 首屏那层动态流光背景

背景是 `docs/assets/flow.js` 里的一块 WebGL 画布（着色器写在同文件的 `FRAG` 字符串里），
颜色直接用的就是上面那组霓虹渐变 —— 青 → 紫 → 粉。想改观感，按需求挑：

| 想改什么 | 改哪里 |
| --- | --- |
| 整体亮/暗 | `flow.js` 里的 `float strength = mix(浅色, 深色, uTheme);`，数值越小越含蓄 |
| 光丝多粗 | `silk(field, 等值线位置, 丝宽)` 三个调用的最后一个参数 |
| 光丝往哪偏 | `vec2 r = vec2(...)` 那行的旋转角 `0.50`（弧度）和纵向压缩 `2.90` |
| 模糊程度 | `style.css` 里 `canvas.fx` 的 `filter: blur(40px)`。调大更柔、更吃 GPU |
| 干脆关掉 | 删掉各页面里的 `<canvas class="fx">` 那一行即可；留着 canvas 但去掉 `flow.js` 会退回 CSS 兜底背景 |

另外两个开关不用管：明暗主题会跟着 `data-theme` 自动切参数；
系统开了「减少动效」时只渲染一帧静图，不再循环。

### 改仓库地址

如果将来仓库改名或搬走，只要改 `docs/assets/app.js` 顶部这两行：

```js
var REPO = '906351854/DisplayMaster';
var REPO_URL = 'https://github.com/' + REPO;
```

版本号会自动跟着最新 Release 走，不用手动改。

### 加一个新的文档页

1. 复制 `docs/install.html` 成 `docs/新页面.html`
2. 改里面的标题和正文
3. 在**每个**页面的侧栏（`<aside class="doc-side">`）里加一行链接

> 站点没有用模板引擎，所以导航是每个页面各写一份的。这是为了保持「零构建」——
> 代价是加页面时要多改几处。页面多到维护不过来时，再考虑上 VitePress 之类的工具。

### 发一个新版本（应用本身）

改完代码发新版，官网的下载区会**自动跟着更新**，不需要动站点文件。顺序是：

```bash
# 1. 改版本号（只改这一处，build.sh 会读它写进 Info.plist）
#    Sources/DisplayMaster/AppInfo.swift → version = "1.0.2"

# 2. 构建 + 安装 + 打 DMG（一条命令全干完）
cd ~/DisplayMaster
./build.sh --dmg
#   装到 /Applications 并重启；同时产出 build/DisplayMaster-1.0.2.dmg

# 3. 提交推送
git add -A && git commit -m "1.0.2：修复 xxx" && git push

# 4. 打 tag 并建 Release（附件名保持 DisplayMaster-<版本>.dmg）
git tag -a v1.0.2 -m "Display Master 1.0.2" && git push origin v1.0.2
gh release create v1.0.2 "build/DisplayMaster-1.0.2.dmg" \
  --title "Display Master 1.0.2" --notes-file /tmp/release-notes.md
```

> 只想构建到 `build/`、不动 `/Applications` 时用 `./build.sh --no-install --dmg`。
> 想同时提供 zip 就在 `gh release create` 后面再加一个
> `"build/DisplayMaster-1.0.2.zip"`（用 `ditto -c -k --sequesterRsrc --keepParent` 打，别用 `zip` 命令）。

### DMG 是怎么打出来的

`./build.sh --dmg` 会调用 `Tools/make-dmg.sh`，做四件事：

1. 把 `.app`、一个指向 `/Applications` 的软链、背景图、卷图标放进暂存目录
2. `hdiutil create` 造一个可写镜像，挂载
3. 写入 `.DS_Store`（窗口尺寸 / 图标位置 / 背景图），设置卷图标标志位
4. 卸载后用 `hdiutil convert -format UDZO` 压缩成最终的 DMG

**窗口布局那一步有两套实现，按可用性自动挑：**

| 方式 | 需要什么 | 说明 |
|---|---|---|
| `Tools/make-dsstore.py`（首选） | `pip install ds_store mac_alias` | 直接拼出 `.DS_Store`，不需要任何系统授权 |
| AppleScript 驱动 Finder（兜底） | 系统设置 → 隐私与安全性 → 自动化 → 勾选 Finder | 没装上面两个包时自动走这条 |
| 都不行 | — | 仍然产出可用的 DMG，只是窗口是默认样式 |

**踩过的坑，改这块代码前先看一眼：**

- `backgroundImageAlias` 里必须是**传统 Alias**（`00 00 00 00` 开头），不能是 Bookmark（`book` 魔数开头）。
  格式不对时 Finder **不报错**，只是静默不画背景图 —— 表现得像「窗口尺寸和图标位置都对，就是没背景」。
  用 `Alias.for_file()`，别用 `Bookmark.for_file()`。
- `WindowBounds` 的高度 = 背景图高度 + 22（标题栏）。背景图按 1:1 像素绘制，给 2x 图会溢出。
- 图标纵向位置必须和背景图里落点框的中心用**同一个值**，否则两者错开。
  这个值在 `Tools/make-dmg.sh` 顶部的 `ICON_Y`，通过参数传给图片生成器和 `.DS_Store` 生成器。
- Finder 底部还会压一条状态栏，所以图标区实际可用高度比窗口小 —— `ICON_Y` 取 175 而不是正中间，就是这个原因。
- 改完一定要 `open build/xxx.dmg` 亲眼看一眼。`.DS_Store` 写对了不代表 Finder 照做。

官网为什么不用改：下载按钮链到 `releases/latest`，版本号/体积/发布日期是页面加载时
用 GitHub API 现场取的（`docs/assets/app.js`）。**只有 Release 建好了，页面上才会显示新版本号。**

顺手记得更新 `CHANGELOG.md`（官网下载区的「更新日志」链接指向它）。

> 注意：`--notes-file` 里的说明会成为 Release 正文，也就是用户点进 Release 看到的内容。
> 建议按 `CHANGELOG.md` 里的写法，先讲「修了什么、为什么会这样」，别只写「修 bug」。

### 规范

- 内部链接一律写**相对路径**（`index.html`、`assets/style.css`），
  不要写 `/assets/style.css` 这种以斜杠开头的绝对路径 —— 换域名或换平台时绝对路径会全部失效。
- 代码块按这个结构写，会自动获得「复制」按钮和注释变灰的效果：

```html
<div class="code">
  <div class="code-head">终端</div>
  <pre><code># 这是注释，会自动变灰
echo "这是命令"</code></pre>
</div>
```

---

## 5. 想要更短的域名

GitHub Pages 的子域名固定带用户名，改不了。想要 `display-master.xxx` 这种，
把同一个 `docs/` 目录接到 Cloudflare Pages 就行，**站点文件一个字都不用改**。

### Cloudflare Pages 流程

1. 注册 <https://dash.cloudflare.com/sign-up>（免费）
2. 左侧选 **Workers & Pages** → **Create** → **Pages** → **Connect to Git**
3. 授权 Cloudflare 读取你的 GitHub 仓库，选中 `DisplayMaster`
4. 构建设置这样填：

   | 字段 | 填什么 |
   |---|---|
   | Framework preset | **None** |
   | Build command | **留空** |
   | Build output directory | **docs** |

5. 点 **Save and Deploy**

一分钟左右就会给你一个 `xxx.pages.dev` 的地址。项目名填 `display-master`，
地址就是 `display-master.pages.dev`。

好处是：免费额度**不限流量**（GitHub Pages 软限制每月 100 GB），而且以后想加
重定向、加访问统计都很方便。Vercel 和 Netlify 的操作几乎一样，选哪个都行。

> 这一步完全可选。GitHub Pages 已经够用，域名长一点不影响使用。

---

## 6. 以后买域名了怎么绑

两条路，看你的站点现在挂在哪：

### 情况一：还用 GitHub Pages

1. 在域名商（Cloudflare / 阿里云 / Namecheap 都行）把域名的 DNS 托管到 Cloudflare，或直接用域名商的 DNS 面板
2. 加一条 **CNAME** 记录：主机名 `www` → `906351854.github.io`
3. GitHub 仓库 → Settings → Pages → **Custom domain** 填你的域名，点 Save
4. 等 DNS 生效（几分钟到几小时），勾上 **Enforce HTTPS**

如果你想用**根域名**（`display-master.com` 而不是 `www.display-master.com`），
GitHub Pages 要求加 4 条 A 记录指向这几个 IP：

```
185.199.108.153
185.199.109.153
185.199.110.153
185.199.111.153
```

### 情况二：站点挂在 Cloudflare Pages

更简单：Pages 项目 → **Custom domains** → 填域名 → 按提示加 DNS 记录，证书自动签。

### 一个必须知道的坑

GitHub Pages 的**项目站点**（`用户名.github.io/仓库名/`）在绑定自有域名后，
访问路径会从 `/DisplayMaster/` 变成根目录 `/`。

**如果站点里用了以斜杠开头的绝对路径（`/assets/style.css`），绑域名后样式会全部失效。**
本站点在写的时候已经全部用相对路径，所以不受影响 —— 以后加内容时请继续保持这个习惯。

---

## 7. 出问题怎么查

### 打开是 404

按顺序查：

1. **等够了吗** —— 首次构建要 1-2 分钟
2. **Pages 开了吗** —— 访问 <https://github.com/906351854/DisplayMaster/settings/pages>，看 Source 是不是 `main` + `/docs`
3. **构建成功了吗** —— 仓库 **Actions** 标签页，看 `pages build and deployment` 是不是绿勾
4. **分支推上去了吗** —— `git status` 确认没有未推送的提交

### 页面能打开，但完全没有样式（裸 HTML）

99% 是资源路径写错。检查：

```bash
curl -I https://906351854.github.io/DisplayMaster/assets/style.css
```

如果是 `404`，说明 HTML 里的路径不对。本站点的页面都在 `docs/` 根目录下，
所以引用应该写成 `assets/style.css`，**不能**写 `/assets/style.css`。

### 打开首页显示的是 README 内容

说明 Pages 的源选成了仓库根目录。回 Settings → Pages 把目录改成 `/docs`。

### 下载按钮显示 `—` 而不是版本号和大小

那个数字是页面用 JavaScript 去问 GitHub API 要的，两种情况下会拿不到：

- 还没有发布过 Release（去 <https://github.com/906351854/DisplayMaster/releases> 建一个）
- 触发了 GitHub API 的匿名速率限制（每小时 60 次，按 IP 算，等一小时就好）

拿不到时页面会退回到静态占位文字，**下载链接本身始终有效**（它指向 `releases/latest`，
GitHub 会自动跳到最新版），所以不影响用户下载。

### 改了内容但线上没变

- 浏览器缓存：按 <kbd>⌘</kbd> + <kbd>Shift</kbd> + <kbd>R</kbd> 强制刷新
- 命令行的 CDN 缓存：`curl -H 'Cache-Control: no-cache' <url>`
- 构建还没跑完：看 Actions 标签页

### 想退回到最简单的状态

删掉 `docs/` 里的站点文件即可，仓库本身不受影响：

```bash
git rm -r docs/index.html docs/install.html docs/usage.html docs/faq.html docs/build.html docs/assets
git commit -m "移除官网站点"
git push
```

（`docs/icon.png` 是 README 在用的，要留着。）

---

## 附：这次上线用到的文件

```
docs/
├── .nojekyll          告诉 GitHub Pages 不要用 Jekyll 处理
├── index.html         首页：介绍、功能、下载、文档入口
├── install.html       安装（含 Gatekeeper 处理）
├── usage.html         使用说明
├── faq.html           常见问题
├── build.html         从源码构建
├── 404.html           找不到页面时的兜底页
├── icon.png           应用图标（README 也在用）
└── assets/
    ├── style.css      全站样式，配色变量集中在顶部
    ├── app.js         主题切换、版本号自动填充、复制按钮、移动端导航
    ├── flow.js        首屏的动态流光背景（WebGL，取不到上下文时退回 CSS 兜底）
    └── menubar.png    菜单栏图标（首页示意图里用）
```

总计 10 个文件，没有依赖、没有构建步骤。整个官网上线只需要在仓库设置里点一次开关。
