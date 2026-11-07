#!/bin/sh
# openlist-txiki apk 打包脚本。
#
# 运行环境：钉死镜像 alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000
# （2026-11-02 现测 apk-tools 3.0.7-r0, compiled for x86_64；容器内直接用 /sbin/apk）。
# 出包与解包校验固定 apk-tools 3.0.7-r0；3.0.8 的 extract 在带根级硬链接的树上 rc=1、9 件只落 5 件。
# 3.0.7-r0 的静态包在 Alpine edge 已下架（2026-11-02 现测 404），所以用上面的容器，不下载静态包。
# 设备精简 BusyBox 缺 comm/stat/find -printf，不支持就地重打（r30 preflight 直接拒跑）；
# 设备自带 apk-tools 3.0.5 没有 mkpkg 子命令（实测），所以必须在容器里打。
#
# 用法（钉死镜像内，默认值见下）：
#   STAGE=/tmp/p3-build/stage SCRIPTS=/tmp/p3-build/scripts \
#   OUT=/tmp/p3-build/openlist-txiki-<版本>.apk \
#   VERSION=<版本> sh scripts/apk/build-apk.sh
# APK 默认 /sbin/apk（就是钉死镜像里 apk-tools 3.0.7-r0 自带的那份），容器内不用显式给。
#
# mtime 归一（r423）：包内 mtime 取 SOURCE_DATE_EPOCH（纯数字非空）或 build-manifest.json
# 的 build_date（YYYY-MM-DD，按 UTC 零点换算）；两者都缺直接失败退出。NORMALIZE_MTIME=0
# 跳过归一（输出带 NORMALIZE_MTIME=0），其它值只接受 1。
# STAGE 是解包后的文件树（只含包内 11 个文件）；SCRIPTS 是 5 个生命周期脚本所在目录。
# VERSION 必须显式给出，OUT 默认 /tmp/p3-build/openlist-txiki-$VERSION.apk：
# 直接重打不会再产出比线上低的包（2026-10-22 实测降级陷阱）。
set -eu

VERSION=${VERSION:?必须显式给出 VERSION（0.1.0 加 -r 序号）}
STAGE=${STAGE:-/tmp/p3-build/stage}
SCRIPTS=${SCRIPTS:-/tmp/p3-build/scripts}
OUT=${OUT:-/tmp/p3-build/openlist-txiki-$VERSION.apk}
APK=${APK:-/sbin/apk}
# shared-tjs 变体（r34）：包内不放 tjs，init 调 /usr/bin/tjs，apk 依赖系统 txiki-js。
# 默认 0 = 现在的自带版，行为与旧脚本逐字节一致（除了新增的 OFFER_VERSION 变量）。
SHARED_TJS=${SHARED_TJS:-0}
case "$SHARED_TJS" in
	0|1) : ;;
	*) echo "FAIL: SHARED_TJS 只接受 0 或 1（现为 $SHARED_TJS）" >&2; exit 1 ;;
esac
TJS_MIN_VERSION=${TJS_MIN_VERSION:-26.9.0}
# A2：字节码独立二进制。默认 0（与 A2 之前逐字节同形）；1 时包内必须有
# openlist-txiki-bin / launch-bytecode.sh / bytecode-identity.txt，固定文件清单随之增加。
BYTECODE=${BYTECODE:-0}
case "$BYTECODE" in
	0|1) : ;;
	*) echo "FAIL: BYTECODE 只接受 0 或 1（现为 $BYTECODE）" >&2; exit 1 ;;
esac
if [ "$SHARED_TJS" = 1 ] && [ "$BYTECODE" = 1 ]; then
	echo "FAIL: SHARED_TJS=1 与 BYTECODE=1 不能同时成立（字节码包自带 tjs 作回退）" >&2
	exit 1
fi

# r30 C6：设备精简 BusyBox 缺 comm/stat，早失败早说清楚（不做 BusyBox 兼容层）。
command -v comm >/dev/null 2>&1 && command -v stat >/dev/null 2>&1 || {
  echo "FAIL: 需要 comm 与 stat（GNU coreutils 或 alpine BusyBox）。设备精简 BusyBox 不支持，请在容器里构建" >&2
  exit 1
}

