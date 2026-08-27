#!/bin/bash
# 오마치 플러그인 설치/갱신: omarchy-plugin/ + core/ 를
# ~/.config/omarchy/plugins/ted.psu/ 로 복사 (심볼릭 링크 금지 정책 때문).
# 플러그인 폴더 저장 = 핫리로드이므로, 복사만 하면 바로 반영된다.
set -euo pipefail

repo="$(dirname "$(readlink -f "$0")")/.."
dest="$HOME/.config/omarchy/plugins/ted.psu"

rm -rf "$dest"
mkdir -p "$dest"
cp -r "$repo/omarchy-plugin/." "$dest/"
mkdir -p "$dest/core"
cp "$repo/core/"*.py "$dest/core/"
chmod +x "$dest/bin/psu"

echo "설치됨: $dest"
