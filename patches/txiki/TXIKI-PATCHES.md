# txiki.js 运行时补丁清单（r58）

基树：txiki.js `zig/v26.9.0` = commit `a07d6aa19553a61d088bbfbd7ac2ae204d2761a6`，
CRLF 工作区（`core.autocrlf=true`）。`deps/libwebsockets` 为子模块 `ac23cae7`。

| 补丁 | 字节 | sha256 | apply 根 | 说明 |
|---|---:|---|---|---|
| `lws-mbedtls-client-alpn-uaf.patch` | 1678 | `2d7fb0edf820de8b361da612ce8404e45dcaf65e5f2b2f8cf327d259ed96a069` | deps/libwebsockets | CMake tjs_apply_patches(lws-) 自动 |
| `lws-uri-encoding.patch` | 1351 | `194839572d4539fd6888d809cbeb754af9edbb7c3ee84699be5e310b1357de81` | deps/libwebsockets | CMake tjs_apply_patches(lws-) 自动；路径里 + 不转空格 |
| `mbedtls-quic.patch` | 27768 | `3302af5406ecf3eefb1c9a2e13dbea36ceb2ed2edad88b410983798184600cab` | deps/mbedtls | CMake tjs_apply_patches(mbedtls-) 自动 |
| `mbedtls-tls12-pss.patch` | 1246 | `cd1d269777facec3a07c3b0549c451c4b9d8278b8e4593e50fd9da85adbdae98` | deps/mbedtls | CMake tjs_apply_patches(mbedtls-) 自动；需 05 build-wiring 才进编译 |
| `wamr-zig.patch` | 2817 | `55862c538f01772ed133d74500c096fa1b6da1a7a0ce687e36ebfcfb4bee3b1f` | 树根 | 构建修补 |
| `libffi-aarch64-windows.patch` | 628 | `26b1eed04ead7e05eda525e5a30218bbc95d2d407589222d6642f1184bcb1088` | 树根 | 仅 aarch64-windows 目标；本版三目标不打 |
| `s1a-c21-5.0.0.patch` | 610765 | `e4e53249fcc7f09cdf05819cddbee94d33077e02b9e53fb17d3b182f1eb29218` | 树根 | 手工段 1；含 deps/libwebsockets 8 文件 + src/httpserver.c；CRLF 上下文，patch 2.8/git apply CRLF 树 |
| `s1b-backpressure.patch` | 20531 | `d1b0a52adf94abfd351c8a3cf7c2e0b544b0be11f18addd6be4cb24e286dac54` | 树根 | 手工段 2；src/httpserver.c + src/js/core/httpserver.js |
| `s1b-core.c` | 461419 | `1fc67813460dcd2b8ad0c955b735abc879ccd4ce9f2b9b3ea698107638c3a411` | src/bundles/c/core/core.c | 生成物（非补丁）：用 tjsc 从 s1b 的 core.js 重生成后覆盖；本归档附 1fc67813… 版本 |
| `txiki-wasm-module.patch` | 516 | `74aa1747ce9dfd6ad7309bc91c719604d59e0d5116e18589bb07f3815bd01d8f` | 树根 | A1；src/js/polyfills/wasm.js 的 Module 实例化 |
| `05-mbedtls-build-wiring.patch` | 473 | `7358a8e2eba216c49e31925db33e402d1cf4cb19528d63564cf1832615f28928` | 树根 | deps/build/mbedtls/build.zig 一行，让 PSS 补丁进编译 |
| `p6-stream-body.patch` | 6901 | `88870627eefbd3ca7bcb91c5992ba8170ba7cb453756d0332d4af759a0a9b5ce` | 树根 | 手工段 3；src/httpserver.c（须在 s1b 之后） |
| `p6b-abort-incomplete-body.patch` | 2444 | `893c647e7d09aa6c8b2aff95ef7a84a5029f5a9bbfbd7c29fe9bb3ace28aafe1` | 树根 | 手工段 4；src/httpserver.c（须在 p6 之后） |
| `0002-txiki-decoded-path.patch` | 7258 | `871d9e38e60a5490361d4f0da0bca2c9878ccc363154086c2e6da8b3cf8f398d` | 树根 | 手工段 5；p6/s1a/s1b 之后用 git apply --3way（plain 上下文对不上）；产品侧 0003/0004 = patches/openlist/48、49 |
| `zerocopy-http-file-body.patch` | 14953 | `fdc2583f4c5672f16ba2bfd3b660161f05a1141a8f5f79b8bd5bb91e9b947bcf` | 树根 | 手工段 6；r4 零拷贝 C 侧（pre-image 1a825acf，post c4bd7a0c）；须在 0002 之后 |
| `zerocopy-httpserver-js.patch` | 1961 | `9e39747cf0dd4cd5fbb20ab56e9982cfbe5b0806603eafb30ec552ca18c80a5e` | 树根 | 手工段 6；r4 零拷贝 JS 侧（pre-image 79a9c67b，post f13a2753）；与 C 侧同批 |
| `f1f5-on-c4bd7a0c.patch` | 6287 | `f5f861c1133c2271f48452401d066cef393f90ac3d2141895433413ceda313c3` | 树根 | 手工段 7；F1-F5 修复（pre-image c4bd7a0c，post c657534d）；须在 zerocopy 两件之后 |