[ -x "$APK" ] || { echo "FAIL: $APK 不可执行。出包要在钉死镜像 alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000 里跑，容器内直接用 /sbin/apk（apk-tools 3.0.7-r0）；完整步骤见仓库根 REBUILD.md「打 apk：钉死镜像与 apk-tools 口径」" >&2; exit 1; }
# B7：apk --version 进构建日志；不是 3.0.7-r0 只 WARN 不 exit（别在别人机器上直接卡死）。
apk_version_line=$("$APK" --version 2>&1 || true)
echo "apk --version: $apk_version_line"
case "$apk_version_line" in
	*"apk-tools 3.0.7-r0"*) : ;;
	*) echo "WARN: apk-tools 不是 3.0.7-r0（实测：${apk_version_line:-读不到}）；r30 字节身份只在 3.0.7-r0 上验证过，出包前请核对" >&2 ;;
esac
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

# S4b fail-closed：自带 tjs 变体（BYTECODE=1）包内的 bytecode-identity.txt 必须记录本次包版本。
# 历史缺口（r47 backlog 1，CA-78 裁决 2）：EXPECTED 名单只查这个文件在不在，不查 package_version
# 内容，把旧 stage 的 identity 带进新包也放行。
# 四条任一不符即中止：① 存在且非空；② 能取到 package_version 行；③ 整串等于 $VERSION
# （不用 grep 子串或正则：VERSION=0.1.0-r4 会命中 0.1.0-r46）；④ 报错同时打出实际值与期望值，
# 并回显该行 od -c 前 120 字节（区分 CRLF、尾部空格这类不可见差异）。
if [ "$BYTECODE" = 1 ]; then
	IDENT=$STAGE/usr/share/openlist-txiki/bytecode-identity.txt
	if [ ! -f "$IDENT" ] || [ ! -s "$IDENT" ]; then
		echo "FAIL: BYTECODE=1 但包内缺 bytecode-identity.txt 或文件为空：$IDENT（期望 package_version=$VERSION）" >&2
		exit 1
	fi
	# r48 B4：按字段解析，不再只取第一行。多行/重复 package_version 一律拒绝，避免第二行旧值被静默放行。
	ident_count=$(grep -c '^package_version=' "$IDENT" || true)
	if [ "${ident_count:-0}" -eq 0 ]; then
		echo "FAIL: $IDENT 里读不到 package_version 行（实际：无该行；期望：package_version=$VERSION）" >&2
		exit 1
	fi
	if [ "$ident_count" -ne 1 ]; then
		echo "FAIL: $IDENT 里有 $ident_count 行 package_version（期望恰好 1 行，多行会掩盖旧值）" >&2
		grep -n '^package_version=' "$IDENT" >&2 || true
		exit 1
	fi
	ident_version=$(sed -n 's/^package_version=//p' "$IDENT")
	if [ "$ident_version" != "$VERSION" ]; then
		echo "FAIL: bytecode-identity.txt 的 package_version=$ident_version 与包版本 VERSION=$VERSION 不完全相等，拒绝打包（实际：$ident_version；期望：$VERSION）" >&2
		ident_line=$(sed -n '/^package_version=/p' "$IDENT" | head -n 1)
		printf '%s\n' "$ident_line" | head -c 120 | od -c >&2 || true
		exit 1
	fi
fi

# S5 fail-closed：包内 THIRD-PARTY-NOTICES 内容门（r46-01，CA-77 方案 A）。
# 历史事故：r44、r45 连续两版把 lite 档的四值写进全部四件发布物（含装 standard 前端的
# linux/win 两件），构建链只查这个文件在不在（EXPECTED 名单），不查正文，所以没人拦。
# 四条任一不符即中止，报错打出实际命中行：
#   ① 存在且非空；② 版本串整串命中；③ 无 @@ 残留；④ 无单档断言且档名与本包 manifest 一致。
# ② 的锚串末尾带「（」：版本行格式固定为「本声明对应包版本：<版本>（与包内…」，
# 不带尾锚时 VERSION=0.1.0-r4 会子串命中模板里的 0.1.0-r46，正是 r446 D1 那类漏放。
TPN=$STAGE/usr/share/openlist-txiki/THIRD-PARTY-NOTICES
if [ ! -f "$TPN" ] || [ ! -s "$TPN" ]; then
	echo "FAIL: 包内缺 THIRD-PARTY-NOTICES 或为空：$TPN" >&2
	exit 1
