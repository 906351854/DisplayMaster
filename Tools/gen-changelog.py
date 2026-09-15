#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 CHANGELOG.md 生成官网首页的「版本更新」列表。

用法
----
    python3 Tools/gen-changelog.py            # 就地写回 docs/index.html
    python3 Tools/gen-changelog.py --check    # 只检查是否已同步（退出码 1 表示过期）

改完 CHANGELOG.md 跑一次，页面上那份列表就跟着更新。
生成的内容夹在 docs/index.html 的两行标记之间：

    <!-- gen:changelog BEGIN -->
    ...
    <!-- gen:changelog END -->

标记以外的地方一个字都不动，所以这个脚本可以反复跑。

列表里只有「结构」是从 CHANGELOG.md 抽出来的（版本号、一句话摘要、每节标题）；
**日期和下载次数**由页面的 assets/app.js 在浏览器里从 GitHub API 取，
不写进这个文件 —— 免得数字进了版本库、越放越旧。
"""

import argparse
import html
import re
import sys
from pathlib import Path

# 和 docs/assets/app.js 里的 REPO 保持一致
REPO = "906351854/DisplayMaster"
REPO_URL = "https://github.com/" + REPO

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
PAGE = ROOT / "docs" / "index.html"

BEGIN = "<!-- gen:changelog BEGIN -->"
END = "<!-- gen:changelog END -->"

CHEVRON = (
    '<svg class="cl-chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" '
    'aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>'
)


# ---------------------------------------------------------------------------
# Markdown 行内语法 → HTML（只支持 CHANGELOG 里实际用到的那几种）
# ---------------------------------------------------------------------------

CODE_RE = re.compile(r"`([^`]+)`")
BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def inline_md(text: str) -> str:
    """转义 HTML，再把 **粗体** / `代码` / [链接](url) 换成标签。"""
    out = html.escape(text.strip(), quote=False)
    out = CODE_RE.sub(r"<code>\1</code>", out)
    out = BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = LINK_RE.sub(r'<a href="\2" target="_blank" rel="noopener">\1</a>', out)
    return out


def plain(text: str) -> str:
    """去掉行内标记，只留文字（用来做一句话摘要的长度判断）。"""
    out = CODE_RE.sub(r"\1", text)
    out = BOLD_RE.sub(r"\1", out)
    out = LINK_RE.sub(r"\1", out)
    return out.strip()


def gist_of(lead: str) -> str:
    """把首段砍成一句话：遇到第一个句号 / 分号就停。

    列表折叠起来时每行只显示这一句，所以要短。砍不出东西就退回整段。
    """
    text = plain(lead)
    for sep in ("。", "；", ";"):
        idx = text.find(sep)
        if 0 < idx <= 60:
            text = text[:idx]
            break
    return text


# ---------------------------------------------------------------------------
# 解析 CHANGELOG.md
# ---------------------------------------------------------------------------

VERSION_RE = re.compile(r"^##\s+(\d+\.\d+\.\d+)\s*$")
SECTION_RE = re.compile(r"^###\s+(.+?)\s*$")
ITEM_RE = re.compile(r"^[-*]\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^\s*```")


def parse_changelog(text: str):
    """→ [{'version', 'lead', 'bullets'}, ...]，保持文件里的顺序（新 → 旧）。"""
    versions = []
    current = None
    seen_section = False
    in_fence = False

    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue

        m = VERSION_RE.match(line)
        if m:
            current = {"version": m.group(1), "lead": [], "bullets": []}
            versions.append(current)
            seen_section = False
            continue

        if current is None or in_fence:
            continue

        m = SECTION_RE.match(line)
        if m:
            seen_section = True
            # 「### ✨ 顺带」这种纯小标题也留一个，它说明还有零碎的改动
            current["bullets"].append(inline_md(m.group(1)))
            continue

        if seen_section:
            continue  # 小节标题已经在上面收过了，小节正文不进列表

        stripped = line.strip()
        if not stripped:
            continue

        m = ITEM_RE.match(stripped)
        if m:
            # 没有 ### 小节时（例如 1.0.0），把顶层条目当作要点
            current["bullets"].append(inline_md(m.group(1)))
            continue

        # 其余算作这一版的引导段（可能跨多行，拼起来）
        current["lead"].append(stripped)

    for v in versions:
        v["lead"] = " ".join(v["lead"]).strip()
    return versions


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------

def render(versions) -> str:
    blocks = []
    for i, v in enumerate(versions):
        ver = v["version"]
        lead = v["lead"]
        bullets = v["bullets"]

        parts = [f'    <details class="cl-item" data-ver="{ver}"{" open" if i == 0 else ""}>']
        parts.append("      <summary>")
        parts.append(f'        <span class="cl-tag">v{ver}</span>')
        parts.append('        <span class="cl-date" data-ver-date hidden></span>')
        if lead:
            parts.append(f'        <span class="cl-gist">{html.escape(gist_of(lead))}</span>')
        parts.append('        <span class="cl-dl" data-ver-dl hidden></span>')
        # 有些版本号只是改了 CHANGELOG、没单独出安装包（例如 1.1.0）。JS 查到
        # 没有对应 Release 时就把这句显示出来，位置和下载次数同一格 ——
        # 不然折叠状态下这一行会莫名其妙地少一截，看着像没写完。
        parts.append(
            '        <span class="cl-norel" data-ver-norel hidden>未单独发布安装包</span>'
        )
        parts.append(f"        {CHEVRON}")
        parts.append("      </summary>")
        parts.append('      <div class="cl-body">')

        if lead:
            # 引导段里可能本身就带 **粗体** / `代码`，这里按整段处理。
            # 太短的（例如 1.0.0 的「首个版本。」）上面摘要已经说完了，
            # 展开再重复一遍没有意义，就不放正文里了。
            if len(plain(lead)) > 12:
                parts.append(f'        <p class="cl-lead">{inline_md(lead)}</p>')

        if bullets:
            parts.append('        <ul class="cl-list">')
            for b in bullets:
                parts.append(f"          <li>{b}</li>")
            parts.append("        </ul>")

        parts.append('        <div class="cl-foot">')
        parts.append(
            f'          <a class="cl-rel" data-ver-rel hidden '
            f'href="{REPO_URL}/releases/tag/v{ver}">下载此版本</a>'
        )
        parts.append("        </div>")
        parts.append("      </div>")
        parts.append("    </details>")

        blocks.append("\n".join(parts))

    return "\n\n".join(blocks) + "\n"


def build() -> str:
    versions = parse_changelog(CHANGELOG.read_text(encoding="utf-8"))
    if not versions:
        raise SystemExit("CHANGELOG.md 里没解析出任何版本（找不到 `## x.y.z` 这样的标题）")
    return render(versions)


def splice(page: str, body: str) -> str:
    if BEGIN not in page or END not in page:
        raise SystemExit(f"docs/index.html 里找不到 {BEGIN} / {END} 标记")
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    return pattern.sub(BEGIN + "\n" + body + "    " + END, page, count=1)


def main() -> int:
    ap = argparse.ArgumentParser(description="从 CHANGELOG.md 生成官网的版本更新列表")
    ap.add_argument("--check", action="store_true",
                    help="只检查是否已同步，不写文件；过期则退出码为 1")
    args = ap.parse_args()

    body = build()
    page = PAGE.read_text(encoding="utf-8")
    updated = splice(page, body)

    if args.check:
        if updated != page:
            print("docs/index.html 的版本列表和 CHANGELOG.md 不一致，"
                  "跑一次 python3 Tools/gen-changelog.py 更新它", file=sys.stderr)
            return 1
        print("版本列表已是最新")
        return 0

    if updated == page:
        print("版本列表没有变化")
        return 0

    PAGE.write_text(updated, encoding="utf-8")
    n = body.count("<details")
    print(f"已更新 docs/index.html 里的版本列表（{n} 个版本）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
