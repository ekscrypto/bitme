# BitCraft client assets

Where the game's art lives on a local machine, what we extract from it, and
how to refresh. Tooling: [tools/asset-extraction](../tools/asset-extraction/)
(public). Extracted output: `bitme-resources/GameAssets/` — its own **private**
git repository ([github.com/ekscrypto/bitme-resources](https://github.com/ekscrypto/bitme-resources)),
nested inside the `bitme` checkout and gitignored there (not a submodule;
clone it next to the tooling on a fresh checkout).

## Source

The game is a Unity IL2CPP build installed by Steam at
`~/Library/Application Support/Steam/steamapps/common/BitCraft Online/BitCraft.app`.

Almost all content ships as Unity **Addressables** in a single local bundle:

```
Contents/Resources/Data/StreamingAssets/aa/StandaloneOSX/remoteassets_assets__<hash>.bundle
```

(1.4 GB at the 2026-09-27 build; `<hash>` changes with every game update.)

`StreamingAssets/aa/catalog.json` in the same tree indexes **10,643 named
assets** — the addressable container paths are the canonical names we match
against. The bundle holds 8,056 Texture2D, 5,319 Sprites, 7,531 meshes, and
the localization tables (see below). `StreamingAssets/Config/production.json`
also names a CDN for addressable updates, but it is not publicly readable
(403) — the Steam install is the practical source, refreshed by Steam itself.

Licensing context (2026-09): these assets are routinely extracted and
republished by community sites (BitJita, Brico's Toolbox); Clockwork Labs is
aware and has not issued takedowns, and the game is expected to be
open-sourced. Out of caution the extracted art is kept in the private
`bitme-resources` repo rather than this public one; revisit when the
open-sourcing lands and an actual license applies.

## What we extract

| Folder | Count | Source (container paths under `…/_AddressedAssets/Sprites/`) | Contents |
|---|---|---|---|
| `GameAssets/items` | 1,641 | `GeneratedIcons/Items/**` | material & item icons (ore, ingots, logs, tools, gear, food…) |
| `GameAssets/cargo` | 105 | `GeneratedIcons/Cargo/**` | cargo, animals, trophy fish |
| `GameAssets/cosmetics` | 1,493 | `GeneratedIcons/Other/**` | cosmetics, travelers, misc icons |
| `GameAssets/skills` | 19 | `Skill/SkillIcon*.png` | profession icons |
| `GameAssets/frames` | 52 | `UI/**` named `Frame_*`/`Fill_*` | tier/rarity frames and fills |

(All paths under `bitme-resources/`.) `OldGeneratedIcons` (869) are skipped —
superseded art.

### Professions (skills)

Alchemy, Artificing, Carpentry, Combat, Cooking, Exploration, Farming,
Fishing, Foraging, Forestry, Hunting, Leatherworking, Masonry, Mining,
Smithing, Survival, Tailoring, Trading (+ a generic "Any" icon), as
`GameAssets/skills/SkillIcon<Name>.png`.

### Tier & rarity palette

Sampled from the extracted `Fill_SQ_Tier*` and `Frame_SQ_BDG_*` art (the PNGs
are authoritative; these hexes are for code/UI styling):

| Tier fill | Hex | | Rarity badge | Hex |
|---|---|---|---|---|
| Tier 1 | `#788DA5` | | Common | `#53677C` |
| Tier 2 | `#008A64` | | Uncommon | `#855C51` |
| Tier 3 | `#1F579E` | | Rare | `#909FB9` |
| Tier 4 | `#521F9E` | | Epic | `#DAAE6A` |
| Tier 5 | `#E4891A` | | Legendary | `#3BA8D0` |
| Tier 6 | `#E01E50` | | Mythic | `#4B689E` |
| Untiered | `#3D526B` | | | |

Each frame/fill exists in square (`SQ`) and hex (`HX`) variants, plus
`Fill_Pointlight_Tier*` glow sprites. Note the UI tier ladder is 6 tiers;
item names go up to T10 (e.g. `Belt_Duelist_T10`) — higher-numbered gear
recycles the 6-step palette.

## Mapping to our data

Icon names are the game's CamelCase English identifiers (`CopperOre`,
`CrushedFerralithOre`, `AstraliteIngot`) — the same names the relay's item
data uses, so matching is by name. Item→tier/quality *assignments* are
server-side, not in the client; pair the icons with the relay's item tables.

The bundle's TextAssets hold the localization tables (27,848 strings each;
CSV with the English string in the `source` column) for de, es, fr, jp, pl,
pt-BR, ru, zh-Hans, zh-Hant — future source if the app needs localized item
names.

## Refresh after a game update

Steam rewrites the bundle; re-run the extractor and commit in
`bitme-resources`:

```sh
cd tools/asset-extraction
.venv/bin/python extract_assets.py   # writes bitme-resources/GameAssets/
```

After a game update, also re-verify schema-dependent assumptions per
[AGENTS.md](../AGENTS.md) (the client and the region DBs move together).
