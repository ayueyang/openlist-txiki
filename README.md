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
- 包体积 3.2MB，装机 7.4MB（Go 版约 51MB）

驱动状态：Local、WebDAV、S3、百度网盘会员（只读）已验证；其余云端驱动需要你自己的凭据。

## 已知限制

- **默认只监听 `127.0.0.1:5345`**。要在局域网用，改 `/etc/openlist-txiki/openlist-txiki.env` 的 `LISTEN_ADDR` 后重启服务，同时换掉初始口令。
- **包内不含前端 SPA**，只有 API 和 WebDAV；要用网页界面得自己构建前端并另行部署。
- **分发**：按公开分发口径发布（AGPL-3.0）；每个 Release 附源码包与 `SOURCE-OFFER`，许可证全文随包。
- 天翼云盘 189 目前不通：驱动请求拿到的是 200 页面而非登录跳转，属上游风控，不是移植缺陷。
- 归档重建（从零 clone 上游再打补丁）需要把树放在同一绝对路径，因为 tjs 源码路径会进二进制；细节见 `docs/BUILD.md`。

## 安装（OpenWrt，aarch64）

```sh
apk add ./openlist-txiki-<版本>-aarch64.apk
cat /etc/openlist-txiki/admin.pass          # 初始管理员口令，权限 600
/etc/init.d/openlist-txiki start
curl -s http://127.0.0.1:5345/api/public/settings
```

升级与卸载：

```sh
apk add --upgrade ./openlist-txiki-<新版本>.apk
apk del openlist-txiki                       # 数据目录 /etc/openlist-txiki 保留
```

数据（`data.db`、`admin.pass`、`openlist-txiki.env`、`rollback/`）都在 `/etc/openlist-txiki`，升级不覆盖用户改过的 env。

## 独立运行（Windows / Linux）

```sh
tjs run openlist-txiki.js
```

需要设置的环境变量见 `docs/INSTALL.md`。

## 从源码构建

见 [`docs/BUILD.md`](docs/BUILD.md)：固定上游 commit、21 个应用补丁、6 个 tjs 补丁、构建脚本与校验方式都在仓库里。

## 许可证

本项目是 OpenList-Worker 的衍生作品，按 **AGPL-3.0** 发布。补丁与构建脚本在 `patches/`、`build/`，对应源码的获取方式见 [`NOTICE.md`](NOTICE.md) 与每个 Release 附带的 source tarball。

> 这是个人自用向的移植，不隶属于 OpenListTeam，也不代表上游立场。
