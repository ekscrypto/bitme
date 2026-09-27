#!/usr/bin/env python3
"""Find extracted BitCraft assets (and client sprites not yet extracted).

Searches GameAssets/manifest.json by regex (case-insensitive) and prints the
extracted file for each match; with --catalog it also lists matching sprites
that exist in the game client but aren't in the extraction (e.g. OldGeneratedIcons
or non-sprite assets), so you know where to look next.

Usage:
    .venv/bin/python find_assets.py 'profession|emblem'
    .venv/bin/python find_assets.py --catalog 'CopperOre|CopperIngot'
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

DEFAULT_MANIFEST = os.path.join(
    os.path.dirname(__file__), "..", "..", "bitme-resources", "GameAssets", "manifest.json"
)
DEFAULT_GAME_DIR = os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/BitCraft Online/BitCraft.app"
)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pattern", help="regex matched against file paths (case-insensitive)")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--catalog", action="store_true",
                    help="also search the game client's addressables catalog")
    ap.add_argument("--game-dir", default=DEFAULT_GAME_DIR)
    args = ap.parse_args()

    pat = re.compile(args.pattern, re.I)
    manifest = json.load(open(args.manifest))
    hits = [m for m in manifest["sprites"] if pat.search(m["path"])]
    print(f"extracted ({len(hits)}):")
    for m in sorted(hits, key=lambda m: m["path"]):
        print(f"  {m['path']}  {m['width']}x{m['height']}")
    if not hits:
        print("  (none)")

    if args.catalog:
        catalog_path = os.path.join(
            args.game_dir, "Contents/Resources/Data/StreamingAssets/aa/catalog.json"
        )
        containers = json.load(open(catalog_path))["m_InternalIds"]
        extracted = {m["container"] for m in manifest["sprites"]}
        missing = [
            c for c in containers
            if "/Sprites/" in c and pat.search(c) and c not in extracted
        ]
        print(f"\nin client but not extracted ({len(missing)}):")
        for c in sorted(missing)[:50]:
            print(f"  {c.split('_AddressedAssets/Sprites/')[-1]}")
        if len(missing) > 50:
            print(f"  … and {len(missing) - 50} more")


if __name__ == "__main__":
    main()
