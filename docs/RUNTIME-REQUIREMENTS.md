# openlist-txiki shared-tjs 变体：系统运行时要求清单

版本：2026-11-03，对应 openlist-txiki 0.1.0-r34（shared-tjs，bundle sha256 `49ba24b7…a210924`）。

> 说明：本文来自构建仓的运行时要求清单（对应 openlist-txiki 0.1.0-r34 shared-tjs）。
> 文中 `artifacts/…`、`findings.md`、`work/…` 是构建仓内部证据路径，公开仓不包含这些文件；
> 补丁本体在 `patches/txiki/` 的按文件名对照，s1a/s1b 两份见第 2 节说明。

## 0. 结论先行

1. **最低版本是 txiki.js 26.9.0，26.6.0 跑不了。** 不是补丁多少的问题：bundle 静态导入
   `tjs:sqlite` 的 `AsyncDatabase`，这是 26.9 才有的模块导出。设备实测（26.6.0-r3，
   4,002,561 B，sha `7be5516f…`）直接报
   `SyntaxError: Could not find export 'AsyncDatabase' in module 'tjs:sqlite'`，进程起不来。
2. **26.9.0 也不是装上就能等价。** 我们发布的运行时是
   `26.9.0 @ a07d6aa + s1a + s1b + s1b 的 core.c + patches/txiki 下 6 个补丁`，
   产物 5,282,808 B、sha `4b931f66…f74693`。缺 s1a，WebDAV 的 PROPFIND/MKCOL/COPY/MOVE
   会被 lws 直接 403（handler 进不去）；缺 s1b，下载内存随文件大小线性涨。
3. **把 26.6.0 打成 26.9.0 等价，仓库里没有这条路。** 需要移植异步 SQLite（线程池）本身，
   不是一条 diff；本仓没有这个补丁，也不在本次交付范围。可行路线只有：系统 txiki-js 包
   升到 26.9.0 基线，再并下面这些补丁。

## 1. patches/txiki/ 下的补丁（公开仓路径）

| 文件 | 解决什么 | 不打会退化成什么样（带数字） |
|---|---|---|
| `p6-stream-body.patch` | Content-Length 大于 1 MiB 的请求体改走流式交给 JS，不再整包缓冲 | 8 MiB PUT 的 ΔVmHWM **22,208 kB（2.711 倍）**、16 MiB **43,308 kB（2.643 倍）**；打后同一夹具 **864 kB / 892 kB**（25.7 倍 / 48.5 倍）。来源：`artifacts/p117-spike-0500/README.md:19-20,75-77` 与 `artifacts/p117-ab-2002/README.md:11,55-56` |
| `p6b-abort-incomplete-body.patch` | chunked PUT 中途断连时把 JS body stream 置错，应用侧 abort，不提交半截文件 | 断连后目标路径会留下文件（0 字节或半截），客户端可能拿到“成功”；打后同一探针目标不存在、临时目录 0。来源：`artifacts/p117-ab-2002/README.md` §3.5（X1TC：dst=有 → 6db0cfce 上 dst=无） |
| `mbedtls-tls12-pss.patch` | TLS 1.2 客户端按值接受 `rsa_pss_rsae_sha256/384/512`（0x0804/0x0805/0x0806） | 服务端选 TLS1.2+PSS 时客户端回 fatal alert 47、握手 `-26112 ILLEGAL_PARAMETER`：百度 pan/api/www 与 open.e.189.cn 全挂，189/百度驱动不可用。打后六域名矩阵 4 个失败域名变 200/405/200/200，2 个对照不变。来源：`findings.md:1949-2005`、`artifacts/t1-tls-20261022/` |
| `lws-mbedtls-client-alpn-uaf.patch` | 修 `lws_ssl_client_bio_create()` 的 ALPN 栈 use-after-scope（QUIC→TCP fallback 路径） | 未定义行为，ASAN 报 stack-use-after-scope；平时靠栈槽没被复用“碰巧能跑”，fallback 时可能崩。没有可量化的性能退化，属于正确性/稳定性缺陷。来源：补丁头注释（上游 commit 3f2669cc） |
| `mbedtls-quic.patch` | 给 mbedtls 打开 `MBEDTLS_SSL_LWS_QUIC_SUPPORT`，供 LWS 的 QUIC 传输使用 | 构建若开 LWS QUIC/H3，这条不打会编不过或没有 QUIC 支持；只用 TCP 的部署不受影响。来源：补丁本体 |
| `wamr-zig.patch` | WAMR 在 darwin/windows 的构建修补 | 只影响 macOS/Windows 目标；Linux aarch64 不受影响。来源：补丁本体 |
| `libffi-aarch64-windows.patch` | aarch64-windows 的 libffi cache flush 顺序 | 只有 aarch64-windows 目标需要；本版发布的三个目标（aarch64-linux-musl / x86_64-linux-musl / x86_64-windows）都不打它。来源：`docs/BUILD.md` §2 |

