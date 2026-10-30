#!/bin/sh
# Merged S1a+S1b + P2 A1 build (WSL Ubuntu, zig 0.16.0, aarch64-linux-musl).
# Tree: TREE（默认 /home/admin/txiki-merged）= txiki-js 26.9 @ a07d6aa + s1a + s1b + s1b core.c
#
# 2026-10-21 固化（architect 06:26 条件的落地）：zig build 不吃 src/js/polyfills/*.js。
# 改过 polyfills 后必须 esbuild 重打 JS bundle、再用 tjsc 生成 src/bundles/c/core/polyfills.c，
# 否则 zig 认为没变化，给 build_seconds=0、tjs sha 不变（这就是假通过）。顺序固定为：
#   A1 补丁 -> esbuild 重打 polyfills JS bundle -> tjsc 生成 polyfills.c -> zig build
# 构建日志记：esbuild 版本、两个 polyfill 依赖版本、polyfills JS bundle 与 polyfills.c 的
# sha256、tjs 的 sha256。任何一步做不到就失败退出，不静默跳过。
#
# 环境变量（都可不设）：
#   TREE=         源码树，默认 /home/admin/txiki-merged
#   A1_PATCH=     0 表示不应用 A1；<路径> 指定别的补丁。
#                 默认 /mnt/c/Users/admin/Desktop/openlist-txiki/work/txiki-wasm-module.patch
#   DEPS=         esbuild 与两个 polyfill 包的缓存目录，默认 /home/admin/txiki-build-deps
#   DEVICE=       tjsc 远程执行设备（tjsc 是 aarch64，x86 构建机跑不了）；必须显式设置，
#                 未设即打印用法并非零退出，脚本不内置任何地址
#   TJSC_REMOTE=  设备上的 tjsc 路径，默认 /tmp/tjs-p2/tjsc
#   LOG=          构建日志路径，默认 /home/admin/txiki-build-logs/build-<UTC 时间>.log
set -eu

TREE=${TREE:-/home/admin/txiki-merged}
DEPS=${DEPS:-/home/admin/txiki-build-deps}
# r27（S3 修复）：DEVICE 必须显式给，脚本不内置任何地址；未设即打印用法并非零退出。
DEVICE=${DEVICE:-}
if [ -z "$DEVICE" ]; then
  echo "usage: DEVICE=user@host [TREE=...] [DEPS=...] [TJSC_REMOTE=...] $0" >&2
  echo "error: DEVICE 未设置；tjsc 是 aarch64 工具，x86 构建机必须显式指定远程设备。" >&2
  exit 2
fi
TJSC_REMOTE=${TJSC_REMOTE:-/tmp/tjs-p2/tjsc}
ESBUILD_VER=0.28.1
WSP_VER=4.3.0
UPP_VER=10.1.0
LOG=${LOG:-/home/admin/txiki-build-logs/build-$(date -u +%Y%m%dT%H%M%SZ).log}

# 输出同时进日志：无论成功失败，结束时把日志原文甩到原 stdout
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
exec 3>&1
dump_log() {
  rc=$?
  exec >&3 2>&1
  echo "===== build log: $LOG ====="
  cat "$LOG"
  echo "===== end: exit=$rc ====="
  exit $rc
}
trap dump_log EXIT
exec >>"$LOG" 2>&1

echo "tree=$TREE"
cd "$TREE"

# ---- 1. A1 补丁（wasm.js 的 compile/instantiate 认已编译 Module） ----
#   - 幂等：已打过就跳过，重复跑不报错；打不上（不是这两种情况）立即失败
#   - s1a/s1b 已在该树里，本脚本不碰 zig 参数与补丁顺序
PATCH="${A1_PATCH-/mnt/c/Users/admin/Desktop/openlist-txiki/work/txiki-wasm-module.patch}"
if [ "$PATCH" = "0" ]; then
  echo "a1_patch=skipped"
elif [ -f "$PATCH" ]; then
  if patch -p1 -N --dry-run --silent < "$PATCH" >/dev/null 2>&1; then
    patch -p1 -N --silent < "$PATCH"
    echo "a1_patch=applied"
  elif patch -p1 -R --dry-run --silent < "$PATCH" >/dev/null 2>&1; then
    echo "a1_patch=already"
  else
    echo "a1_patch=failed patch=$PATCH" >&2
    exit 1
  fi
