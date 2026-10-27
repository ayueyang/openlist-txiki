#!/bin/sh
# apk post-install：建数据目录、生成引导口令、只在缺失时复制 env 模板、enable 服务。装完不自动启动。
# admin.pass 是首次建 admin 的引导凭据（0600 root:root），init 启动前读它做 bootstrap probe。
set -u
DATA_DIR=/etc/openlist-txiki

log() { logger -t openlist-txiki "$*"; }

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
logger -t openlist-txiki "post-install done: data dir $DATA_DIR kept, admin.pass ensured, env template applied only if missing, service enabled (not started)"
# 默认只绑 127.0.0.1：装完不主动对 LAN 开放，首次使用见 env 文件头部注释
logger -t openlist-txiki "服务默认只监听 127.0.0.1（未对 LAN 开放）；首次使用先读 $DATA_DIR/admin.pass，见 env 文件头部三步说明"
exit 0