## 2. 不在 patches/txiki/、但发布运行时里必须有的东西

这几项是公开仓 `patches/txiki/` 目录**没有**的，必须一并并进系统 txiki-js 包，否则不等价：

| 项 | 位置 | 解决什么 | 不打会退化成什么样 |
|---|---|---|---|
| `s1a-c21-5.0.0.patch` | 本仓 `work/s1a-c21-5.0.0.patch`（610,765 B，sha `e4e53249…`） | lws 方法表加 PROPFIND/MKCOL/COPY/MOVE | WebDAV 方法在 lws 层被拒 **403**，handler 根本进不去；PROPFIND 拿不到 207。来源：`findings.md:458,5650` |
| `s1b-backpressure.patch` + `s1b-core.c` | 本仓 `work/s1b-backpressure.patch`（20,531 B，sha `d1b0a52a…`）、`work/s1b-core.c`（461,419 B，sha `1fc67813…`） | 响应流式写背压 | 下载内存随文件线性涨：32 MB 下载 ΔVmHWM **+41 MB**、64 MB **+73 MB**、1 GB 在 96.8 MB 处截断（curl rc=18）；打后 1 GB 两跳 65.0 s、传输期 VmHWM **+0 kB**、RSS +468 kB。来源：`findings.md:305,353,369,548` |
| `AsyncDatabase`（26.9 基线） | txiki.js 26.9 的 `tjs:sqlite` | 应用数据库访问 | 26.6.0 上 bundle 加载即失败：`SyntaxError: Could not find export 'AsyncDatabase' in module 'tjs:sqlite'`（本次设备实测，见交付 raw/05） |

## 3. 最低版本判定

- `tjs --version` 必须 **>= 26.9.0**。shared 变体的 init 会在启动前跑这个判断，
  低于要求直接拒绝启动并在 syslog 写明版本（本次实测：26.6.0 被拒，rc=1）。
- apk 侧同时声明 `Depends: txiki-js>=26.9.0`，装包阶段就会挡住 26.6.0
  （本次设备 `apk add --simulate` 原文：`txiki-js-26.6.0-r3 breaks: openlist-txiki-0.1.0-r34[txiki-js>=26.9.0]`）。
- 若你的 txiki-js 包仍按 26.6.0 版本号发布，但源码已经升到 26.9 基线：请把包版本改成
  26.9.0 或更高，否则 apk 依赖和 init 版本闸都会拒绝。版本号是判据，不读二进制里的字符串。

## 4. 构建顺序与已知坑

1. 基线：`qwtel/txiki-js` `a07d6aa19553a61d088bbfbd7ac2ae204d2761a6`，**CRLF 检出**
   （`core.autocrlf=true`）。补丁上下文是 CRLF，LF 检出会大面积 `different line endings`。
2. 顺序：`s1a` → `s1b` →（`s1b-core.c` 覆盖 `src/bundles/c/core/core.c`）→
   `mbedtls-quic` → `mbedtls-tls12-pss` → `p6-stream-body` → `p6b-abort-incomplete-body`
   → `lws-mbedtls-client-alpn-uaf` → `wamr-zig`。PSS 必须在 quic 之后打，顺序错会打出
   另一份源码但 rc=0（`findings.md:4219`）。
3. 改了 `src/js/core/*.js`（p6 会改 `httpserver.js`）必须重生成 `core.c`：
   esbuild 打 `src/js/core/index.js`，再 `tjsc -m -s` 打 `core.c`；直接编旧 `core.c`
   等于补丁没进 JS 侧。
4. 构建路径会进二进制（约 170 条绝对路径字符串），换路径 sha 必变；要逐字节复现发布件
   必须把树放在 `/home/admin/txiki-merged`，或 `unshare -m` + `mount --bind` 挂到该路径。
5. 目标 aarch64-linux-musl 用 Zig 0.16.0；本版发布件是 `-Doptimize=ReleaseSmall`。

## 5. 等价性怎么验（最少四条）

1. `tjs --version` 输出 `v26.9.0`（或更高）。
2. WebDAV：`curl -X PROPFIND -H "Depth: 1" -u admin:<pass> http://127.0.0.1:<port>/dav/<mount>/`
   返回 **207**（不是 403）。
3. 上传内存：8 MiB 带 Content-Length 的 WebDAV PUT，ΔVmHWM 应在 **1 MB 量级**
   （我们实测 864 kB），不是 22 MB。
4. 下载内存：32 MB 单流下载，ΔVmHWM 应远小于 16 MB（我们 1 GB 实测 +0 kB），
   不是 +41 MB。
