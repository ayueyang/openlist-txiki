# 从源码构建（openlist-txiki 0.1.0-r56）

本归档是 openlist-txiki 0.1.0-r56 的完整对应源码：

    upstream/                 上游 OpenList-Worker，commit 5f53f58dd0f5e5d03eb6079da7f637fa151d8dca
                              （CRLF 工作区，浅克隆 .git 只含该提交；不含 node_modules）
    patches/openlist/01..55   应用侧补丁，按编号顺序累进应用
    patches/txiki/            txiki.js 运行时补丁（本归档不包含 txiki.js 源码树，见第 2 节）
    build/                    build-txiki.mjs、p2-source-manifest.txt
    scripts/                  apk 打包脚本与生命周期钩子
    src/                      移植层源码（src/backend/txiki/*、src/backend/server/admin.ts）
    work/                     补丁原文件名（构建脚本按清单里的路径校验 sha256）
    docs/                     本文件与安装说明

下文命令都在解包后的归档根目录执行，环境为 Linux（WSL 亦可）。

## 0. 依赖

- Node.js 20+、pnpm 9、git、python3
- tjs 另需 Zig 0.16.0
- apk 打包需 apk-tools 3.x（带 `mkpkg`）

## 1. 出 bundle（已实测可逐字节重建）

```sh
export PROJ=$PWD
cp -a upstream tree
cd tree

# CRLF 检出校验：必须是 2015
grep -c $'\r' src/backend/server/fs.ts

# 按清单顺序应用 55 条补丁；--exclude 必须带（src/backend/txiki 由移植层提供，不走补丁）
while read -r tag seq sha rel; do
  [ "$tag" = patch ] || continue
  echo "$sha  $PROJ/$rel" | sha256sum -c - || exit 1
  git apply --exclude='src/backend/txiki/*' "$PROJ/$rel" || exit 1
done < <(tr -d '\r' < "$PROJ/work/p2-source-manifest.txt" | grep '^patch ' | sort -k2)

cp "$PROJ/build/build-txiki.mjs" scripts/build-txiki.mjs
pnpm install --frozen-lockfile
TXIKI_SOURCE_MANIFEST="$PROJ/work/p2-source-manifest.txt" node scripts/build-txiki.mjs
sha256sum dist-txiki/openlist-txiki.js
```

期望：预检打印「补丁 55/55（01..55 顺序与 sha 一致），指纹 99 条（file 43 + patch 55 + commit 1），
checkout_eol=crlf」；产物 `dist-txiki/openlist-txiki.js` 为 2,083,901 B、
sha256 `25b78068bd5f1be81ad2c1105b947f9979941824842b59fd86532cf73a1e26c9`、inputs 447。

第 21 条补丁只改适配层 `src/backend/txiki/config.ts`（Windows 绝对路径判定与
`%LOCALAPPDATA%` 默认数据目录）。适配层文件由上面 `--exclude` 口径跳过 apply，
实际字节来自归档根的 `src/`（清单里 `src=repo` 的条目）；补丁本体保留在
`patches/openlist/21-*` 与 `work/` 中，用于补丁链留痕与 sha256 校验。

`TXIKI_SOURCE_MANIFEST` 指向归档内 `work/` 的清单，构建脚本由此把 `src=` 指向归档根的 `src/`，
所以构建树 `tree/` 与归档根必须保持这一层的相对位置。

## 2. tjs 运行时

发布的 tjs 二进制由 txiki.js fork（26.9.0 基线，commit a07d6aa）加本轮运行期补丁编出：

补丁全集与逐条 apply 根/顺序见 `patches/txiki/TXIKI-PATCHES.md`。分组：

- 服务端流式与背压：`s1a-c21-5.0.0.patch`（lws WebDAV 方法表 + httpserver.c）、`s1b-backpressure.patch`
  （+ 生成物 `s1b-core.c`）、`p6-stream-body.patch`、`p6b-abort-incomplete-body.patch`
- 请求路径解码：`lws-uri-encoding.patch`（lws，`+` 在路径里保持字面）、`0002-txiki-decoded-path.patch`
  （httpserver.c/js 把解码后原始路径挂给 JS；本归档对应产品侧 `patches/openlist/48`、`49`）
- 运行时与构建：`txiki-wasm-module.patch`（A1 wasm Module 实例化）、`05-mbedtls-build-wiring.patch`
  （把 `mbedtls-tls12-pss.patch` 接进 deps 构建）
- 依赖与工具链：`mbedtls-tls12-pss.patch`、`lws-mbedtls-client-alpn-uaf.patch`、`mbedtls-quic.patch`、`wamr-zig.patch`
- `libffi-aarch64-windows.patch`：仅 aarch64-windows 目标需要；本版发布的三目标（aarch64-linux-musl / x86_64-linux-musl / x86_64-windows）不打它

构建（aarch64 交叉为例，Zig 0.16.0）：

```sh
git clone https://github.com/qwtel/txiki-js.git txiki
cd txiki && git checkout a07d6aa19553a61d088bbfbd7ac2ae204d2761a6
mkdir -p patches && cp ../patches/txiki/*.patch patches/
# 应用补丁（p6、p6b 改 src/，其余改 deps/ 与构建文件；按上面列出的顺序）
# 手工段按 TXIKI-PATCHES.md 的顺序：s1a -> s1b -> p6 -> p6b -> lws-uri-encoding -> 0002(3way)
for p in patches/s1a-c21-5.0.0.patch patches/s1b-backpressure.patch \
         patches/p6-stream-body.patch patches/p6b-abort-incomplete-body.patch; do
  patch -p1 -N < "$p" || exit 1
done
(cd deps/libwebsockets && patch -p1 -N < ../../patches/lws-uri-encoding.patch) || exit 1
git apply --3way patches/0002-txiki-decoded-path.patch || exit 1
# A1 与 05：patch -p1 -N < patches/txiki-wasm-module.patch 等，见 TXIKI-PATCHES.md
for p in patches/lws-mbedtls-client-alpn-uaf.patch patches/mbedtls-quic.patch \
         patches/mbedtls-tls12-pss.patch patches/wamr-zig.patch; do
  patch -p1 -N < "$p" || exit 1
done
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
ls -l zig-out/bin/tjs
```

注意两条实测限制：

1. **构建路径会进二进制**。同一棵树换个绝对路径编出来的 sha256 必变（源码里有约 170 条
   以自身绝对路径开头的字符串）。要复现发布件的 sha256（aarch64：`4b931f66…f74693`，
   5,282,808 B），必须把树放在 `/home/admin/txiki-merged`（或用 `unshare -m` + `mount --bind`
   挂到该路径）。
2. 本归档给的是**补丁与命令**，不含 txiki.js 上游源码树本体（上游 tag `zig/v26.9.0` 需自行
   克隆）。r45 起 s1a/s1b/p6/p6b/lws-uri-encoding/0002/A1/05 的补丁实体都在
   `patches/txiki/`（`TXIKI-PATCHES.md` 列明顺序与根），不再是「不在清单内」的状态；但
   「从空树照本节命令编出同 sha 的二进制」仍未在离线空树端到端验证，已验的是发布机上
   同树状态冷缓存重建同 sha 同字节。

## 3. 打包 apk

```sh
VERSION=0.1.0-r56
STAGE=/tmp/r17-stage SCRIPTS=$PWD/scripts OUT=/tmp/openlist-txiki-$VERSION.apk \
  APK=/path/to/apk sh scripts/build-apk.sh
```

`scripts/build-apk.sh` 会校验包内 `build-manifest.json` 的 `package_version` 与 `$VERSION` 一致、
stage 文件集为固定 12 个文件（另有 dist/ 下 222 件前端产物按白名单校验），然后调 `apk mkpkg` 出包。`build-manifest.json` 由
`scripts/build-manifest.mjs` 生成（参数见该脚本头部注释）。

## 3.1 从源码归档复算桌面两件（linux tar.gz / win x64 zip）

归档带齐了复算所需的四件：`build/make-archives.py`（渲染器）、`build/assets/*.in`（四份模板）、
`scripts/build-archives.py`（组装器）、`scripts/build-archives.inputs.0.1.0-r56.json`（输入锚点）。
inputs.json 里的七个路径一律写 `${NAME}` 占位符，不含任何本机路径；复算前自己填一份变量文件：

```sh
cp scripts/build-archives.vars.example.json /tmp/vars.json
# 按下面的字段来源改 /tmp/vars.json 的七个值（相对仓根或绝对路径都行）
python scripts/build-archives.py \
  --inputs scripts/build-archives.inputs.0.1.0-r56.json \
  --out /tmp/desktop --renderer build/make-archives.py \
  --vars /tmp/vars.json
```

要自填的七个输入：

| 占位符 | 指向 | 怎么来 |
|---|---|---|
| `${BUNDLE}` | `dist-txiki/openlist-txiki.js` | 第 1 节出 bundle |
| `${TJS_LINUX}` | linux x86_64 的 tjs 二进制 | 第 2 节编译 |
| `${TJS_WIN}` | windows x64 的 tjs 可执行 | 第 2 节编译 |
| `${DIST}` | 官方前端 dist 目录 | `scripts/fetch-frontend.sh` 拉取 |
| `${OFFER}` | `scripts/SOURCE-OFFER` | 归档自带 |
| `${NOTICES}` | `scripts/THIRD-PARTY-NOTICES` | 归档自带 |
| `${TEMPLATES_DIR}` | `build/assets/` | 归档自带 |

- 相对路径按 `--inputs-root` 解析，默认仓根（或归档根）；不写 `--vars` 时也可用环境变量
  `BUILD_ARCHIVES_VAR_<NAME>` 逐个给。
- 身份不匹配就停：json 里钉了五件输入的 sha256 与字节数，`dist` 另钉文件数、字节与树 sha256。
  换过 bundle 或 dist 的复算会以 `BUILD=FAIL reason=INPUT_IDENTITY` 收场，这是预期。
- `--record` 只回写 sha256 与字节数，不改 `path` 原文，所以不会把本机路径写进 json。
- 期望输出一行 `BUILD=PASS`，另两行给出两件的 `bytes` 与 `sha256`；任一项入身份不符即
  `BUILD=FAIL reason=...`、exit 1，输出目录零新文件。
- 核对方式：与同一版本的 `SHA256SUMS.txt`（或 Release 资产页）逐件 `sha256sum -c`；文件名是
  `openlist-txiki-<version>-linux-x86_64.tar.gz` 与 `openlist-txiki-<version>-win-x64.zip`。
- 组装器只做确定性重排与渲染，不重编 bundle、不重下 dist：要改 bundle 先走第 1 节。

## 4. 许可

上游与依赖的许可证全文见归档根与 `LICENSE`；第三方组件清单见
`scripts/THIRD-PARTY-NOTICES`。本源码归档对应 AGPL-3.0 源码要约，见 `scripts/SOURCE-OFFER`。
