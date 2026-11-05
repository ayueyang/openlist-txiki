#!/bin/sh
# 取 OpenList-Frontend 官方 dist asset（standard / lite），校验 sha256 后解开。
#
# 用法：sh <脚本所在目录>/fetch-frontend.sh standard|lite <dest-dir>
#       （脚本在 scripts/apk/ 与 scripts/ 两种布局下都可用）
# 产物：<dest-dir>/<asset 文件名>  与  <dest-dir>/dist/
# 版本钉死 v4.2.7（与 build-manifest.mjs 的 WEB_PINS 同一口径）；换版本要同时改两处。
set -eu

KIND=${1:?用法: fetch-frontend.sh standard|lite <dest-dir>}
DEST=${2:?用法: fetch-frontend.sh standard|lite <dest-dir>}
VER=v4.2.7

case "$KIND" in
	standard)
		NAME=openlist-frontend-dist-$VER.tar.gz
		WANT=88aba5260646ed784847a11e473880d749b17b80af53caf895fe1f31f36aa3e3
		;;
	lite)
		NAME=openlist-frontend-dist-lite-$VER.tar.gz
		WANT=6679861e3726305434f5de665a06880bd9a74aeab5ffc4c4150accef00e1c42d
		;;
	*)
		echo "FAIL: 只接受 standard 或 lite（现为 $KIND）" >&2
		exit 1
		;;
esac

URL="https://github.com/OpenListTeam/OpenList-Frontend/releases/download/$VER/$NAME"
mkdir -p "$DEST"
if [ ! -f "$DEST/$NAME" ]; then
	echo "GET $URL"
	curl -fL --retry 3 --max-time 600 -o "$DEST/$NAME.part" "$URL"
	mv "$DEST/$NAME.part" "$DEST/$NAME"
fi

GOT=$(sha256sum "$DEST/$NAME" | awk '{print $1}')
if [ "$GOT" != "$WANT" ]; then
	echo "FAIL: $NAME sha256=$GOT 与钉死值 $WANT 不符" >&2
	exit 1
fi
echo "OK $NAME sha256=$GOT bytes=$(wc -c < "$DEST/$NAME" | tr -d ' ')"

rm -rf "$DEST/dist"
mkdir -p "$DEST/dist"
tar -xzf "$DEST/$NAME" -C "$DEST/dist"
[ -f "$DEST/dist/index.html" ] || { echo "FAIL: 解开后没有 index.html" >&2; exit 1; }
echo "OK dist=$DEST/dist files=$(find "$DEST/dist" -type f | wc -l | tr -d ' ')"
