#!/bin/sh
# openlist-txiki apk 打包脚本。
#
# 运行环境：有 apk-tools 3.0.x（带 mkpkg）的机器。本项目的实际做法是把
# Alpine edge 的 apk-tools-static 解包到设备 /tmp/apkstatic，在设备 /tmp 里打包：
#   wget -O /tmp/ats.apk https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/apk-tools-static-3.0.8-r0.apk
#   cd /tmp/apkstatic && apk extract --allow-untrusted /tmp/ats.apk   # 得到 sbin/apk.static
# 设备自带 apk-tools 3.0.5 没有 mkpkg 子命令（实测），所以必须用这个静态包。
#
# 用法（本地构建，apk-tools 3.0.x 带 mkpkg 的 Linux；默认值见下）：
#   STAGE=/tmp/p3-build/stage SCRIPTS=/tmp/p3-build/scripts \
#   OUT=/tmp/p3-build/openlist-txiki-<版本>.apk APK=/tmp/apkstatic/sbin/apk.static \
#   VERSION=<版本> sh scripts/apk/build-apk.sh
#
# STAGE 是解包后的文件树（只含包内 11 个文件）；SCRIPTS 是 5 个生命周期脚本所在目录。
# VERSION 必须显式给出，OUT 默认 /tmp/p3-build/openlist-txiki-$VERSION.apk：
# 直接重打不会再产出比线上低的包（2026-10-22 实测降级陷阱）。
set -eu

VERSION=${VERSION:?必须显式给出 VERSION（0.1.0 加 -r 序号）}
STAGE=${STAGE:-/tmp/p3-build/stage}
SCRIPTS=${SCRIPTS:-/tmp/p3-build/scripts}
OUT=${OUT:-/tmp/p3-build/openlist-txiki-$VERSION.apk}
APK=${APK:-/tmp/apkstatic/sbin/apk.static}

[ -x "$APK" ] || { echo "FAIL: $APK 不可执行（需要 apk-tools 3.0.x 的 mkpkg）" >&2; exit 1; }
[ -d "$STAGE" ] || { echo "FAIL: staging 目录不存在 $STAGE" >&2; exit 1; }
for s in pre-deinstall post-install pre-upgrade post-upgrade post-deinstall; do
	[ -f "$SCRIPTS/$s.sh" ] || { echo "FAIL: 缺少脚本 $SCRIPTS/$s.sh" >&2; exit 1; }
done

