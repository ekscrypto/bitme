#!/usr/bin/env python3
"""Extract BitCraft client art from the local Steam install into the private
bitme-resources repo (nested at <repo>/bitme-resources, gitignored there).

The client ships its content as Unity Addressables; everything we need sits in
one local bundle (see docs/client-assets.md for the full map). This script
categorises sprites by their addressable container path and writes PNGs plus
a manifest. Re-run after every game update — Steam rewrites the bundle (the
hash in its filename changes) and the icon set with it.

Categories (output subfolders of --out):
  items/     GeneratedIcons/Items/**        material & item icons
  cargo/     GeneratedIcons/Cargo/**        cargo, animals, trophies
  cosmetics/ GeneratedIcons/Other/**        cosmetics, travelers, misc icons
  skills/    Sprites/Skill/SkillIcon*.png   profession icons
  frames/    Sprites/UI/** Frame_*/Fill_*    tier/rarity frames and fills
  ui/        Sprites/UI/** + Randy UI/**    (only with --also-ui)

Usage:
    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt
    .venv/bin/python extract_assets.py [--game-dir PATH] [--out PATH] [--also-ui]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

import UnityPy

DEFAULT_GAME_DIR = os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/BitCraft Online/BitCraft.app"
)

SPRITES_ANCHOR = "Assets/_Project/StaticAssets/_AddressedAssets/Sprites/"
FRAME_NAME = re.compile(r"^(Frame|Fill)_")


def find_bundle(game_dir: str) -> str:
    pattern = os.path.join(
        game_dir,
        "Contents/Resources/Data/StreamingAssets/aa/StandaloneOSX",
        "remoteassets_assets__*.bundle",
    )
    candidates = glob.glob(pattern)
    if not candidates:
        sys.exit(f"no remoteassets bundle under {game_dir} — is BitCraft installed via Steam?")
    return max(candidates, key=os.path.getsize)


def categorise(container: str, also_ui: bool):
    """Map a container path to (output dir, relative subpath) or None."""
    if not container.startswith(SPRITES_ANCHOR):
        return None
    rel = container[len(SPRITES_ANCHOR):]
    if rel.endswith(".png"):
        rel = rel[: -len(".png")]
    if rel.startswith("OldGeneratedIcons/"):
        return None  # superseded art, kept out of the extraction
    if rel.startswith("GeneratedIcons/"):
        sub = rel[len("GeneratedIcons/"):]
        if sub.startswith("Items/"):
            return "items", sub[len("Items/"):]
        if sub.startswith("Cargo/"):
            return "cargo", sub[len("Cargo/"):]
        return "cosmetics", sub[len("Other/"):] if sub.startswith("Other/") else sub
    name = rel.rsplit("/", 1)[-1]
    if rel.startswith("Skill/") and name.startswith("SkillIcon"):
        return "skills", name
    if rel.startswith("UI/") and FRAME_NAME.match(name):
        return "frames", name
    if also_ui and (rel.startswith("UI/") or rel.startswith("Randy UI/")):
        return "ui", rel
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--game-dir", default=DEFAULT_GAME_DIR, help="BitCraft.app bundle")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "bitme-resources", "GameAssets"),
                    help="output directory (default: <repo>/bitme-resources/GameAssets — the private assets repo)")
    ap.add_argument("--also-ui", action="store_true",
                    help="also dump the full UI sprite set (~800 sprites)")
    args = ap.parse_args()

    bundle = find_bundle(args.game_dir)
    out_root = os.path.abspath(args.out)
    print(f"bundle: {bundle}")
    print(f"out:    {out_root}")

    env = UnityPy.load(bundle)
    manifest, failed = [], []
    for obj in env.objects:
        if obj.type.name != "Sprite":
            continue
        container = getattr(obj, "container", None)
        if not container:
            continue
        cat = categorise(container, args.also_ui)
        if not cat:
            continue
        dest_dir, rel = cat
        try:
            sprite = obj.read()
            img = sprite.image
        except Exception as e:  # unreadable sprite — surface it, keep going
            failed.append({"container": container, "error": str(e)})
            continue
        out_path = os.path.join(out_root, dest_dir, rel + ".png")
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        img.save(out_path)
        manifest.append(
            {"path": os.path.relpath(out_path, out_root), "container": container,
             "width": img.width, "height": img.height}
        )

    os.makedirs(out_root, exist_ok=True)
    with open(os.path.join(out_root, "manifest.json"), "w") as f:
        json.dump({"bundle": os.path.basename(bundle), "sprites": manifest,
                   "failed": failed}, f, indent=1, sort_keys=True)

    per_dir = {}
    for m in manifest:
        per_dir[m["path"].split("/")[0]] = per_dir.get(m["path"].split("/")[0], 0) + 1
    for d in sorted(per_dir):
        print(f"  {d:10} {per_dir[d]:5} sprites")
    print(f"total: {len(manifest)} sprites, {len(failed)} failed (see manifest.json)")


if __name__ == "__main__":
    main()
