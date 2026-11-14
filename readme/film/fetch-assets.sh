#!/bin/bash
# Puts back the files that are not in git: the system font, the music and the sound effects.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p assets/fonts assets/audio assets/sfx
cp /System/Library/Fonts/SFNS.ttf assets/fonts/
# "Electro Dreams" by Arulo, Mixkit Stock Music Free License (no attribution required).
curl -fsSL -o assets/audio/electro-dreams.mp3 https://assets.mixkit.co/music/190/190.mp3
# Pixabay-licensed effects bundled with the HyperFrames media-use skill.
sfx="${HYPERFRAMES_SFX:-$HOME/.claude/skills/media-use/audio/assets/sfx}"
for f in click key-press pop whoosh impact-bass-1 impact-bass-2 riser error; do
  cp "$sfx/$f.mp3" assets/sfx/
done
echo "assets ready"