# S4 fail-closed：manifest 里的 package_version 必须等于本次包的 $VERSION，不等就中止。
# 历史事故：manifest 与 VERSION 不同步（只改 arch 没跟版本号），不拦就会带着旧版本号出门。
MANIFEST=$STAGE/usr/share/openlist-txiki/build-manifest.json
[ -f "$MANIFEST" ] || { echo "FAIL: 缺 $MANIFEST" >&2; exit 1; }
manifest_version=$(sed -n 's/.*"package_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)
if [ -z "$manifest_version" ]; then
	echo "FAIL: $MANIFEST 里读不到 package_version" >&2
	exit 1
fi
if [ "$manifest_version" != "$VERSION" ]; then
	echo "FAIL: manifest package_version=$manifest_version 与包版本 VERSION=$VERSION 不一致，拒绝打包" >&2
	exit 1
fi

# r29：固定文件 12 个（原 11 个 + 前端 MIT license）；其余文件只允许在 dist 下。
# 规则：固定名单逐个必须在；不在固定名单的，路径必须以 usr/share/openlist-txiki/dist/ 开头；
# dist 里必须有 index.html，且文件数等于 manifest 的 web_dist.file_count；多一个少一个都失败。
EXPECTED='etc/init.d/openlist-txiki
usr/libexec/openlist-txiki/openlist-txiki.js
usr/libexec/openlist-txiki/tjs
usr/share/openlist-txiki/LICENSE.AGPL-3.0
usr/share/openlist-txiki/LICENSE.Apache-2.0
usr/share/openlist-txiki/LICENSE.LGPL-3.0
usr/share/openlist-txiki/LICENSE.MIT
usr/share/openlist-txiki/licenses/LICENSE.MIT-OpenList-Frontend
usr/share/openlist-txiki/SOURCE-OFFER
usr/share/openlist-txiki/THIRD-PARTY-NOTICES
usr/share/openlist-txiki/build-manifest.json
usr/share/openlist-txiki/openlist-txiki.env.default'
DIST_PREFIX='usr/share/openlist-txiki/dist/'
GOT=$(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
printf '%s\n' "$EXPECTED" | sort > /tmp/expected.$$
printf '%s\n' "$GOT" > /tmp/got.$$
missing=$(comm -23 /tmp/expected.$$ /tmp/got.$$)
extra=$(comm -13 /tmp/expected.$$ /tmp/got.$$ | grep -v "^$DIST_PREFIX" || true)
rm -f /tmp/expected.$$ /tmp/got.$$
if [ -n "$missing" ] || [ -n "$extra" ]; then
	echo "FAIL: staging 文件集不符（缺固定文件或出现 dist 外的额外文件）" >&2
	echo "--- 缺 ---" >&2; printf '%s\n' "$missing" >&2
	echo "--- 多（不在固定名单且不在 dist 下）---" >&2; printf '%s\n' "$extra" >&2
	exit 1
fi
[ -f "$STAGE/usr/share/openlist-txiki/dist/index.html" ] || { echo "FAIL: dist 里没有 index.html" >&2; exit 1; }
want_dist_files=$(sed -n 's/.*"file_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MANIFEST" | tail -n 1)
got_dist_files=$(cd "$STAGE" && find "usr/share/openlist-txiki/dist" -type f | wc -l | tr -d ' ')
if [ -z "$want_dist_files" ] || [ "$got_dist_files" != "$want_dist_files" ]; then
	echo "FAIL: dist 文件数 $got_dist_files 与 manifest web_dist.file_count=${want_dist_files:-读不到} 不符" >&2
	exit 1
fi

# 权限位逐项固定（owner 必须 root:root；staging 由 Windows 侧打包上传时会带上
# MSYS 的 uid，mkpkg 会照抄成 nobody，所以这里强制归零，归零失败就中止）
chown -R 0:0 "$STAGE"
[ "$(ls -ln "$STAGE/usr/libexec/openlist-txiki/tjs" | awk '{print $3":"$4}')" = "0:0" ] || { echo "FAIL: chown 后 owner 不是 0:0" >&2; exit 1; }
chmod 755 "$STAGE/usr/libexec/openlist-txiki/tjs"
chmod 755 "$STAGE/etc/init.d/openlist-txiki"
chmod 644 "$STAGE/usr/libexec/openlist-txiki/openlist-txiki.js"
# 只对文件 chmod：r29 起 usr/share/openlist-txiki 下有 licenses/ 与 dist/ 两个子目录，
# 对目录 chmod 644 会去掉执行位，包内目录就进不去。
for f in "$STAGE"/usr/share/openlist-txiki/*; do [ -f "$f" ] && chmod 644 "$f"; done
if [ -d "$STAGE/usr/share/openlist-txiki/licenses" ]; then
	find "$STAGE/usr/share/openlist-txiki/licenses" -type f -exec chmod 644 {} \;
fi
if [ -d "$STAGE/usr/share/openlist-txiki/dist" ]; then
	find "$STAGE/usr/share/openlist-txiki/dist" -type f -exec chmod 644 {} \;
fi
# 目录权限固定 0755：Windows/MSYS 拷进来的目录常是 0777，mkpkg 会照抄进包
# （本轮负向对照实测：0777 staging 用旧脚本打出来的包内目录就是 0777，见
# artifacts/p4-apk-r7-*/README.md）。chmod 后回读，任何目录不是 0755 就中止。
find "$STAGE" -type d -exec chmod 755 {} \;
find "$STAGE" -type d -exec chown 0:0 {} \;
bad_dirs=$(find "$STAGE" -type d ! -perm 755)
[ -z "$bad_dirs" ] || { echo "FAIL: 目录权限不是 0755:" >&2; echo "$bad_dirs" >&2; exit 1; }

rm -f "$OUT"
# r29：installed-size 记录。历史口径是「包内所有文件字节和」（r15 已核）；这里先现算，
# 打包后再从 adbdump 读实际值比对，不等就说明 staging 与包内文件集不一致。
STAGE_BYTES=$(find "$STAGE" -type f -printf '%s\n' | awk '{s+=$1} END{print s}')
echo "STAGE_BYTES=$STAGE_BYTES"
"$APK" mkpkg --compat 3.0.0_pre1 \
	-I "name:openlist-txiki" \
	-I "version:$VERSION" \
	-I "description:OpenList Worker on txiki.js (WebDAV/HTTP file gateway)" \
	-I "arch:aarch64_cortex-a53" \
	-I "license:AGPL-3.0-only AND LGPL-3.0-or-later AND MIT AND Apache-2.0" \
	-I "origin:openlist-txiki" \
	-I "maintainer:openlist-txiki maintainers" \
	--files "$STAGE" \
	-s "pre-deinstall:$SCRIPTS/pre-deinstall.sh" \
	-s "post-install:$SCRIPTS/post-install.sh" \
	-s "pre-upgrade:$SCRIPTS/pre-upgrade.sh" \
	-s "post-upgrade:$SCRIPTS/post-upgrade.sh" \
	-s "post-deinstall:$SCRIPTS/post-deinstall.sh" \
	-o "$OUT"

echo "APK=$OUT"
echo "BYTES=$(wc -c < "$OUT" | tr -d ' ')"
echo "SHA256=$(sha256sum "$OUT" | cut -d' ' -f1)"
# r29：dist tree 现算，与 manifest 的 web_dist.tree_sha256 比对（算法与 CRITERIA G3 一致）。
if [ -d "$STAGE/usr/share/openlist-txiki/dist" ]; then
	DIST_TREE=$(cd "$STAGE/usr/share/openlist-txiki/dist" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | \
		while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done | \
		sha256sum | awk '{print $1}')
	WANT_TREE=$(sed -n 's/.*"tree_sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" | head -n 1)
	echo "DIST_TREE=$DIST_TREE"
	echo "DIST_TREE_WANT=$WANT_TREE"
	[ "$DIST_TREE" = "$WANT_TREE" ] || { echo "FAIL: dist tree 与 manifest 不符" >&2; exit 1; }
fi
echo "--- adbdump（前 40 行）---"
ADB=$("$APK" adbdump "$OUT" 2>/dev/null || apk adbdump "$OUT" 2>/dev/null || true)
printf '%s\n' "$ADB" | head -40
ISIZE=$(printf '%s\n' "$ADB" | sed -n 's/.*installed-size:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
echo "INSTALLED_SIZE=${ISIZE:-unread}"
echo "STAGE_BYTES=$STAGE_BYTES"
if [ -n "${ISIZE:-}" ]; then
	[ "$ISIZE" = "$STAGE_BYTES" ] || echo "WARN: adbdump installed-size=$ISIZE 与 staging 字节和 $STAGE_BYTES 不等"
fi
