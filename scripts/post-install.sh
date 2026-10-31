#!/bin/sh
# apk post-install：建数据目录、生成引导口令、只在缺失时复制 env 模板、enable 服务。装完不自动启动。
# admin.pass 是首次建 admin 的引导凭据（0600 root:root），init 启动前读它做 bootstrap probe。
set -u
DATA_DIR=/etc/openlist-txiki
MANIFEST=/usr/share/openlist-txiki/build-manifest.json
DIST=/usr/share/openlist-txiki/dist

log() { logger -t openlist-txiki "$*"; }

manifest_sha() {
	sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" | head -n 1
}

# r29：就地校验包内精简前端（dist）的 tree sha 与文件数。
# 算法与 CRITERIA G3 / build-manifest.mjs 的 webTree 一致；不符只记 ERROR，不让安装失败：
# apk 签名已经覆盖字节，tree 不符是打包错误，该由装机门拦，不该把设备卡在升级钩子里。
check_web_dist() {
	[ -f "$MANIFEST" ] || { log "web dist: 缺 $MANIFEST，跳过校验"; return 0; }
	[ -d "$DIST" ] || { log "web dist: 缺 $DIST（前端不可用，后端照常启动）"; return 0; }
	want=$(manifest_sha tree_sha256)
	[ -n "$want" ] || { log "web dist: manifest 没有 web_dist.tree_sha256，跳过校验"; return 0; }
	got=$(cd "$DIST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | \
		while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done | \
		sha256sum | awk '{print $1}')
	n=$(find "$DIST" -type f | wc -l | tr -d ' ')
	if [ "$got" = "$want" ]; then
		log "web dist ok: $n files tree=$got"
	else
		log "ERROR: web dist tree mismatch files=$n got=$got want=$want"
	fi
}

# 只在缺失时生成 24 个 hex 字符（96 bit）的引导口令；日志只打路径，绝不打值。
ensure_admin_pass() {
	[ -f "$DATA_DIR/admin.pass" ] && return 0
	umask 077
	tmp="$DATA_DIR/.admin.pass.$$"
	if head -c 12 /dev/urandom | hexdump -v -e '/1 "%02x"' > "$tmp"; then
		chmod 600 "$tmp"
		chown 0:0 "$tmp" 2>/dev/null
		mv "$tmp" "$DATA_DIR/admin.pass"
		log "generated $DATA_DIR/admin.pass (0600)"
	else
		rm -f "$tmp"
		log "WARN: admin.pass 生成失败；首次启动请手工设 TJS_ADMIN_PASS 或走本机安装向导"
	fi
}

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
ensure_admin_pass
if [ ! -f "$DATA_DIR/openlist-txiki.env" ]; then
	cp /usr/share/openlist-txiki/openlist-txiki.env.default "$DATA_DIR/openlist-txiki.env"
	chmod 600 "$DATA_DIR/openlist-txiki.env"
fi
[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki enable
check_web_dist
logger -t openlist-txiki "post-install done: data dir $DATA_DIR kept, admin.pass ensured, env template applied only if missing, service enabled (not started)"
# 默认只绑 127.0.0.1：装完不主动对 LAN 开放，首次使用见 env 文件头部注释
logger -t openlist-txiki "服务默认只监听 127.0.0.1（未对 LAN 开放）；首次使用先读 $DATA_DIR/admin.pass，见 env 文件头部三步说明"
exit 0
