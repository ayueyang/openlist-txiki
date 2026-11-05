#!/bin/sh
# openlist-txiki bytecode 形态启动器（A2）。
# procd 没有工作目录参数（/lib/functions/procd.sh 的可用类型里没有 cwd），
# 所以这里先 cd 到包目录，再 exec 包内独立二进制，不带任何参数。
# exec 不换 pid：/proc/<pid>/exe 与 /proc/<pid>/cmdline 都指向 openlist-txiki-bin，
# 不含 run、不含 .js。命令行参数一律由 init 通过 procd_set_param env 传入。
PKG_DIR=/usr/libexec/openlist-txiki
cd "$PKG_DIR" || exit 1
exec "$PKG_DIR/openlist-txiki-bin"
