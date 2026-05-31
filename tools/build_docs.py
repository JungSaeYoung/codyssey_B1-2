#!/usr/bin/env python3
"""
build_docs.py — 프로젝트의 모든 .md 파일을 단일 HTML 사이트로 빌드한다.

결과:  ./docs/html/index.html  (단일 파일, 더블클릭으로 열림)
의존:  pip install markdown pygments
실행:  python3 tools/build_docs.py [--no-open]
"""

from __future__ import annotations
import sys
import json
import subprocess
from pathlib import Path

import markdown
from markdown.extensions.codehilite import CodeHiliteExtension
from markdown.extensions.toc import TocExtension
from pygments.formatters import HtmlFormatter

# 이 파일은 tools/ 아래에 있으므로 한 단계 더 올라가야 프로젝트 루트가 된다.
ROOT = Path(__file__).resolve().parent.parent
MD_DIR = ROOT / "docs" / "md"
OUT_DIR = ROOT / "docs" / "html"
OUT = OUT_DIR / "index.html"

# (표시 제목, 파일 경로) — 순서 유지
# README/실험_절차서 는 루트, 이론 지식·용어집·리포트는 그 외 위치
REPORTS_DIR = ROOT / "reports"
DOCS = [
    ("README",                ROOT / "README.md"),
    ("이론 지식",              MD_DIR / "이론_지식.md"),
    ("용어집",                 MD_DIR / "용어집.md"),
    ("실험 절차서",            ROOT / "실험_절차서.md"),
    ("[1] OOM 분석 리포트",    REPORTS_DIR / "01_oom_report.md"),
    ("[2] CPU 과점유 리포트",  REPORTS_DIR / "02_cpu_report.md"),
    ("[3] Deadlock 리포트",    REPORTS_DIR / "03_deadlock_report.md"),
    ("[보너스] 스케줄링 분석", REPORTS_DIR / "04_scheduling_analysis.md"),
]


def render_doc(file_path: Path):
    md = markdown.Markdown(
        extensions=[
            "extra",
            "tables",
            "fenced_code",
            "sane_lists",
            "attr_list",
            CodeHiliteExtension(css_class="codehilite", guess_lang=False),
            TocExtension(toc_depth="2-4", anchorlink=False, permalink="#"),
        ]
    )
    text = file_path.read_text(encoding="utf-8")
    html = md.convert(text)
    toc = md.toc  # nested <ul> structure
    return html, toc


