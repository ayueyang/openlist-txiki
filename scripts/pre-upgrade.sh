#!/bin/sh
# apk pre-upgrade：停服务，备份 data.db（<32MB 才备份），
# 把旧二进制与旧 manifest 存进 /etc/openlist-txiki/rollback/<旧版本>/。
# 只读 /etc/openlist-txiki，不删用户数据。
#
# A4（2026-10-22 P4）：保留份数从 2+2 收到 1+1。overlay 只有 122.3M，2 份 rollback
# （每份 tjs+bundle+manifest 约 7.3MiB）加 2 份 db 备份（主文件上限 32MiB，连 -wal/-shm
# 约 36MiB）最坏约 79MiB，升级期间还要再放下新包约 7.4MiB。1+1 最坏约 43MiB，
# 留约 79MiB 余量。算式与本地实跑数见 artifacts/p4-apk-r7-*/README.md。
#
# D1（2026-10-28 r19）：备份名不再用 apk 传入的新版本 $1（那是升级后的版本，会被误读成
# 备份内容所属版本），改用升级前已安装 manifest 的 package_version；读不到时用时间戳。
# 保留份数由 KEEP_DB_BACKUPS 控制：默认 1（与 A4 的 1+1 一致）；0 = 一份都不删；
# N = 保留最近 N 份。db 备份与 rollback/<旧版本> 目录同受此变量控制，每次删除逐条记日志。
#
# r34（2026-11-03）：apk-tools 3.x 起钩子环境被清空，只留 APK_PACKAGE/APK_SCRIPT/PATH/PWD/SHLVL，
# 调用者的 `KEEP_DB_BACKUPS=0 apk add` 传不进脚本（3.0.7 容器实测；3.0.5 源码 context.c 同一分支）。
# 所以开关改从设备上的 /etc/openlist-txiki/openlist-txiki.env 读，不依赖 apk 调用环境。
# 该文件由 post-install 只在缺失时生成、升级不覆盖，也不在包文件清单里，apk 升级不会动它。
# 钩子环境里若有显式值（apk --preserve-env 时才可能）仍优先，便于临时覆盖。
set -u
DATA_DIR=/etc/openlist-txiki
ENV_FILE=$DATA_DIR/openlist-txiki.env
MANIFEST=/usr/share/openlist-txiki/build-manifest.json

KEEP_SRC=env
KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS:-}
if [ -z "$KEEP_DB_BACKUPS" ]; then
	KEEP_SRC=env-file
	KEEP_DB_BACKUPS=$(sed -n 's/^[[:space:]]*KEEP_DB_BACKUPS[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS%%#*}
	KEEP_DB_BACKUPS=$(printf '%s' "$KEEP_DB_BACKUPS" | tr -d '[:space:]')
	KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS#\"}; KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS%\"}
	KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS#\'}; KEEP_DB_BACKUPS=${KEEP_DB_BACKUPS%\'}
fi
if [ -z "$KEEP_DB_BACKUPS" ]; then
	KEEP_DB_BACKUPS=1
	[ "$KEEP_SRC" = env-file ] && KEEP_SRC=default
fi

# 非数字（含空串）回退默认 1，避免下面的 -eq/-gt 在升级钩子里报错中断。
case "$KEEP_DB_BACKUPS" in
''|*[!0-9]*) KEEP_DB_BACKUPS=1; KEEP_SRC=invalid-fallback ;;
esac
logger -t openlist-txiki "pre-upgrade: KEEP_DB_BACKUPS=$KEEP_DB_BACKUPS (source=$KEEP_SRC)"

