#!/bin/sh
# apk post-deinstall：只清本包自己的 rc.d 软链与 /tmp/openlist-txiki。
# 绝不 rm -rf /etc/openlist-txiki、绝不删 data.db/WAL、不枚举用户上传下载目录。
# rc.common 的 enable 生成的 /etc/rc.d/S99openlist-txiki 不属于 apk 文件表，要自己删。
set -u
for f in /etc/rc.d/*openlist-txiki; do
	[ -L "$f" ] && rm -f "$f" && logger -t openlist-txiki "post-deinstall: removed $f"
done
rm -rf /tmp/openlist-txiki
# r52：升级前状态记录只在一次 pre-upgrade -> post-upgrade 之间有效，卸载时清掉，
# 免得下次重装的 post-install 读到残留 running 而擅自启动。
rm -f /etc/openlist-txiki/.upgrade-state
logger -t openlist-txiki "post-deinstall: package files removed by apk; DATA KEPT at /etc/openlist-txiki (data.db, -wal, -shm, env, rollback/)"
exit 0
