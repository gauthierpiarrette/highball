#!/bin/bash
# Builds cabextract (GPL-3.0-or-later, https://www.cabextract.org.uk) from its pinned source
# tarball for the app bundle. winetricks needs it to unpack Microsoft's cabinet installers,
# the core fonts among them, and macOS does not ship it (highball#96). Output: spike/tools/cabextract.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.11
SHA=b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6
URL="https://www.cabextract.org.uk/cabextract-$VERSION.tar.gz"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
curl -sSL -o "$WORK/src.tar.gz" "$URL"
echo "$SHA  $WORK/src.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$WORK/src.tar.gz" -C "$WORK"
cd "$WORK/cabextract-$VERSION"
./configure --prefix="$WORK/out" >/dev/null
make -j4 >/dev/null
cp cabextract "$OLDPWD/cabextract"
cd "$OLDPWD"
cp "$WORK/cabextract-$VERSION/COPYING" cabextract.LICENSE
ls -la cabextract | awk '{print $5, $9}'; ./cabextract --version | head -1
