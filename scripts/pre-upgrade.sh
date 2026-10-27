#!/bin/sh
# apk pre-upgrade：停服务，备份 data.db（<32MB 才备份，保留最近 1 份），
# 把旧二进制与旧 manifest 存进 /etc/openlist-txiki/rollback/<旧版本>/（保留最近 1 份）。
# 只读 /etc/openlist-txiki，不删用户数据。
#
# A4（2026-10-22 P4）：保留份数从 2+2 收到 1+1。overlay 只有 122.3M，2 份 rollback
# （每份 tjs+bundle+manifest 约 7.3MiB）加 2 份 db 备份（主文件上限 32MiB，连 -wal/-shm
# 约 36MiB）最坏约 79MiB，升级期间还要再放下新包约 7.4MiB。1+1 最坏约 43MiB，
# 留约 79MiB 余量。算式与本地实跑数见 artifacts/p4-apk-r7-*/README.md。
set -u
DATA_DIR=/etc/openlist-txiki

[ -x /etc/init.d/openlist-txiki ] && /etc/init.d/openlist-txiki stop 2>/dev/null

if [ -f "$DATA_DIR/data.db" ]; then
	SIZE=$(wc -c < "$DATA_DIR/data.db" | tr -d ' ')
	if [ "$SIZE" -lt 33554432 ]; then
		VER=${1:-unknown}
		cp -a "$DATA_DIR/data.db" "$DATA_DIR/data.db.bak-$VER"
		# data.db 与 WAL/SHM 必须成套备份：只备主文件，回滚时 -wal 里的最近提交会丢。
		for S in -wal -shm; do
			[ -f "$DATA_DIR/data.db$S" ] && cp -a "$DATA_DIR/data.db$S" "$DATA_DIR/data.db.bak-$VER$S"
		done
		ls -1t "$DATA_DIR"/data.db.bak-* 2>/dev/null | awk '$0 !~ /-(wal|shm)$/' | awk 'NR>1' | while read -r f; do
			rm -f "$f" "$f-wal" "$f-shm"
		done
		logger -t openlist-txiki "pre-upgrade: backed up data.db ($SIZE B) to data.db.bak-$VER"
	else
		logger -t openlist-txiki "pre-upgrade: data.db is $SIZE B (>=32MB), backup skipped on purpose"
	fi
fi

if [ -f /usr/share/openlist-txiki/build-manifest.json ] && [ -f /usr/libexec/openlist-txiki/tjs ]; then
	OLDVER=$(sed -n 's/.*"package_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /usr/share/openlist-txiki/build-manifest.json | head -n 1)
	R="$DATA_DIR/rollback/${OLDVER:-unknown}"
	mkdir -p "$R"
	cp -a /usr/libexec/openlist-txiki/tjs "$R/tjs" 2>/dev/null
	cp -a /usr/libexec/openlist-txiki/openlist-txiki.js "$R/openlist-txiki.js" 2>/dev/null
	cp -a /usr/share/openlist-txiki/build-manifest.json "$R/build-manifest.json" 2>/dev/null
	ls -1dt "$DATA_DIR"/rollback/* 2>/dev/null | awk 'NR>1' | while read -r d; do rm -rf "$d"; done
	logger -t openlist-txiki "pre-upgrade: old binaries saved to $R"
fi
exit 0
