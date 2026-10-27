#!/bin/sh
# apk post-upgrade：先校验装后字节与 build-manifest 一致，再生成引导口令并 enable（幂等）。
# 不自动 start：新版首次启动由管理员决定，出问题能立刻回滚。
# sha 不符时不 enable（init 启动前也会再校验一次，双保险），等人工处置。
set -u
MANIFEST=/usr/share/openlist-txiki/build-manifest.json
PKG_DIR=/usr/libexec/openlist-txiki
BUNDLE=$PKG_DIR/openlist-txiki.js
TJS=$PKG_DIR/tjs
DATA_DIR=/etc/openlist-txiki

log() { logger -t openlist-txiki "$*"; }

manifest_sha() {
	sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" | head -n 1
}

# 升级不覆盖已有 admin.pass；r1/r2 升上来没有这个文件时补一个。
ensure_admin_pass() {
	mkdir -p "$DATA_DIR" 2>/dev/null
	chmod 700 "$DATA_DIR" 2>/dev/null
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

if [ -f "$MANIFEST" ] && [ -f "$BUNDLE" ] && [ -f "$TJS" ]; then
	want_b=$(manifest_sha bundle_sha256)
	want_t=$(manifest_sha tjs_sha256)
	got_b=$(sha256sum "$BUNDLE" | cut -d' ' -f1)
	got_t=$(sha256sum "$TJS" | cut -d' ' -f1)
	if [ -n "$want_b" ] && [ "$got_b" = "$want_b" ] && [ -n "$want_t" ] && [ "$got_t" = "$want_t" ]; then
		log "post-upgrade: sha256 ok (bundle $got_b, tjs $got_t)"
	else
		log "post-upgrade: SHA MISMATCH bundle=$got_b want=$want_b tjs=$got_t want=$want_t; not enabling, 等人工处置"
		[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki disable 2>/dev/null
		exit 0
	fi
else
	log "post-upgrade: 缺 build-manifest 或包内文件，跳过 sha 校验，不 enable"
	exit 0
fi

ensure_admin_pass
[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki enable
log "post-upgrade done: service enabled, not started (start manually or on next boot)"
exit 0
