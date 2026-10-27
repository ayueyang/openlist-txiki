#!/bin/sh
# apk pre-deinstall：apk 删除包文件之前先把实例停掉。
#
# 依据 artifacts/porter-p4-hookorder-20261022T2125 的设备实测：pre-deinstall 早于文件删除，
# post-deinstall 在其后、那时 /etc/init.d/openlist-txiki 已随包删除，post 里调 stop 是空操作。
# 所以「卸载时停服务」只能挂 pre-deinstall。
#
# 判活不能只用 `pidof tjs`：设备上 alist-encrypt 用 /usr/bin/tjs 在跑（P3 实测 pid 3717），
# 本包用 /usr/libexec/openlist-txiki/tjs，`pidof tjs` 会同时命中两个，等待永远超时、
# 日志永远是「进程仍在」。这里按 /proc/<pid>/exe 的真实指向只认本包的 tjs。
#
# 只停服务：不删 /etc/openlist-txiki、不删 data.db/-wal/-shm、不删 rollback/。
# 超时 5 秒（busybox 秒级 sleep，1 秒 × 5 次）；超时只记日志并放行卸载，绝不 kill、
# 也绝不 exit 非 0 卡住 apk。
set -u

PKG_DIR=/usr/libexec/openlist-txiki
log() { logger -t openlist-txiki "$*" 2>/dev/null; }

# 只列本包目录下的 tjs（按 exe 真实指向过滤），alist-encrypt 的 /usr/bin/tjs 不算
ours() {
	local p
	for p in $(pidof tjs 2>/dev/null); do
		[ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$PKG_DIR/tjs" ] && printf '%s ' "$p"
	done
}

if [ -x /etc/init.d/openlist-txiki ]; then
	/etc/init.d/openlist-txiki stop 2>/dev/null
	log "pre-deinstall: init stop returned $?"
else
	log "pre-deinstall: /etc/init.d/openlist-txiki 不存在，跳过 stop"
fi

i=0
while [ "$i" -lt 5 ]; do
	[ -n "$(ours)" ] || break
	sleep 1
	i=$((i + 1))
done
if [ -n "$(ours)" ]; then
	log "pre-deinstall: 等了 ${i}s 本包进程仍在（pid $(ours)），放行卸载（不 kill；数据保留在 /etc/openlist-txiki）"
else
	log "pre-deinstall: 本包进程已退出（等待 ${i}s），数据保留在 /etc/openlist-txiki"
fi
exit 0
