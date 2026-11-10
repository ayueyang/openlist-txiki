# openlist-txiki

把 [OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker)（TypeScript + Hono，AGPL-3.0）移植到 [txiki.js](https://github.com/saghul/txiki.js) 运行时，产出：

- **OpenWrt apk**（aarch64，自带私有 tjs，不依赖系统 txiki；另有共享 tjs 版本）
- **独立可执行运行时 + 应用包**：Linux（aarch64 / x86_64）与 Windows（x86_64），下载后直接 `tjs run openlist-txiki.js` 就能起服务

不是 OpenList Go 版的重写。上游的存储驱动、WebDAV、分享、任务逻辑都保留，只把运行时从 Workers 换成 txiki.js。

## 本版（0.1.0-r67）

- 补丁栈 91 条。本版新增四条驱动收敛补丁：
  - WPS 上传只做 fail-closed：没有上传实现时明确报错，不再出现「元数据标了 no_upload、上传却假成功」（补丁 88）。
  - 微云列表去掉 45 页预算上限，保留 count=500 分页与结束标志/空页终止条件（补丁 89）。
  - Yandex 的 use_online_api 默认 false，默认直连 oauth.yandex.com；在线刷新只在显式开启时走，并打告警（补丁 90）。
  - WoPan 的 init family 探测 fail-closed，缺 defaultHomeId 也抛错；坏凭据不会留下能列出空目录的假挂载（补丁 91）。
- 设备实测（Nokia XG-040G-MF，用包内 tjs 起隔离实例）：
  - 冷启中位 1,312 ms（n=3，极差 6 ms）。
  - 空闲 VmRSS 25,036 kB（120 s 后 n=3，极差 0）。
  - 64 MiB 下载中位 119.98 MiB/s（n=9，9/9 sha 一致）；上传中位 27.35 MiB/s（n=3，3/3 落盘 sha 一致）。
  - Range 206/416 语义正确，含整段 Range 与小文件越界。
- 验证面：静态检查 12 项、设备回归 88 项，0 失败。设备 88 项 = 77 通过 + 4 通过另带说明 + 6 已知限制 + 1 无账号未验证。

### 本版已知限制

- 微云 22,000 条目录覆盖缺口：本版没有真实微云账号，补丁 89 的运行面未闭环。补丁删掉了列表预算分支及其 8 处预算计数引用；发行包里残留的 `Cloudflare Worker subrequest budget` 字样经复核属 189Cloud 上下文，不是微云残留。解除条件：一个可用的微云 cookie 加一份 22,000 条目录夹具，跑一次列表看是否到第 22,000 条。
- Range 64 MiB：在 MemAvailable 78,572 kB 的隔离实例上，`Range: bytes=0-67108863` 会触发既有的 range fixup skip 路径，进程可能被 OOM 杀掉。该路径在 r66 的发行包里同样存在，不是本版退化。最小复现：低内存环境 + 64 MiB 文件 + 整段 Range。
- 189pc 驱动未接线（发行包里没有该驱动代码）；真实云盘账号未覆盖：115、阿里云盘、139、微云、WPS、WoPan 等只用 mock 或坏凭据验证过，没在真实账号上跑。
- WPS 没有真实 cookie：fail-closed 只在凭据/网络环节验过（明确失败、无落盘），没走到代码里的 not implemented 抛错行。
- 浏览器前端交互、WebDAV LOCK/UNLOCK、并发同名写、长时压测与多流并发未验证（本版设备门只做单流）。
- 本 Release 只含 OpenWrt apk、源码包与 txiki-js apk，未附 Linux / Windows 桌面归档。
- shared 版依赖系统 txiki-js>=26.9.0；设备上系统包是 26.9.0-r3，本 Release 另附 r4，两者差异未逐项验证。
- 三条沿用自 r61 的上游行为差异：删不存在的项回 200 success（Go 版为 500）；列不存在的目录回 200 空列表；WebDAV PUT 自动建父目录回 201。

## 现在能做什么

在 Nokia XG-040G-MF（Airoha AN7583DT，双核 A53，512MB RAM）上实测过：

- 5244 端口跑着本项目的 r66 安装树，与 alist-encrypt（5344）并存；本包默认 5345，可与它们共存
- 登录、列目录、下载与 Range（1GB 单文件下载 sha 一致，峰值内存无增长）
- WebDAV 服务端（只读 + 写方法）与 WebDAV 客户端驱动
- 上传流式落盘，不把整文件读进内存
- 复制任务（SQLite 持久化、进度、取消，重启后无僵尸任务）
- 整机重启后数据与登录都还在

## 网盘适配状态

按实测结论分档，只写跑过的，不写猜的：

| 网盘 | 驱动 | 状态 | 说明 |
|---|---|---|---|
| 本地目录 | Local | 已适配 | 读写、Range、重启存活均已验 |
| WebDAV | WebDAV | 已适配 | 服务端与客户端驱动都验过 |
| S3 | S3 | 已适配 | 读写与删除已验 |
| 百度网盘 | BaiduNetdisk | 已适配 | refresh_token + access_token，可列目录与下载 |
| 天翼云盘 | 189 | 基础可用（缺可用恢复路径） | 登录首跳用系统 curl 兜底；会话失效后重登不成立，IP 变化会报 check ip error |
| 夸克网盘 | Quark | 基础可用（缺恢复路径） | cookie 认证，能列目录与取链；服务端下发的 cookie 更新未落库，重启后可能需重新粘贴 |
| 阿里云盘 Open | AliyundriveOpen | 基础可用（缺恢复路径） | 中转刷新已改成 POST JSON；新 refresh_token 未落库，重启后可能挂载失败 |
| 115 网盘 | 115（cookie 版） | 待适配 | 现有实现是 Open API 版，cookie/TV 扫码版待移植 |
| 百度网盘青春版 | BaiduYouth | 不支持 | 没有这个驱动，建议用会员版 |
| 其余 70+ 驱动 | — | 未验证 | 需要具体账号与用例，按需逐个适配 |

云端驱动一律要你自己的凭据（cookie 或 refresh_token），我们不提供也不代持；cookie 类会过期，过期后要重新取。

## 安装（OpenWrt，aarch64）

```sh
apk add --allow-untrusted ./openlist-txiki-0.1.0-r67.apk
cat /etc/openlist-txiki/admin.pass          # 初始管理员口令，权限 600
/etc/init.d/openlist-txiki start
curl -s http://127.0.0.1:5345/api/public/settings
```

本版四个包（同一份应用，区别在前端大小与是否自带 tjs 运行时）：

| 文件 | 字节 | 说明 |
|---|---:|---|
| openlist-txiki-0.1.0-r67.apk | 26,454,792 | standard，自带 tjs，完整前端 |
| openlist-txiki-0.1.0-r67-lite.apk | 8,882,958 | lite，自带 tjs，精简前端 |
| openlist-txiki-0.1.0-r67-shared-tjs.apk | 21,127,009 | standard，共享系统 tjs |
| openlist-txiki-0.1.0-r67-lite-shared-tjs.apk | 3,553,754 | lite，共享系统 tjs |

shared 版本依赖系统里的 txiki-js>=26.9.0，可用本 Release 附带的 txiki-js-26.9.0-r4.apk。

验签：Release 附 openlist-txiki.rsa.pub。把公钥拷进 `/etc/apk/keys/` 后，`apk add ./openlist-txiki-0.1.0-r67.apk` 会正常验签；`--allow-untrusted` 是跳过验签的装法。

升级与卸载：

```sh
apk add --allow-untrusted --upgrade ./openlist-txiki-<新版本>.apk
apk del openlist-txiki                       # 数据目录 /etc/openlist-txiki 保留
```

数据（data.db、admin.pass、openlist-txiki.env、rollback/）都在 `/etc/openlist-txiki`，升级不覆盖用户改过的 env。默认只监听 `127.0.0.1:5345`；要在局域网用，改 `/etc/openlist-txiki/openlist-txiki.env` 的 `LISTEN_ADDR` 后重启服务，同时换掉初始口令。

## 单独下载 txiki 运行时

运行时单独发布（aarch64 / x86_64 Linux musl、x86_64 Windows），适合系统里已经有 txiki 的用户：

下载页：<https://github.com/ayueyang/openlist-txiki/releases/tag/txiki-runtime-v26.9.0>

本版 Release 另附 OpenWrt 的 `txiki-js-26.9.0-r4.apk`，供 shared 版安装。运行时是 26.9.0 定制构建，带流式请求体、断流处理、TLS PSS 等补丁；低于 26.9.0 的运行时无法加载当前字节码。

## 独立运行（Windows / Linux）

```sh
tjs run openlist-txiki.js
```

需要设置的环境变量见 `docs/INSTALL.md`。

## 从源码构建

见 [`docs/BUILD.md`](docs/BUILD.md)：固定上游 commit 5f53f58、91 个应用补丁、tjs 运行时补丁清单（apply 顺序见 `patches/txiki/TXIKI-PATCHES.md`）、构建脚本与校验方式都在仓库里。每个 Release 附源码包与 `SOURCE-OFFER`。

## 许可证

本项目是 OpenList-Worker 的衍生作品，按 **AGPL-3.0** 发布。补丁与构建脚本在 `patches/`、`build/`，对应源码的获取方式见 [`NOTICE.md`](NOTICE.md) 与每个 Release 附带的 source tarball。

> 这是个人自用向的移植，不隶属于 OpenListTeam，也不代表上游立场。

## 联系

问题与建议：<https://github.com/ayueyang/openlist-txiki/issues>