fi
if ! grep -Fq "本声明对应包版本：$VERSION（" "$TPN"; then
	echo "FAIL: THIRD-PARTY-NOTICES 缺少整串「本声明对应包版本：$VERSION（」；实际版本行：" >&2
	grep -n '本声明对应包版本' "$TPN" >&2 || echo "  （文件里没有版本行）" >&2
	exit 1
fi
if grep -Fq '@@' "$TPN"; then
	echo "FAIL: THIRD-PARTY-NOTICES 含未渲染占位符 @@；命中行：" >&2
	grep -nF '@@' "$TPN" >&2
	exit 1
fi
if grep -Fq '本包包含 OpenListTeam/OpenList-Frontend 的官方发布件' "$TPN"; then
	echo "FAIL: THIRD-PARTY-NOTICES 仍有单档断言（本包包含…的官方发布件）；命中行：" >&2
	grep -nF '本包包含 OpenListTeam/OpenList-Frontend 的官方发布件' "$TPN" >&2
	exit 1
fi
if grep -Fq 'openlist-frontend-dist' "$TPN"; then
	web_dist_archive=$(sed -n '/"web_dist"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/s/.*"archive"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)
	if [ -z "$web_dist_archive" ]; then
		echo "FAIL: 从 $MANIFEST 读不到 web_dist.archive，无法核对 THIRD-PARTY-NOTICES 的档名" >&2
		exit 1
	fi
	if ! grep -Fq "$web_dist_archive" "$TPN"; then
		echo "FAIL: THIRD-PARTY-NOTICES 提到 openlist-frontend-dist，但不含本包 manifest 的 web_dist.archive=$web_dist_archive" >&2
		grep -nF 'openlist-frontend-dist' "$TPN" >&2
		exit 1
	fi
fi

# B5 fail-closed：包内 SOURCE-OFFER 是把 SOURCE-OFFER.in 渲染进 stage 的成品，本脚本既不渲染也不改写它，
# 所以这里逐条核对它确实是本次 $VERSION 的成品。三条任一不满足就中止，不带着旧版本或未替换占位符出门。
# 历史事故：工作树里另有一份未渲染的 0.1.0-r28 残留，与包内成品并存，肉眼看不出。
# r446 D1：两条版本断言从子串匹配改成精确相等。子串会让 VERSION=0.1.0-r3 命中 0.1.0-r30，
# 旧版本号打新模板会被放过；现在版本串必须整串相等。
# shared-tjs 变体：包内 SOURCE-OFFER 仍指向同一个源码归档（本包按 0.1.0-r33 源码重打），
# 版本串必须由调用方显式给 OFFER_VERSION，脚本不猜；自带版 OFFER_VERSION 等于 VERSION。
# A2 起：任何变体都允许显式给 OFFER_VERSION（源码归档版本与包版本解耦；A2 实验包
# 的 bundle 与 r40 逐字节相同，源码归档只能指向真实的 0.1.0-r40 归档）。
if [ -n "${OFFER_VERSION:-}" ]; then
	: # 调用方显式给，下面照用
elif [ "$SHARED_TJS" = 1 ]; then
	echo "FAIL: shared 变体必须显式给 OFFER_VERSION（本包对应的源码归档版本，如 0.1.0-r33）" >&2
	exit 1
else
	OFFER_VERSION=$VERSION
fi
# S4c fail-closed：自带 tjs 变体（SHARED_TJS=0）的源码归档版本必须等于包版本。
# 历史缺口（r47 backlog 1，CA-78 裁决 2）：OFFER_VERSION 可被调用方显式覆盖，自带版能打出
# 「bundle 复用旧源码、offer 指向旧归档」的实验包（A2 就是这种形态）。
# shared 变体不受此限，仍按 B5 与其自身 OFFER_VERSION 整串相等。
# 出路：确实要指向旧归档的实验包，改用 shared 变体（SHARED_TJS=1）或另立显式实验开关；
# 本门不提供旁路。
if [ "$SHARED_TJS" = 0 ] && [ "$OFFER_VERSION" != "$VERSION" ]; then
	echo "FAIL: 自带 tjs 变体的源码归档版本必须等于包版本（OFFER_VERSION=$OFFER_VERSION，VERSION=$VERSION）；确实要指向旧归档的实验包，改用 shared 变体或另立显式实验开关，不许绕过本门" >&2
	exit 1
fi
OFFER=$STAGE/usr/share/openlist-txiki/SOURCE-OFFER
[ -f "$OFFER" ] || { echo "FAIL: 缺 $OFFER" >&2; exit 1; }
offer_ver_line=$(grep '^包名与版本：' "$OFFER" | head -n 1)
if [ -z "$offer_ver_line" ]; then
	echo "FAIL: 判据=版本行：$OFFER 里找不到「包名与版本：」行，无法核对版本（期望完全等于 OFFER_VERSION=$OFFER_VERSION）" >&2
	exit 1
fi
# 判据=版本行：取「包名与版本：」行的包名 openlist-txiki 之后、「（」之前的版本串，必须与 $OFFER_VERSION 整串相等。
offer_rest=${offer_ver_line#*包名与版本：}
case "$offer_rest" in
	"openlist-txiki "*)
		offer_tail=${offer_rest#openlist-txiki }
		case "$offer_tail" in
			*"（"*) offer_ver=${offer_tail%%（*} ;;
			*) echo "FAIL: 判据=版本行：版本行里 openlist-txiki 之后找不到「（」分隔，取不出版本串（期望 OFFER_VERSION=$OFFER_VERSION；原文：$offer_ver_line）" >&2; exit 1 ;;
		esac
		;;
	*)
		echo "FAIL: 判据=版本行：版本行里「包名与版本：」之后不是 openlist-txiki 开头，取不出版本串（期望 OFFER_VERSION=$OFFER_VERSION；原文：$offer_ver_line）" >&2
		exit 1
		;;
