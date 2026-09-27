# BitCraft client asset extraction

Pulls icons and UI art out of the local Steam install of BitCraft into
`bitme-resources/GameAssets/` — the private assets repo
(github.com/ekscrypto/bitme-resources) nested inside the `bitme` checkout and
gitignored there. Full background: see
[docs/client-assets.md](../../docs/client-assets.md).

## Setup & run

```sh
cd tools/asset-extraction
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python extract_assets.py            # default game dir + assets repo
.venv/bin/python extract_assets.py --also-ui  # additionally dump full UI set
```

First checkout: `git clone git@github.com:ekscrypto/bitme-resources.git
bitme-resources` inside the `bitme` repo root.

## Notes

- The script locates the bundle by glob (`remoteassets_assets__*.bundle`), so it
  keeps working after Steam updates rewrite the hash in the filename. Re-run
  after every game update and commit in `bitme-resources` like any other data
  refresh.
- `GameAssets/manifest.json` records every extracted file's source container
  path and pixel size (traceability, and the collision-free subpaths come from
  the same container paths).
- `OldGeneratedIcons` are skipped on purpose (superseded art).
- The bundle also contains the game's localization tables as TextAssets
  (`de`, `fr`, `es`, `jp`, `pl`, `pt-BR`, `ru`, `zh-Hans`, `zh-Hant`; CSV with
  the English string in the `source` column). The script doesn't dump them;
  grab them with a small UnityPy pass if i18n ever needs them.
