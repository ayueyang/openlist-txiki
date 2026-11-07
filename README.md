# openlist-txiki

把 [OpenList-Worker](https://github.com/OpenListTeam/OpenList-Worker)（TypeScript + Hono，AGPL-3.0）移植到 [txiki.js](https://github.com/saghul/txiki.js) 运行时，产出：

- **OpenWrt apk**（aarch64，自带私有 tjs，不依赖系统 txiki）
- **独立可执行运行时 + 应用包**：Linux（aarch64 / x86_64）与 Windows（x86_64），下载后直接 `tjs run openlist-txiki.js` 就能起服务

不是 OpenList Go 版的重写。上游的存储驱动、WebDAV、分享、任务逻辑都保留，只把运行时从 Workers 换成 txiki.js。

## 现在能做什么

在 Nokia XG-040G-MF（Airoha AN7583DT，双核 A53，512MB RAM）上实测过：

- 与 Go 版 OpenList（5244）、alist-encrypt（5344）**并存**，本包默认 5345
- 登录、列目录、下载与 Range（含 1GB 真传、sha 一致、峰值内存零增长）
- WebDAV 服务端（只读 + 写方法）与 WebDAV 客户端驱动
- 上传流式落盘：8MiB / 16MiB 单次请求的 VmHWM 增量分别 864kB / 892kB
- 复制任务（SQLite 持久化、进度、取消，重启后无僵尸任务）
- 整机重启后数据与登录都还在
- 装机 68.3MB（含 452 个前端静态文件；Go 版约 51MB）

## 网盘适配状态

按实测结论分三档，**只写跑过的，不写猜的**：

| 网盘 | 驱动 | 状态 | 修复队列 | 说明 |
|---|---|---|---|---|
| 本地目录 | Local | 已适配 | — | 读写、Range、重启存活均已验 |
| WebDAV | WebDAV | 已适配 | — | 服务端与客户端驱动都验过 |
| S3 | S3 | 已适配 | — | 读写与删除已验 |
| 百度网盘 | BaiduNetdisk | 已适配 | — | refresh_token + access_token，可列目录与下载 |
| 天翼云盘 | 189 | 基础可用（缺可用恢复路径） | 3（189pc） | 登录首跳已用 curl 兜底；登录三步仍走 fetch，会话失效后重登不成立，IP 变化会报 check ip error |
| 夸克网盘 | Quark | 基础可用（缺恢复路径） | 1 | cookie 认证，能列目录与取链；服务端下发的 cookie 更新未落库，重启后可能需重新粘贴 |
| 阿里云盘 Open | AliyundriveOpen | 基础可用（缺恢复路径） | 2 | 中转刷新已改成 POST JSON；新 refresh_token 未落库，重启后可能挂载失败 |
| 115 网盘 | 115（cookie 版） | 待适配 | 4（二维码登录） | 现有实现是 Open API 版，cookie/TV 扫码版需移植 |
| 百度网盘青春版 | BaiduYouth | 不支持 | — | cookie 驱动未移植，建议改用会员版 |
| 其余 70+ 驱动 | — | 未验证 | — | 需要具体账号与用例，按需逐个适配 |

需要说明的两点：云端驱动一律要你自己的凭据（cookie 或 refresh_token），我们不提供也不代持；cookie 类会过期，过期后要重新取。

队列号只表示修复先后，不改变本表的状态列。

## 已知限制

- **默认只监听 `127.0.0.1:5345`**。要在局域网用，改 `/etc/openlist-txiki/openlist-txiki.env` 的 `LISTEN_ADDR` 后重启服务，同时换掉初始口令。
- **包内带完整前端**（OpenList-Frontend v4.2.7，452 个文件，约 55.8MB），浏览器直接可用；不追随前端新版。
- **分发**：按公开分发口径发布（AGPL-3.0）；每个 Release 附源码包与 `SOURCE-OFFER`，许可证全文随包。
- 天翼云盘 189 的登录首跳对 tjs 的 TLS 指纹不友好（返回登录页空壳而非跳转），现由设备自带 curl 完成那两跳、其余请求仍走 tjs；因此该驱动依赖系统里有 `curl`。
- 归档重建（从零 clone 上游再打补丁）需要把树放在同一绝对路径，因为 tjs 源码路径会进二进制；细节见 `docs/BUILD.md`。

## 安装（OpenWrt，aarch64）

```sh
apk add --allow-untrusted ./openlist-txiki-<版本>.apk
cat /etc/openlist-txiki/admin.pass          # 初始管理员口令，权限 600
/etc/init.d/openlist-txiki start
curl -s http://127.0.0.1:5345/api/public/settings
```

升级与卸载：

```sh
apk add --allow-untrusted --upgrade ./openlist-txiki-<新版本>.apk
apk del openlist-txiki                       # 数据目录 /etc/openlist-txiki 保留
```

数据（`data.db`、`admin.pass`、`openlist-txiki.env`、`rollback/`）都在 `/etc/openlist-txiki`，升级不覆盖用户改过的 env。

## 单独下载 txiki 运行时

运行时也单独发布，三个平台各一个文件，适合已装 alist-encrypt、系统里已有 txiki 的用户，不必再带第二份：

- `tjs-aarch64-linux-musl`（OpenWrt / aarch64）
- `tjs-x86_64-linux-musl`（Linux）
- `tjs-x86_64-windows.exe`（Windows）

下载页：<https://github.com/ayueyang/openlist-txiki/releases/tag/txiki-runtime-v26.9.0>

注意：本运行时是 26.9.0 定制构建，带 6 个补丁（流式请求体、断流处理、TLS PSS 等），并支持 QuickJS-ng 字节码版本 27；低于 26.9.0 的运行时无法加载 r40 之后的字节码形态。

## 独立运行（Windows / Linux）

```sh
tjs run openlist-txiki.js
```

需要设置的环境变量见 `docs/INSTALL.md`。

## 从源码构建

见 [`docs/BUILD.md`](docs/BUILD.md)：固定上游 commit、53 个应用补丁、tjs 运行时补丁全集（apply 顺序见 patches/txiki/TXIKI-PATCHES.md，其中 1 个仅 aarch64-windows 用，本版三目标不发）、构建脚本与校验方式都在仓库里。

## 许可证

本项目是 OpenList-Worker 的衍生作品，按 **AGPL-3.0** 发布。补丁与构建脚本在 `patches/`、`build/`，对应源码的获取方式见 [`NOTICE.md`](NOTICE.md) 与每个 Release 附带的 source tarball。

> 这是个人自用向的移植，不隶属于 OpenListTeam，也不代表上游立场。