esac
if [ "$offer_ver" != "$OFFER_VERSION" ]; then
	echo "FAIL: 判据=版本行：SOURCE-OFFER 版本串=$offer_ver 与 OFFER_VERSION=$OFFER_VERSION 不完全相等（原文：$offer_ver_line）" >&2
	exit 1
fi
offer_url_line=$(grep '下载地址：' "$OFFER" | head -n 1)
if [ -z "$offer_url_line" ]; then
	echo "FAIL: 判据=下载地址：$OFFER 里找不到「下载地址：」行，无法核对源码归档地址（期望版本段 v$OFFER_VERSION）" >&2
	exit 1
fi
# 判据=下载地址：取 URL 里 /releases/download/ 之后、下一个 / 之前的路径段，必须与 v$OFFER_VERSION 整串相等。
case "$offer_url_line" in
	*"/releases/download/"*)
		offer_tag=${offer_url_line#*/releases/download/}
		offer_tag=${offer_tag%%/*}
		;;
	*)
		echo "FAIL: 判据=下载地址：下载地址行里没有 /releases/download/ 路径，取不出版本段（期望 v$OFFER_VERSION；原文：$offer_url_line）" >&2
		exit 1
		;;
esac
if [ "$offer_tag" != "v$OFFER_VERSION" ]; then
	echo "FAIL: 判据=下载地址：SOURCE-OFFER 下载地址版本段=$offer_tag 与 v$OFFER_VERSION 不完全相等（原文：$offer_url_line）" >&2
	exit 1
fi
if grep -q '@@' "$OFFER"; then
	echo "FAIL: 判据=占位符：SOURCE-OFFER 仍有未渲染占位符（含 @@），.in 模板没替换干净（期望 VERSION=$VERSION 的成品）：" >&2
	grep -n '@@' "$OFFER" | head -n 5 >&2
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
if [ "$SHARED_TJS" = 1 ]; then
	EXPECTED=$(printf '%s\n' "$EXPECTED" | grep -v '^usr/libexec/openlist-txiki/tjs$')
fi
if [ "$BYTECODE" = 1 ]; then
	EXPECTED=$(printf '%s\n%s\n%s\n%s\n' "$EXPECTED" \
		'usr/libexec/openlist-txiki/openlist-txiki-bin' \
		'usr/libexec/openlist-txiki/launch-bytecode.sh' \
		'usr/share/openlist-txiki/bytecode-identity.txt')
fi
DIST_PREFIX='usr/share/openlist-txiki/dist/'
CHUNK_PREFIX='usr/libexec/openlist-txiki/chunks/'
# r40 驱动拆分：包内 chunks/ 只允许 manifest 里登记的那些 .js；数量由 CHUNK_COUNT 传入。
CHUNK_COUNT=${CHUNK_COUNT:-0}
case "$CHUNK_COUNT" in
	''|*[!0-9]*) echo "FAIL: CHUNK_COUNT 必须是非负整数（现为 $CHUNK_COUNT）" >&2; exit 1 ;;
esac
GOT=$(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
# r30 C5：失败路径清理。中间任一步非零退出（如 comm 缺失 rc=127）都不留 /tmp 残留文件。
trap 'rm -f /tmp/expected.$$ /tmp/got.$$' EXIT INT TERM HUP
printf '%s\n' "$EXPECTED" | sort > /tmp/expected.$$
printf '%s\n' "$GOT" > /tmp/got.$$
missing=$(comm -23 /tmp/expected.$$ /tmp/got.$$)
extra=$(comm -13 /tmp/expected.$$ /tmp/got.$$ | grep -v "^$DIST_PREFIX" | grep -v "^$CHUNK_PREFIX" || true)
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
# r40：chunks 数量必须与传入的 CHUNK_COUNT 一致；目录里只允许 .js，且不能为空目录残留。
got_chunks=$(cd "$STAGE" && find usr/libexec/openlist-txiki/chunks -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$got_chunks" != "$CHUNK_COUNT" ]; then
	echo "FAIL: chunks 文件数 $got_chunks 与 CHUNK_COUNT=$CHUNK_COUNT 不符" >&2
	exit 1
fi
if [ "$CHUNK_COUNT" -gt 0 ]; then
	bad_chunk=$(cd "$STAGE" && find usr/libexec/openlist-txiki/chunks -type f ! -name '*.js' | head -n 1)
	[ -z "$bad_chunk" ] || { echo "FAIL: chunks 目录里有非 .js 文件：$bad_chunk" >&2; exit 1; }
fi

# 权限位逐项固定（owner 必须 root:root；staging 由 Windows 侧打包上传时会带上
# MSYS 的 uid，mkpkg 会照抄成 nobody，所以这里强制归零，归零失败就中止）
chown -R 0:0 "$STAGE"
if [ "$SHARED_TJS" = 1 ]; then
	[ ! -e "$STAGE/usr/libexec/openlist-txiki/tjs" ] || { echo "FAIL: shared 变体 stage 里不应有 tjs" >&2; exit 1; }
else
	[ "$(ls -ln "$STAGE/usr/libexec/openlist-txiki/tjs" | awk '{print $3":"$4}')" = "0:0" ] || { echo "FAIL: chown 后 owner 不是 0:0" >&2; exit 1; }
	chmod 755 "$STAGE/usr/libexec/openlist-txiki/tjs"
fi
chmod 755 "$STAGE/etc/init.d/openlist-txiki"
chmod 644 "$STAGE/usr/libexec/openlist-txiki/openlist-txiki.js"
if [ "$BYTECODE" = 1 ]; then
	chmod 755 "$STAGE/usr/libexec/openlist-txiki/openlist-txiki-bin"
	chmod 755 "$STAGE/usr/libexec/openlist-txiki/launch-bytecode.sh"
fi
# 只对文件 chmod：r29 起 usr/share/openlist-txiki 下有 licenses/ 与 dist/ 两个子目录，
# 对目录 chmod 644 会去掉执行位，包内目录就进不去。
for f in "$STAGE"/usr/share/openlist-txiki/*; do [ -f "$f" ] && chmod 644 "$f"; done
if [ -d "$STAGE/usr/share/openlist-txiki/licenses" ]; then
	find "$STAGE/usr/share/openlist-txiki/licenses" -type f -exec chmod 644 {} \;
fi
if [ -d "$STAGE/usr/share/openlist-txiki/dist" ]; then
	find "$STAGE/usr/share/openlist-txiki/dist" -type f -exec chmod 644 {} \;
fi
# r40：拆分后的 chunk 是只读数据文件，权限固定 644。
if [ -d "$STAGE/usr/libexec/openlist-txiki/chunks" ]; then
	find "$STAGE/usr/libexec/openlist-txiki/chunks" -type f -exec chmod 644 {} \;
fi
# 目录权限固定 0755：Windows/MSYS 拷进来的目录常是 0777，mkpkg 会照抄进包
# （本轮负向对照实测：0777 staging 用旧脚本打出来的包内目录就是 0777，见
# artifacts/p4-apk-r7-*/README.md）。chmod 后回读，任何目录不是 0755 就中止。
find "$STAGE" -type d -exec chmod 755 {} \;
find "$STAGE" -type d -exec chown 0:0 {} \;
bad_dirs=$(find "$STAGE" -type d ! -perm 755)
[ -z "$bad_dirs" ] || { echo "FAIL: 目录权限不是 0755:" >&2; echo "$bad_dirs" >&2; exit 1; }

# r423 C2：mtime 归一（依据 work/architect-mtime-dec-2206/DECISION.md，commit 2bbb7f4f）。
# 目的：同一 staging 内容换时间打包，apk 字节会因包内 mtime 不同而不同；这里把 mtime 钉死。
# 取值优先级：SOURCE_DATE_EPOCH（纯数字、非空）> manifest 的 build_date（YYYY-MM-DD，UTC 零点）。
# 两者都缺就失败退出，不回退到「现在」。NORMALIZE_MTIME=0 跳过归一（输出带 NORMALIZE_MTIME=0），
# NORMALIZE_MTIME 空等同 1，其它值失败退出。归一后逐条回读，任何一条不等就失败退出。
NORMALIZE_MTIME=${NORMALIZE_MTIME:-1}
case "$NORMALIZE_MTIME" in
	0)
		echo "NORMALIZE_MTIME=0：跳过 mtime 归一（SOURCE_DATE_EPOCH/build_date 均不读取）"
		;;
	1)
		if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
			case "$SOURCE_DATE_EPOCH" in
				*[!0-9]*) echo "FAIL: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH 不是纯数字" >&2; exit 1 ;;
			esac
			MTIME_EPOCH=$SOURCE_DATE_EPOCH
			MTIME_SRC="SOURCE_DATE_EPOCH"
		else
			mtime_build_date=$(sed -n 's/.*"build_date"[[:space:]]*:[[:space:]]*"\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)".*/\1/p' "$MANIFEST" | head -n 1)
			[ -n "$mtime_build_date" ] || { echo "FAIL: 没有 SOURCE_DATE_EPOCH，$MANIFEST 里也没有 build_date（YYYY-MM-DD），拒绝打包" >&2; exit 1; }
			if ! MTIME_EPOCH=$(date -u -d "$mtime_build_date 00:00:00" +%s 2>/dev/null); then
				echo "FAIL: build_date=$mtime_build_date 换算 UTC epoch 失败" >&2
				exit 1
			fi
			MTIME_SRC="manifest build_date=$mtime_build_date"
		fi
		case "$MTIME_EPOCH" in
			''|*[!0-9]*) echo "FAIL: mtime epoch 不是纯数字：$MTIME_EPOCH（来源 $MTIME_SRC）" >&2; exit 1 ;;
		esac
		# cd 进 $STAGE 后只用 find . 的相对路径：归一范围锁死，路径不可能逃出 $STAGE。
		# find . 的输出含根目录 .（对应 C1 清单的根行）；-depth 让目录排在其内容之后。
		# 遍历顺序不影响结果（touch 子项不改父目录 mtime），加 -depth 与 C1 复原口径一致。
		( cd "$STAGE" && find . -depth -exec touch -h -d "@$MTIME_EPOCH" {} + ) || { echo "FAIL: mtime 归一 touch 失败（STAGE=$STAGE epoch=$MTIME_EPOCH）" >&2; exit 1; }
		mtime_lines=$( cd "$STAGE" && find . -exec stat -c '%Y %n' {} + ) || { echo "FAIL: mtime 回读命令失败" >&2; exit 1; }
		[ -n "$mtime_lines" ] || { echo "FAIL: mtime 回读为空" >&2; exit 1; }
		bad_mtime=$(printf '%s\n' "$mtime_lines" | awk -v want="$MTIME_EPOCH" '$1 != want {print}')
		[ -z "$bad_mtime" ] || { echo "FAIL: mtime 回读与目标 epoch=$MTIME_EPOCH 不等（来源 $MTIME_SRC）:" >&2; echo "$bad_mtime" >&2; exit 1; }
		echo "MTIME_EPOCH=$MTIME_EPOCH（来源 $MTIME_SRC）"
		;;
	*)
		echo "FAIL: NORMALIZE_MTIME=$NORMALIZE_MTIME 非法（只接受 0 或 1）" >&2
		exit 1
		;;
