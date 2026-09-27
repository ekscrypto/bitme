#!/usr/bin/env python3
"""Generate GameAssets/index.html — a self-contained, searchable gallery of
all extracted assets. Open it in a browser (works from the local checkout via
file://); type to filter, click a tile to open the full PNG.

Run after every extraction refresh:
    .venv/bin/python make_gallery.py
"""

from __future__ import annotations

import argparse
import json
import os

DEFAULT_MANIFEST = os.path.join(
    os.path.dirname(__file__), "..", "..", "bitme-resources", "GameAssets", "manifest.json"
)

TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Bit-Me game assets</title>
<style>
  body { font-family: -apple-system, sans-serif; margin: 16px; background: #1e242c; color: #e6edf3; }
  header { position: sticky; top: 0; background: #1e242c; padding: 8px 0; z-index: 1; }
  input { font-size: 16px; padding: 6px 10px; width: 320px; border-radius: 6px; border: 1px solid #444; background: #2b333d; color: #e6edf3; }
  .cats button { margin: 2px; padding: 4px 10px; border-radius: 12px; border: 1px solid #444; background: #2b333d; color: #cfd8e3; cursor: pointer; }
  .cats button.on { background: #4d7cc1; color: #fff; border-color: #4d7cc1; }
  #count { color: #8b98a5; margin-left: 10px; font-size: 13px; }
  #grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 10px; margin-top: 12px; }
  .tile { text-align: center; font-size: 10px; color: #9aa7b4; word-break: break-all; }
  .tile img { width: 96px; height: 96px; object-fit: contain; background:
    repeating-conic-gradient(#2b333d 0% 25%, #343e4a 0% 50%) 0 0/16px 16px; border-radius: 6px; }
</style>
</head>
<body>
<header>
  <input id="q" placeholder="search file names… (regex ok)" autofocus>
  <span id="count"></span>
  <div class="cats" id="cats"></div>
</header>
<div id="grid"></div>
<script>
const ASSETS = __ASSETS__;
const grid = document.getElementById('grid'), q = document.getElementById('q'),
      count = document.getElementById('count'), cats = document.getElementById('cats');
const catOf = p => p.includes('/') ? p.split('/')[0] : '(root)';
const allCats = ['all', ...[...new Set(ASSETS.map(a => catOf(a.p)))].sort()];
let cat = 'all';
function render() {
  let pat;
  try { pat = new RegExp(q.value, 'i'); } catch { pat = new RegExp(q.value.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'i'); }
  const hits = ASSETS.filter(a => (cat === 'all' || catOf(a.p) === cat) && pat.test(a.p));
  count.textContent = hits.length + ' of ' + ASSETS.length;
  grid.innerHTML = hits.slice(0, 1200).map(a =>
    `<div class="tile"><a href="${a.p}"><img loading="lazy" src="${a.p}"></a><div>${a.p.split('/').pop()}</div></div>`
  ).join('');
}
for (const c of allCats) {
  const b = document.createElement('button');
  b.textContent = c; b.className = c === 'all' ? 'on' : '';
  b.onclick = () => { cat = c; [...cats.children].forEach(x => x.className = ''); b.className = 'on'; render(); };
  cats.appendChild(b);
}
q.oninput = render;
render();
</script>
</body>
</html>
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    args = ap.parse_args()

    manifest = json.load(open(args.manifest))
    assets = [{"p": m["path"], "w": m["width"], "h": m["height"]} for m in manifest["sprites"]]
    out = os.path.join(os.path.dirname(os.path.abspath(args.manifest)), "index.html")
    with open(out, "w") as f:
        f.write(TEMPLATE.replace("__ASSETS__", json.dumps(assets, separators=(",", ":"))))
    print(f"wrote {out} ({len(assets)} assets)")


if __name__ == "__main__":
    main()
