#!/bin/sh
# apk post-upgrade：先校验装后字节与 build-manifest 一致，再生成引导口令并 enable（幂等）。
# r52 起：pre-upgrade 记录了升级前服务在跑时，装完立即 start 并等首个 200（≤3 秒）；
# 升级前是停的就保持停止。sha 不符时不 enable 也不 start（init 启动前也会再校验一次），等人工处置。
set -u
MANIFEST=/usr/share/openlist-txiki/build-manifest.json
PKG_DIR=/usr/libexec/openlist-txiki
BUNDLE=$PKG_DIR/openlist-txiki.js
TJS=$PKG_DIR/tjs
DATA_DIR=/etc/openlist-txiki
ENV_FILE=$DATA_DIR/openlist-txiki.env
DIST=/usr/share/openlist-txiki/dist

log() { logger -t openlist-txiki "$*"; }

manifest_sha() {
	sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST" | head -n 1
}

manifest_str() {
	sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1
}

# 变体：manifest 没有 runtime 字段时按自带版处理（与旧包兼容）。
RUNTIME=$(manifest_str runtime)
RUNTIME=${RUNTIME:-bundled}
[ "$RUNTIME" = shared ] && TJS=/usr/bin/tjs

# r29：升级后就地校验包内 dist（前端 v4.2.7）的 tree sha 与文件数；不符只记 ERROR，不阻断升级。
check_web_dist() {
	[ -d "$DIST" ] || { log "web dist: 缺 $DIST（前端不可用，后端照常启动）"; return 0; }
	want=$(manifest_sha tree_sha256)
	[ -n "$want" ] || { log "web dist: manifest 没有 web_dist.tree_sha256，跳过校验"; return 0; }
	got=$(cd "$DIST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | \
		while IFS= read -r f; do printf '%s	%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done | \
		sha256sum | awk '{print $1}')
	n=$(find "$DIST" -type f | wc -l | tr -d ' ')
	if [ "$got" = "$want" ]; then
		log "web dist ok: $n files tree=$got"
	else
		log "ERROR: web dist tree mismatch files=$n got=$got want=$want"
	fi
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

# r52：在线升级自动拉起。pre-upgrade 在 stop 之前把服务状态写进 $STATE_FILE，
# 这里只按那份记录决定：running 才 start，stopped 或无记录一律保持停止，
# 不擅自启动用户没开的服务。3 秒内拿不到 200 只记日志，保持 enable，不阻塞升级。
STATE_FILE=$DATA_DIR/.upgrade-state

now_ms() {
	awk '{ printf "%d", $1 * 1000 }' /proc/uptime 2>/dev/null || echo "$(date +%s)000"
}

read_state() {
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

probe_host() {
	case "$1" in
		0.0.0.0|''|'*') printf '127.0.0.1' ;;
		::|'[::]') printf '[::1]' ;;
		*) printf '%s' "$1" ;;
	esac
}

resume_if_was_running() {
	if [ ! -f "$STATE_FILE" ]; then
		log "auto-start: 无 pre-upgrade 状态记录，保持停止（老包升级或手工执行钩子）"
		return 0
	fi
	_pre_state=$(read_state PRE_STATE)
	_pre_port=$(read_state PRE_PORT)
	case "$_pre_port" in ''|*[!0-9]*) _pre_port=5345 ;; esac
	if [ "$_pre_state" != running ]; then
		log "pre=${_pre_state:-unknown} -> post=stopped (kept stopped)"
		rm -f "$STATE_FILE"
		return 0
	fi
	_addr=$(sed -n 's/^[[:space:]]*LISTEN_ADDR[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	_addr=${_addr%%#*}; _addr=$(printf '%s' "$_addr" | tr -d '[:space:]')
	_addr=${_addr#\"}; _addr=${_addr%\"}; _addr=${_addr#\'}; _addr=${_addr%\'}
	_host=$(probe_host "$_addr")
	_start_out=$(/etc/init.d/openlist-txiki start 2>&1)
	_start_rc=$?
	_t0=$(now_ms)
	_first200=none
	while :; do
		if wget -q -T 1 -O /dev/null "http://$_host:$_pre_port/api/public/settings" 2>/dev/null; then
			_first200=$(( $(now_ms) - _t0 ))
			break
		fi
		[ $(( $(now_ms) - _t0 )) -ge 3000 ] && break
		sleep 1
	done
	if [ "$_first200" != none ]; then
		log "pre=running -> post=started, first200=${_first200}ms (port=$_pre_port rc=$_start_rc)"
	else
		log "pre=running -> post=start-failed rc=$_start_rc first200=none (port=$_pre_port, 保持 enable，不阻塞升级)"
		[ -n "$_start_out" ] && log "auto-start: start output: $(printf '%s' "$_start_out" | tr '\n' ' ')"
		_tail=$(logread -e openlist-txiki 2>/dev/null | tail -n 3 | tr '\n' ' ')
		[ -n "$_tail" ] && log "auto-start: last log: $_tail"
	fi
	rm -f "$STATE_FILE"
	return 0
}

if [ -f "$MANIFEST" ] && [ -f "$BUNDLE" ] && [ -x "$TJS" ]; then
	want_b=$(manifest_sha bundle_sha256)
	got_b=$(sha256sum "$BUNDLE" | cut -d' ' -f1)
	if [ "$RUNTIME" = shared ]; then
		# shared-tjs：包内没有 tjs，不校验 tjs sha；只校验 bundle 与系统运行时存在。
		if [ -n "$want_b" ] && [ "$got_b" = "$want_b" ]; then
			log "post-upgrade: bundle sha256 ok ($got_b), runtime=shared tjs=$TJS $("$TJS" --version 2>/dev/null | head -n 1)"
		else
			log "post-upgrade: SHA MISMATCH bundle=$got_b want=$want_b (runtime=shared); not enabling, 等人工处置"
			[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki disable 2>/dev/null
			exit 0
		fi
	else
		want_t=$(manifest_sha tjs_sha256)
		got_t=$(sha256sum "$TJS" | cut -d' ' -f1)
		if [ -n "$want_b" ] && [ "$got_b" = "$want_b" ] && [ -n "$want_t" ] && [ "$got_t" = "$want_t" ]; then
			log "post-upgrade: sha256 ok (bundle $got_b, tjs $got_t)"
		else
			log "post-upgrade: SHA MISMATCH bundle=$got_b want=$want_b tjs=$got_t want=$want_t; not enabling, 等人工处置"
			[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki disable 2>/dev/null
			exit 0
		fi
	fi
else
	log "post-upgrade: 缺 build-manifest 或包内文件，跳过 sha 校验，不 enable"
	exit 0
fi

ensure_admin_pass
[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki enable
# 先拉起再校验前端：dist 校验是软检查（不符只记 ERROR），放在 start 后面可以少占停服窗口。
resume_if_was_running
check_web_dist
log "post-upgrade done: service enabled, auto-start per pre-upgrade state"
exit 0