esac

rm -f "$OUT"
# r29：installed-size 记录。历史口径是「包内所有文件字节和」（r15 已核）；这里先现算，
# 打包后再从 adbdump 读实际值比对，不等就说明 staging 与包内文件集不一致。
STAGE_BYTES=$(find "$STAGE" -type f -exec stat -c %s {} + | awk '{s+=$1} END{print s}')
echo "STAGE_BYTES=$STAGE_BYTES"
# B2（r37）：curl 是 189 驱动 curl 传输的运行时依赖，必须在包元数据里声明。
# 设备现查 apk info -e curl rc=0、/usr/bin/curl 属 curl-8.21.0-r1，依赖可满足。
# 2026-11-04：mkpkg 的 -I depends 重复给会覆盖（实测只留最后一条），两条依赖必须合成
# 一个空格分隔的字符串一次给；否则 shared 变体丢 curl。
if [ "$SHARED_TJS" = 1 ]; then
	set -- -I "depends:curl txiki-js>=$TJS_MIN_VERSION"
	echo "DEPENDS=curl txiki-js>=$TJS_MIN_VERSION"
else
	set -- -I "depends:curl"
	echo "DEPENDS=curl"
fi
# r49：可选签名。SIGN_KEY 是容器内可见的 PEM 私钥路径（无口令）；不给就不出签名块，
# 命令行与 r48 逐字节同形。给错路径直接失败，不静默出未签名包。
if [ -n "${SIGN_KEY:-}" ]; then
	[ -f "$SIGN_KEY" ] || { echo "FAIL: SIGN_KEY=$SIGN_KEY 不存在" >&2; exit 1; }
	set -- "$@" --sign-key "$SIGN_KEY"
	echo "SIGN_KEY=$SIGN_KEY"
fi
"$APK" mkpkg --compat 3.0.0_pre1 \
	-I "name:openlist-txiki" \
	-I "version:$VERSION" \
	-I "description:OpenList Worker on txiki.js (WebDAV/HTTP file gateway)" \
	-I "arch:aarch64_cortex-a53" \
	-I "license:AGPL-3.0-only AND LGPL-3.0-or-later AND MIT AND Apache-2.0" \
	-I "origin:openlist-txiki" \
	-I "maintainer:openlist-txiki maintainers" \
	"$@" \
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