else
  echo "a1_patch=missing patch=$PATCH" >&2
  exit 1
fi

# ---- 1b. mbedtls TLS1.2 PSS 补丁（T1 修复，固化；fail-closed） ----
#   - 补丁锚定 sha256（PSS_SHA），文件默认 $TREE/patches/（与仓库 work/txiki-26.9/patches/ 同一份，LF）
#   - deps/build/mbedtls/build.zig 必须已挂 ensureApplied，否则补丁根本不进编译
#   - 该 mbedtls 检出目录的工作树是 CRLF（历史遗留的整树换行，非本补丁造成），git apply 默认按
#     字节比上下文，LF 补丁对 CRLF 工作树前向/反向 check 都失败；检出目录设 core.autocrlf=true
#     后 git apply 做换行归一，才能认出“已打过”。只改检出目录 .git/config，不动源码字节。
#   - 前向 check 通过 = 未打；反向 check 通过 = 已打；两者都不过立即失败，不静默跳过
PSS_PATCH=${PSS_PATCH:-patches/mbedtls-tls12-pss.patch}
PSS_SHA=cd1d269777facec3a07c3b0549c451c4b9d8278b8e4593e50fd9da85adbdae98
if [ ! -f "$PSS_PATCH" ]; then
  echo "pss_patch=missing patch=$PSS_PATCH" >&2
  exit 1
fi
# git -C <dir> 会切到检出目录，相对路径的补丁会被解析到 deps/mbedtls 下，先用绝对路径
case "$PSS_PATCH" in
  /*) ;;
  *) PSS_PATCH="$PWD/$PSS_PATCH" ;;
esac
pss_got=$(sha256sum "$PSS_PATCH" | cut -d' ' -f1)
echo "pss_patch_path=$PSS_PATCH"
echo "pss_patch_sha256=$pss_got"
if [ "$pss_got" != "$PSS_SHA" ]; then
  echo "pss_patch_sha256_mismatch want=$PSS_SHA got=$pss_got" >&2
  exit 1
fi
if ! grep -q 'mbedtls-tls12-pss.patch' deps/build/mbedtls/build.zig; then
  echo "pss_ensure_applied=missing deps/build/mbedtls/build.zig" >&2
  exit 1
fi
echo "pss_ensure_applied=wired"
if file deps/mbedtls/library/ssl_misc.h | grep -q 'CRLF'; then
  git -C deps/mbedtls config core.autocrlf true
  echo "mbedtls_worktree_eol=crlf core.autocrlf=true"
else
  echo "mbedtls_worktree_eol=lf"
fi
if git -C deps/mbedtls apply --check "$PSS_PATCH" >/dev/null 2>&1; then
  echo "pss_forward_check=ok"
else
  echo "pss_forward_check=fail"
fi
if git -C deps/mbedtls apply --reverse --check "$PSS_PATCH" >/dev/null 2>&1; then
  echo "pss_reverse_check=ok"
  pss_rev=ok
else
  echo "pss_reverse_check=fail"
  pss_rev=fail
fi
if git -C deps/mbedtls apply --check "$PSS_PATCH" >/dev/null 2>&1; then
  echo "pss_patch=not_applied"
elif [ "$pss_rev" = ok ]; then
  echo "pss_patch=already_applied"
else
  echo "pss_patch=failed neither applies nor applied patch=$PSS_PATCH" >&2
  exit 1
fi

# ---- 2. 工具与依赖（版本锁定，全部进日志） ----
pkg_version() {
  grep -m1 '"version"' "$1" | sed 's/.*"version": *"\([^"]*\)".*/\1/'
}

ESBUILD="$DEPS/esbuild-$ESBUILD_VER/bin/esbuild"
if [ ! -x "$ESBUILD" ]; then
  echo "deps: fetch @esbuild/linux-x64@$ESBUILD_VER"
  rm -rf "$DEPS/esbuild-$ESBUILD_VER"
  mkdir -p "$DEPS/esbuild-$ESBUILD_VER"
  curl -fsSL "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-$ESBUILD_VER.tgz" \
    | tar xz -C "$DEPS/esbuild-$ESBUILD_VER" --strip-components=1
  chmod +x "$ESBUILD"
