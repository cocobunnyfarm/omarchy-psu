#!/bin/bash
# 오마치 플러그인 설치/갱신 (로컬 개발용).
# repo 루트 = 플러그인 루트이므로 런타임 파일만 플러그인 폴더로 복사한다.
# (심볼릭 링크는 오마치가 거부. 배포는 `omarchy plugin add <git-url>`이 담당)
# 플러그인 폴더 저장 = 핫리로드이므로, 복사만 하면 바로 반영된다.
set -euo pipefail

repo="$(dirname "$(readlink -f "$0")")/.."
dest="$HOME/.config/omarchy/plugins/io.github.cocobunnyfarm.psu"

rm -rf "$dest"
mkdir -p "$dest"
cp "$repo/manifest.json" "$repo/Widget.qml" "$dest/"
cp -r "$repo/bin" "$repo/core" "$dest/"
rm -rf "$dest/core/__pycache__"
chmod +x "$dest/bin/psu"

echo "설치됨: $dest"