# 旧版本只读一次：db 备份名与下面的 rollback/<旧版本> 共用。
OLDVER=
[ -f "$MANIFEST" ] && OLDVER=$(sed -n 's/.*"package_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)
if [ -n "$OLDVER" ]; then
	TAG=$OLDVER
	TAG_SRC=installed-manifest
else
	TAG=$(date +%Y%m%dT%H%M%S)
	TAG_SRC=timestamp
fi

# r52：升级前记录服务状态，供 post-upgrade 决定是否自动拉起。
# r51 实测在线升级停服 12 分 29 秒，原因是 post-upgrade 只 enable 不 start。
# 判定不依赖 procd 的瞬时状态：status 只是第一条证据，另两条是进程名与端口 LISTEN。
# source 形态的进程名是 tjs（与 alist-encrypt 共用），不能靠 pidof，所以端口这条必须有。
STATE_FILE=$DATA_DIR/.upgrade-state

read_listen_port() {
	_P=$(sed -n 's/^[[:space:]]*LISTEN_PORT[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	_P=${_P%%#*}
	_P=$(printf '%s' "$_P" | tr -d '[:space:]')
	_P=${_P#\"}; _P=${_P%\"}; _P=${_P#\'}; _P=${_P%\'}
	case "$_P" in ''|*[!0-9]*) _P=5345 ;; esac
	printf '%s' "$_P"
}

port_listening() {
	_hex=$(printf '%04X' "$1")
	for _f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$_f" ] || continue
		awk -v p="$_hex" 'NR > 1 { split($2, a, ":"); if (a[2] == p && $4 == "0A") found = 1 } END { exit !found }' "$_f" && return 0
	done
	return 1
}

PRE_PORT=$(read_listen_port)
PRE_PID=$(pidof openlist-txiki-bin 2>/dev/null | awk '{print $1}')
if [ "$(/etc/init.d/openlist-txiki status 2>/dev/null)" = running ] || [ -n "$PRE_PID" ] || port_listening "$PRE_PORT"; then
	PRE_STATE=running
else
	PRE_STATE=stopped
fi
mkdir -p "$DATA_DIR" 2>/dev/null
if { printf 'PRE_STATE=%s\n' "$PRE_STATE"
     printf 'PRE_PORT=%s\n' "$PRE_PORT"
     printf 'PRE_PID=%s\n' "${PRE_PID:-none}"
     printf 'PRE_TS=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
   } > "$STATE_FILE" 2>/dev/null; then
	chmod 600 "$STATE_FILE" 2>/dev/null
	logger -t openlist-txiki "pre-upgrade: service state=$PRE_STATE port=$PRE_PORT pid=${PRE_PID:-none} -> $STATE_FILE"
else
	logger -t openlist-txiki "WARN: pre-upgrade: 写不了 $STATE_FILE，升级后不会自动拉起（保持停止）"
fi

[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki stop 2>/dev/null

prune_db_backups() {
	KEEP=$1
	[ "$KEEP" -eq 0 ] && return 0
	N=0
	ls -1t "$DATA_DIR"/data.db.bak-* 2>/dev/null | awk '$0 !~ /-(wal|shm)$/' | while read -r f; do
		N=$((N + 1))
		[ "$N" -le "$KEEP" ] && continue
		for S in '' -wal -shm; do
			[ -f "$f$S" ] || continue
			logger -t openlist-txiki "pre-upgrade: removing $f$S (KEEP_DB_BACKUPS=$KEEP, keep newest $KEEP db backup set(s))"
			rm -f "$f$S"
		done
	done
}

if [ -f "$DATA_DIR/data.db" ]; then
	SIZE=$(wc -c < "$DATA_DIR/data.db" | tr -d ' ')
	if [ "$SIZE" -lt 33554432 ]; then
		cp -a "$DATA_DIR/data.db" "$DATA_DIR/data.db.bak-$TAG"
		# 备份件 mtime 记为“做备份的时刻”：cp -a 会保留 data.db 的旧 mtime，全部备份同
		# mtime 时 ls -1t 排序成平局，保留策略可能删掉刚做的那份。字节与权限不动。
		touch "$DATA_DIR/data.db.bak-$TAG"
		# data.db 与 WAL/SHM 必须成套备份：只备主文件，回滚时 -wal 里的最近提交会丢。
		for S in -wal -shm; do
			[ -f "$DATA_DIR/data.db$S" ] && cp -a "$DATA_DIR/data.db$S" "$DATA_DIR/data.db.bak-$TAG$S"
		done
		prune_db_backups "$KEEP_DB_BACKUPS"
		logger -t openlist-txiki "pre-upgrade: backed up data.db ($SIZE B) to data.db.bak-$TAG (tag_source=$TAG_SRC)"
	else
		logger -t openlist-txiki "pre-upgrade: data.db is $SIZE B (>=32MB), backup skipped on purpose"
	fi
fi

if [ -f "$MANIFEST" ] && [ -f /usr/libexec/openlist-txiki/openlist-txiki.js ]; then
	R="$DATA_DIR/rollback/${OLDVER:-$TAG}"
	mkdir -p "$R"
	# 自带版才有包内 tjs；shared-tjs 变体不复制系统运行时，改为记录版本与 sha 供回滚核对。
	[ -f /usr/libexec/openlist-txiki/tjs ] && cp -a /usr/libexec/openlist-txiki/tjs "$R/tjs" 2>/dev/null
	cp -a /usr/libexec/openlist-txiki/openlist-txiki.js "$R/openlist-txiki.js" 2>/dev/null
	cp -a "$MANIFEST" "$R/build-manifest.json" 2>/dev/null
	if [ ! -f /usr/libexec/openlist-txiki/tjs ] && [ -x /usr/bin/tjs ]; then
		{ /usr/bin/tjs --version 2>&1; sha256sum /usr/bin/tjs; } > "$R/system-tjs.txt" 2>/dev/null
	fi
	if [ "$KEEP_DB_BACKUPS" -eq 0 ]; then
		:
	else
		ls -1dt "$DATA_DIR"/rollback/* 2>/dev/null | awk -v k="$KEEP_DB_BACKUPS" 'NR > k' | while read -r d; do
			logger -t openlist-txiki "pre-upgrade: removing $d (KEEP_DB_BACKUPS=$KEEP_DB_BACKUPS, keep newest $KEEP_DB_BACKUPS rollback dir(s))"
			rm -rf "$d"
		done
	fi
	logger -t openlist-txiki "pre-upgrade: old binaries saved to $R"
fi
exit 0