fi
echo "esbuild_version=$("$ESBUILD" --version)"

for spec in "web-streams-polyfill:$WSP_VER" "urlpattern-polyfill:$UPP_VER"; do
  name=${spec%%:*}
  ver=${spec##*:}
  dir="node_modules/$name"
  if [ ! -f "$dir/package.json" ] || [ "$(pkg_version "$dir/package.json")" != "$ver" ]; then
    echo "deps: fetch $name@$ver"
    rm -rf "$dir"
    mkdir -p "$dir"
    curl -fsSL "https://registry.npmjs.org/$name/-/$name-$ver.tgz" \
      | tar xz -C "$dir" --strip-components=1
  fi
  got=$(pkg_version "$dir/package.json")
  if [ "$got" != "$ver" ]; then
    echo "dep_version_mismatch name=$name want=$ver got=$got" >&2
    exit 1
  fi
  echo "dep_$name=$got"
done

# ---- 3. esbuild 重打 polyfills JS bundle（参数与 txiki Makefile 第 41-48 行一致） ----
BUNDLE=src/bundles/js/core/polyfills.js
mkdir -p src/bundles/js/core
"$ESBUILD" src/js/polyfills/index.js \
  --bundle \
  --metafile="$BUNDLE.json" \
  --outfile="$BUNDLE" \
  --external:tjs:* \
  --minify \
  --keep-names \
  --target=es2023 \
  --platform=neutral \
  --format=esm \
  --main-fields=main,module \
  '--define:process.env.NODE_ENV="production"'
echo "polyfills_js_bytes=$(wc -c < "$BUNDLE" | tr -d ' ')"
echo "polyfills_js_sha256=$(sha256sum "$BUNDLE" | cut -d' ' -f1)"

# ---- 4. tjsc 生成 polyfills.c（aarch64 工具；x86 构建机只能在设备上跑） ----
#   - 参数与 Makefile 第 50-57 行一致
#   - 只有构建机本身是 aarch64 且给了可执行的 TJSC 才本地跑，否则走 DEVICE
C_OUT=src/bundles/c/core/polyfills.c
mkdir -p src/bundles/c/core
if [ "$(uname -m)" = "aarch64" ] && [ -n "${TJSC:-}" ] && [ -x "${TJSC:-}" ]; then
  echo "tjsc=local path=$TJSC"
  "$TJSC" -m -s -o "$C_OUT" -n "tjs:internal/polyfills" -p tjs__ "$BUNDLE"
else
  echo "tjsc=remote device=$DEVICE path=$TJSC_REMOTE"
  # 设备是 dropbear，没有 sftp-server，scp 会报 /usr/libexec/sftp-server: not found，
  # 所以走 ssh 的 exec 通道传文件（二进制安全，不要 pty）
  TMPD=/tmp/tjsc-build
  ssh -o BatchMode=yes "$DEVICE" "rm -rf $TMPD && mkdir -p $TMPD && cat > $TMPD/polyfills.js" < "$BUNDLE"
  ssh -o BatchMode=yes "$DEVICE" "$TJSC_REMOTE -m -s -o $TMPD/polyfills.c -n tjs:internal/polyfills -p tjs__ $TMPD/polyfills.js"
  ssh -o BatchMode=yes "$DEVICE" "cat $TMPD/polyfills.c" > "$C_OUT"
  ssh -o BatchMode=yes "$DEVICE" "rm -rf $TMPD"
  echo "tjsc_remote_sha256=$(ssh -o BatchMode=yes "$DEVICE" "sha256sum $TJSC_REMOTE" | cut -d' ' -f1)"
fi
echo "polyfills_c_bytes=$(wc -c < "$C_OUT" | tr -d ' ')"
echo "polyfills_c_sha256=$(sha256sum "$C_OUT" | cut -d' ' -f1)"

# ---- 5. zig build ----
ZIG=/home/admin/zig/zig-x86_64-linux-0.16.0/zig
echo "zig_version=$($ZIG version)"
t0=$(date +%s)
$ZIG build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
t1=$(date +%s)
echo "build_seconds=$((t1 - t0))"
ls -l zig-out/bin/tjs
echo "tjs_sha256=$(sha256sum zig-out/bin/tjs | cut -d' ' -f1)"
file zig-out/bin/tjs