def build():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    docs_data = []
    for title, f in DOCS:
        if not f.exists():
            print(f"  ! skip: {f} (not found)")
            continue
        html, toc = render_doc(f)
        # 파일 경로를 ROOT 기준 상대 경로로 — 내부 .md 링크 라우팅에 사용
        rel = f.relative_to(ROOT).as_posix()
        docs_data.append({
            "title": title,
            "file": rel,
            "html": html,
            "toc": toc,
        })

    # Pygments 라이트/다크 CSS — 같은 .codehilite 클래스, 부모 data-theme 으로 분기
    light_css = HtmlFormatter(style="friendly").get_style_defs(
        '[data-theme="light"] .codehilite'
    )
    dark_css = HtmlFormatter(style="monokai").get_style_defs(
        '[data-theme="dark"] .codehilite'
    )

    payload = json.dumps(docs_data, ensure_ascii=False)

    html_out = HTML_TEMPLATE.format(
        light_pygments=light_css,
        dark_pygments=dark_css,
        docs_json=payload,
    )

    OUT.write_text(html_out, encoding="utf-8")
    kb = OUT.stat().st_size // 1024
    # Windows console may use cp949; force utf-8 safe print
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    print(f"OK generated: {OUT.relative_to(ROOT)} ({kb} KB, {len(docs_data)} docs)")
    return OUT


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="ko" data-theme="light">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codyssey B1-2 — 시스템 장애 분석 Documentation</title>

  <link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin>
  <link rel="stylesheet"
        href="https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.min.css">
  <link rel="stylesheet"
        href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap">

  <style>
    :root {{
      --bg:#ffffff; --bg-alt:#f6f8fa; --bg-soft:#eef2f5;
      --fg:#1f2328; --fg-muted:#656d76;
      --border:#d0d7de; --accent:#0969da; --accent-soft:#ddf4ff;
      --code-bg:#f6f8fa;
      --side-w:300px;
    }}
    [data-theme="dark"] {{
      --bg:#0d1117; --bg-alt:#161b22; --bg-soft:#1c2330;
      --fg:#e6edf3; --fg-muted:#8b949e;
      --border:#30363d; --accent:#58a6ff; --accent-soft:#1f2d3d;
      --code-bg:#161b22;
    }}

    * {{ box-sizing: border-box; }}
    html, body {{ margin: 0; padding: 0; }}
    body {{
      font-family:'Pretendard','Pretendard Variable',-apple-system,BlinkMacSystemFont,
                   'Apple SD Gothic Neo','Noto Sans KR',sans-serif;
      background: var(--bg); color: var(--fg);
      line-height: 1.75; font-size: 16px;
      -webkit-font-smoothing: antialiased;
    }}
    a {{ color: var(--accent); text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}

    /* ── Layout ─────────────────────────────────────────────────────── */
    aside.sidebar {{
      position: fixed; top: 0; left: 0; bottom: 0; width: var(--side-w);
      background: var(--bg-alt); border-right: 1px solid var(--border);
      padding: 24px 20px; overflow-y: auto;
    }}
    main.content {{
      margin-left: var(--side-w); max-width: 920px;
      padding: 56px 64px 120px;
    }}
    @media (max-width: 900px) {{
      aside.sidebar {{
        transform: translateX(-100%); transition: transform .2s; z-index: 50;
        box-shadow: 0 0 24px rgba(0,0,0,.2);
      }}
      aside.sidebar.open {{ transform: translateX(0); }}
      main.content {{ margin-left: 0; padding: 24px; }}
      #menu-btn {{ display: flex !important; }}
    }}

    /* ── Sidebar ────────────────────────────────────────────────────── */
    .brand {{
      display: flex; align-items: center; gap: 8px;
      font-size: 17px; font-weight: 700;
      padding: 4px 8px 0; margin-bottom: 8px;
    }}
    .brand small {{ font-weight: 500; color: var(--fg-muted); font-size: 12px; }}
    .sec-label {{
      font-size: 11px; text-transform: uppercase; letter-spacing: .08em;
      color: var(--fg-muted); padding: 14px 8px 6px; font-weight: 600;
    }}
    .nav-list, .toc-list, .toc-list ul {{ list-style: none; padding: 0; margin: 0; }}
    .nav-list a {{
      display: block; padding: 8px 12px; color: var(--fg);
      border-radius: 6px; font-size: 14px; margin-bottom: 1px;
    }}
    .nav-list a:hover {{ background: var(--bg-soft); text-decoration: none; }}
    .nav-list a.active {{ background: var(--accent); color: #fff; }}
    .nav-list a.active:hover {{ text-decoration: none; }}

    /* TOC (Python markdown extension 이 만든 nested ul 형태) */
    .toc-list a {{
      display: block; padding: 3px 10px;
      color: var(--fg-muted); font-size: 13px;
      border-left: 2px solid transparent;
      line-height: 1.45;
    }}
    .toc-list a:hover {{ color: var(--fg); text-decoration: none; }}
    .toc-list a.active {{
      color: var(--accent); border-left-color: var(--accent);
      background: var(--accent-soft);
    }}
    .toc-list ul ul a {{ padding-left: 24px; font-size: 12.5px; }}
    .toc-list ul ul ul a {{ padding-left: 38px; font-size: 12px; opacity: .85; }}

    /* ── Controls ───────────────────────────────────────────────────── */
    .controls {{
      position: fixed; top: 16px; right: 24px; display: flex; gap: 8px; z-index: 20;
    }}
    .ctl-btn {{
      background: var(--bg-alt); border: 1px solid var(--border);
      border-radius: 8px; padding: 8px 12px; cursor: pointer;
      color: var(--fg); font-size: 13px; font-family: inherit;
      display: inline-flex; align-items: center; gap: 6px;
    }}
    .ctl-btn:hover {{ background: var(--bg-soft); }}

    #menu-btn {{
      display: none; position: fixed; top: 16px; left: 16px; z-index: 60;
      background: var(--bg-alt); border: 1px solid var(--border);
      border-radius: 8px; width: 38px; height: 38px;
      align-items: center; justify-content: center; cursor: pointer;
      color: var(--fg); font-size: 18px;
    }}

    /* ── Content typography ─────────────────────────────────────────── */
    main.content h1, main.content h2, main.content h3,
    main.content h4, main.content h5 {{
      color: var(--fg); font-weight: 700; line-height: 1.35;
      scroll-margin-top: 24px;
    }}
    main.content h1 {{
      font-size: 2.1em; margin: 0 0 .6em;
      border-bottom: 1px solid var(--border); padding-bottom: 14px;
    }}
    main.content h2 {{
      font-size: 1.55em; margin: 2.2em 0 .6em;
      border-bottom: 1px solid var(--border); padding-bottom: 8px;
    }}
    main.content h3 {{ font-size: 1.25em; margin: 1.8em 0 .5em; }}
    main.content h4 {{ font-size: 1.08em; margin: 1.4em 0 .4em; color: var(--fg-muted); }}
    main.content p {{ margin: 0.9em 0; }}
    main.content ul, main.content ol {{ padding-left: 1.5em; }}
    main.content li {{ margin: .25em 0; }}
    main.content hr {{ border: 0; border-top: 1px solid var(--border); margin: 2em 0; }}

    /* Inline code & code blocks */
    main.content :not(pre) > code {{
      background: var(--code-bg);
      padding: 0.18em 0.42em; border-radius: 5px;
      font-family: 'JetBrains Mono','SF Mono',Menlo,Consolas,monospace;
      font-size: 0.875em; word-break: break-word;
    }}
    main.content pre, main.content .codehilite pre {{
      background: var(--code-bg); padding: 16px 18px;
      border-radius: 8px; overflow-x: auto;
      border: 1px solid var(--border);
      font-family: 'JetBrains Mono','SF Mono',Menlo,Consolas,monospace;
      font-size: 13px; line-height: 1.55;
    }}
    main.content pre code {{
      background: none; padding: 0; font-size: inherit; border-radius: 0;
    }}
    .codehilite {{ margin: 1em 0; }}

    /* Blockquote */
    main.content blockquote {{
      margin: 1em 0; padding: 10px 18px;
      background: var(--bg-soft); border-left: 4px solid var(--accent);
      border-radius: 0 6px 6px 0; color: var(--fg);
    }}
    main.content blockquote > :first-child {{ margin-top: 0; }}
    main.content blockquote > :last-child {{ margin-bottom: 0; }}

    /* Table */
    main.content table {{
      border-collapse: collapse; margin: 1.2em 0;
      font-size: 0.92em; max-width: 100%;
    }}
    main.content th, main.content td {{
      border: 1px solid var(--border); padding: 8px 14px; text-align: left;
      vertical-align: top;
    }}
    main.content th {{ background: var(--bg-soft); font-weight: 600; }}
    main.content tr:nth-child(2n) td {{ background: var(--bg-alt); }}

    /* TOC permalink (#) */
    main.content .headerlink {{
      opacity: 0; margin-left: 8px; font-size: .85em; color: var(--fg-muted);
      text-decoration: none;
    }}
    main.content h1:hover .headerlink,
    main.content h2:hover .headerlink,
    main.content h3:hover .headerlink,
    main.content h4:hover .headerlink {{ opacity: 1; }}

    /* Doc meta */
    .doc-meta {{
      color: var(--fg-muted); font-size: 13px;
      margin: -8px 0 28px;
    }}
    .doc-meta code {{ font-size: .95em; background: var(--bg-soft);
                      padding: 2px 6px; border-radius: 4px; }}

    /* Print */
    @media print {{
      aside.sidebar, .controls, #menu-btn {{ display: none !important; }}
      main.content {{ margin-left: 0; max-width: 100%; padding: 0; }}
      a {{ color: var(--fg) !important; text-decoration: underline; }}
      pre, .codehilite pre {{ break-inside: avoid; }}
    }}

    /* Scrollbar */
    aside.sidebar::-webkit-scrollbar {{ width: 8px; }}
    aside.sidebar::-webkit-scrollbar-thumb {{ background: var(--border); border-radius: 4px; }}

    /* ── Pygments (light theme — friendly) ──────────────────────────── */
    {light_pygments}

    /* ── Pygments (dark theme — monokai) ────────────────────────────── */
    {dark_pygments}

    /* Pygments 공통: 라인 줄바꿈 방지 + 패딩 일관성 */
    .codehilite .hll {{ background-color: var(--accent-soft); }}
  </style>
</head>
<body>
  <button id="menu-btn" aria-label="menu">☰</button>
  <div class="controls">
    <button class="ctl-btn" id="theme-btn" onclick="toggleTheme()">
      <span id="theme-icon">🌙</span><span id="theme-label">Dark</span>
    </button>
    <button class="ctl-btn" onclick="window.print()">🖨️ Print</button>
  </div>

  <aside class="sidebar" id="sidebar">
    <div class="brand">📚 Codyssey B1-2 <small>· 시스템 장애 분석</small></div>
    <div class="sec-label">Documents</div>
    <ul class="nav-list" id="nav-list"></ul>
    <div class="sec-label">목차 (현재 문서)</div>
    <div class="toc-list" id="toc"></div>
  </aside>

  <main class="content" id="content">Loading…</main>

  <script>
    const DOCS = {docs_json};

    function renderNav() {{
      const nav = document.getElementById('nav-list');
      nav.innerHTML = DOCS.map((d, i) =>
        `<li><a href="#" data-i="${{i}}" onclick="loadDoc(${{i}});return false;">${{d.title}}</a></li>`
      ).join('');
    }}

    function loadDoc(i, anchor) {{
      const d = DOCS[i];
      const meta = `<p class="doc-meta">원본: <code>${{d.file}}</code></p>`;
      const content = document.getElementById('content');
      content.innerHTML = meta + d.html;

      // TOC 주입
      const toc = document.getElementById('toc');
      toc.innerHTML = `<div class="toc-list">${{d.toc || ''}}</div>`;

      // 내부 .md 링크를 SPA 라우팅으로
      // README.md 는 docs/md/xxx.md 로 가리키고, docs/md 안의 .md 들은 서로
      // 짧은 이름(xxx.md) 으로 가리킬 수 있다. basename 비교로 둘 다 매칭.
      // 앵커(#term)가 있으면 문서 전환 후 그 위치로 스크롤.
      const basename = (p) => (p || '').split('/').pop();
      content.querySelectorAll('a[href$=".md"], a[href*=".md#"]').forEach(a => {{
        const href = a.getAttribute('href');
        const hashIdx = href.indexOf('#');
        const filePart = hashIdx >= 0 ? href.slice(0, hashIdx) : href;
        const linkAnchor = hashIdx >= 0 ? href.slice(hashIdx + 1) : null;
        const fBase = basename(filePart);
        const idx = DOCS.findIndex(x => basename(x.file) === fBase);
        if (idx >= 0) {{
          a.onclick = (e) => {{ e.preventDefault(); loadDoc(idx, linkAnchor); }};
          a.style.cursor = 'pointer';
        }}
      }});

      // 활성 nav 표시
      document.querySelectorAll('#nav-list a').forEach(a =>
        a.classList.toggle('active', parseInt(a.dataset.i) === i)
      );

      // 모바일에서 사이드바 닫기
      document.getElementById('sidebar').classList.remove('open');

      // 앵커가 있으면 해당 헤딩으로 스크롤, 없으면 맨 위.
      // 렌더가 끝난 직후 DOM 이 안정되도록 다음 프레임에 수행.
      if (anchor) {{
        requestAnimationFrame(() => {{
          const el = document.getElementById(anchor);
          if (el) el.scrollIntoView({{ behavior: 'auto', block: 'start' }});
          else window.scrollTo(0, 0);
        }});
      }} else {{
        window.scrollTo(0, 0);
      }}
      localStorage.setItem('lastDoc', i);

      // 스크롤 스파이용 헤딩 인덱싱
      collectSpyTargets();
    }}

    let spyTargets = [];
    function collectSpyTargets() {{
      spyTargets = Array.from(
        document.querySelectorAll('main.content h2, main.content h3, main.content h4')
      );
    }}
    window.addEventListener('scroll', () => {{
      if (!spyTargets.length) return;
      const offset = 100;
      let activeId = null;
      for (const el of spyTargets) {{
        if (el.getBoundingClientRect().top < offset) activeId = el.id;
        else break;
      }}
      if (!activeId && spyTargets[0]) activeId = spyTargets[0].id;
      document.querySelectorAll('#toc a').forEach(a => {{
        const href = a.getAttribute('href');
        if (!href) return;
        a.classList.toggle('active', href === '#' + activeId);
      }});
    }}, {{ passive: true }});

    function applyTheme(theme) {{
      document.documentElement.dataset.theme = theme;
      document.getElementById('theme-icon').textContent  = theme === 'dark' ? '☀️' : '🌙';
      document.getElementById('theme-label').textContent = theme === 'dark' ? 'Light' : 'Dark';
      localStorage.setItem('theme', theme);
    }}
    function toggleTheme() {{
      const cur = document.documentElement.dataset.theme;
      applyTheme(cur === 'dark' ? 'light' : 'dark');
    }}

    (function init() {{
      const saved = localStorage.getItem('theme') ||
        (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
      applyTheme(saved);
      document.getElementById('menu-btn').onclick = () =>
        document.getElementById('sidebar').classList.toggle('open');
      renderNav();
      const last = parseInt(localStorage.getItem('lastDoc') || '0');
      loadDoc(isNaN(last) || last >= DOCS.length ? 0 : last);
    }})();
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    out = build()
    if "--no-open" not in sys.argv:
        try:
            subprocess.run(["open", str(out)], check=False)
        except FileNotFoundError:
            pass