## 顺序

1. CMake 自动段：`deps/*` 的 `lws-*` / `mbedtls-*` 由 `CMakeLists.txt` 的
   `tjs_apply_patches()` 在 configure/build 时自动打；`wamr-zig`、`libffi-aarch64-windows` 按目标使用。
2. 手工段（必须按序）：`s1a` -> `s1b` -> `p6` -> `p6b` -> `lws-uri-encoding`（在子模块根）
   -> `0002`（`git apply --3way`）。A1（`txiki-wasm-module.patch`）与 05（`05-mbedtls-build-wiring.patch`）
   不与其他补丁重叠，可在 s1a 前或后。
3. r53 零拷贝段（必须按序，在手工段 5 之后）：`zerocopy-http-file-body`（C）
   -> `zerocopy-httpserver-js`（JS）-> `f1f5-on-c4bd7a0c`（F1-F5 修复）。
   应用顺序与 pre/post sha 见本表说明；三段串起来把 r3 的 `1a825acf` / `79a9c67b`
   推到 r4 的 `c657534d` / `f13a2753`。
4. `s1b-core.c` 不是补丁：它是 s1b 的 JS 侧经 tjsc 编译出的 `src/bundles/c/core/core.c`，
   覆盖同名文件即可；本归档附的版本 sha256 以本表为准。

## 不在补丁栈内的构建树内容

- 无。r45 起构建树用到的 tjs 侧改动全部有补丁实体或生成物实体落在本目录；
  `0003-openlist-wirepath-decoded` 与 `0004-canonical-path-tests` 属产品侧，落在
  `patches/openlist/48`、`49`（在 53 条累进栈内）；r54 的 `raw.ts` HEAD 短路同为产品侧
  补丁，落在 `patches/openlist/53`，不属于本目录的 tjs 补丁栈。r56 的 F10/F11 属产品侧补丁，
  落在 `patches/openlist/54`、`55`；r57 的四处驱动修复属产品侧补丁，落在
  `patches/openlist/56`..`59`。r55 的 Range 收尾修复
  是 `src/backend/txiki/shims/fs.ts`（src=repo，适配层自有文件，源码指纹清单登记），
  不是补丁，也不属于本目录的 tjs 补丁栈。
- 仍未归档的是 txiki.js 上游源码树本体（415 MB 级 CRLF 检出），由上游 tag 提供，
  按 `docs/BUILD.md` 第 2 节 clone 即可；这不属于本项目改动的缺口。
