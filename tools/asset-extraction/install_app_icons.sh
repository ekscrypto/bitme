#!/bin/sh
# Populate Crafter/Assets.xcassets with the game's profession icons, copied
# from the private bitme-resources checkout. The catalog is gitignored —
# game art stays out of the public repo — and the app falls back to SF
# Symbols whenever an icon is missing, so a public-only clone builds fine.
#
# Run after cloning (and after game updates refresh the extraction):
#     sh tools/asset-extraction/install_app_icons.sh

set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$REPO_ROOT/bitme-resources/GameAssets"
CATALOG="$REPO_ROOT/Crafter/Assets.xcassets"

if [ ! -d "$SRC/skills" ]; then
    echo "error: $SRC/skills not found — clone bitme-resources first (see tools/asset-extraction/README.md)" >&2
    exit 1
fi

mkdir -p "$CATALOG"
cat > "$CATALOG/Contents.json" <<'EOF'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# A catalog existing at all makes actool demand an AppIcon set — an empty
# single-size entry satisfies it (the app has no icon art of its own yet).
mkdir -p "$CATALOG/AppIcon.appiconset"
cat > "$CATALOG/AppIcon.appiconset/Contents.json" <<'EOF'
{
  "images" : [
    { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# Icon name -> source path under GameAssets. Scholar has no SkillIcon in the
# game's set; the UI's own Book icon stands in.
install_set() {
    name=$1; src=$2
    setdir="$CATALOG/$name.imageset"
    mkdir -p "$setdir"
    cp "$SRC/$src" "$setdir/$name.png"
    cat > "$setdir/Contents.json" <<EOF
{
  "images" : [
    { "idiom" : "universal", "filename" : "$name.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
}

install_set SkillIconCarpentry        "skills/SkillIconCarpentry.png"
install_set SkillIconFarming          "skills/SkillIconFarming.png"
install_set SkillIconFishing          "skills/SkillIconFishing.png"
install_set SkillIconForaging         "skills/SkillIconForaging.png"
install_set SkillIconForestry         "skills/SkillIconForestry.png"
install_set SkillIconHunting          "skills/SkillIconHunting.png"
install_set SkillIconLeatherworking   "skills/SkillIconLeatherworking.png"
install_set SkillIconMasonry          "skills/SkillIconMasonry.png"
install_set SkillIconMining           "skills/SkillIconMining.png"
install_set SkillIconSmithing         "skills/SkillIconSmithing.png"
install_set SkillIconTailoring        "skills/SkillIconTailoring.png"
install_set SkillIconScholar          "ui/UI/Book.png"

echo "installed 12 profession icons into $CATALOG"
echo "regenerate the Xcode project if it is open:  xcodegen generate"
