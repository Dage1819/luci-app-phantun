# luci-app-phantun 项目总结（供跨会话续接）

> 把这份文件贴给新对话，或让助手读取它，即可无缝接上开发进度。

## 项目定位
LuCI 界面插件，管理 [Phantun](https://github.com/Dage1819/phantun)（UDP over FakeTCP 混淆工具）。
把 UDP 伪装成真实 TCP，穿透只允许 TCP / 对 UDP 限速封锁的网络，常配合 WireGuard 用。
参考同作者的姊妹项目 `luci-app-udp2raw-ultra`（在 `../luci-app-udp2raw-ultra`）对齐能力。

## 关键设计决策（重要，别推翻）
1. **不内置二进制，手动上传安装**（v1.4.0 起）：插件不调用 GitHub API、不下载、不解压、不测速。
   用户在「核心程序」页面看到本机目标 triple 和对应 ZIP 文件名，点链接跳转 Releases，在电脑上下载解压后，分别把 `phantun_client` / `phantun_server` ELF 文件上传到路由器。本地文件名不限，安装后自动命名为标准名称。后端验证 ELF magic（4 字节 `7f454c46`）拒绝 ZIP/文本/错误页。
   **废弃**：旧的 curl 竞速下载、镜像列表、GitHub API 查询、unzip 解压依赖——全部移除，不可恢复。
2. **地址族(family)**：只有**客户端**有（解析对端域名走 A/AAAA）；**服务端不选地址族**。
3. **自动防火墙**：只有**服务端**需要。勾选 `auto_fw` → 用 UCI 写 fw4 的端口转发（reload/重启不丢，网页端「端口转发」可见）。
   - v4/v6 **必须两条**（DNAT 目标不同：v4→`192.168.201.2`，v6→`fcc9::2`），服务端固定生成两条，用户不用选。
   - 去勾/停止/卸载自动清除（`phantun_` 前缀标识）。
   - **客户端不需要任何防火墙规则**。
4. **DNS 解析绕过代理**（bypass.sh）：防止隧道断开后 DNS 走隧道导致的重连死锁。有「外网接口」下拉配合。
5. **DDNS 域名监控**（monitor.sh）：客户端 remote 为域名 + 勾 monitor 时，定期重解析，IP 变化重启。

## 已修复的关键坑
- **auto_fw/Flag 不写入配置**：LuCI 的 Flag 等于默认值时不落配置 → 必须 `o.rmempty=false` 强制写入。
- **外网接口不能下拉**：load() 要加 `network.getNetworks()`，wan_iface 用 ListValue + networks 填充。
- **prerm/postrm/postinst 必须写在 `include luci.mk` 之前**。prerm 会被系统覆盖，清理放 postrm；postinst 用于 enable 服务。
- **EXTRA_DEPENDS 写 OR 依赖**（`bind-host | drill`），不能用 LUCI_DEPENDS 的 select（select 不支持 OR）。

## 文件结构
- `Makefile` — 依赖 kmod-tun + bind-host|drill；postinst(enable)/postrm(清理)；无 curl/unzip
- `build-packages.sh` — 本地构建 IPK/APK；CI 走 .github/workflows/build-apk.yml
- `root/etc/init.d/phantun` — 服务：family 解析、DNS bypass、nft apply、monitor、单规则控制
- `root/etc/config/phantun` — 默认配置
- `root/usr/share/phantun/manage.sh` — 架构检测、双核心状态、ELF 上传安装、规则诊断
- `root/usr/share/phantun/nftrules.sh` — 服务端自动防火墙（UCI 写 fw4，v4+v6 两条）
- `root/usr/share/phantun/monitor.sh` — DDNS 监控
- `root/usr/share/phantun/bypass.sh` — DNS 绕过代理
- `root/usr/share/rpcd/acl.d/luci-app-phantun.json` — ACL（manage.sh/init.d exec + 两个固定上传路径读写）
- `root/usr/share/luci/menu.d/luci-app-phantun.json` — 菜单（服务→Phantun）
- `htdocs/luci-static/resources/view/phantun/phantun.js` — 前端（手动上传状态卡/规则表/poll 实时刷新）

## 当前版本
v1.4.0（PKG_VERSION 在 Makefile）

### v1.2.0 变更
- 新增「服务端例外路由」（客户端选项）：WireGuard 全局代理场景下，为 Phantun 服务端 IP 添加走物理 WAN 的例外路由，破解死锁。
- 例外路由跟随解析；生命周期闭环（停止/取消勾选/卸载自动清除）。
- 修复 init.d 脚本 CRLF 换行导致在 OpenWrt 上无法运行的问题。

### v1.2.1 变更
- 修复 `route.sh` CLI 分支被 source 时意外触发 `exit 1` 杀死 init.d 进程的致命 bug。

### v1.2.2 变更
- **例外路由改为写 OpenWrt 标准静态路由**（`/etc/config/network`），可在 LuCI「静态路由」页面看到、核对、编辑。
- 网关解析加内核路由表兜底，修复 source-specific 默认路由环境下 IPv6 握手失败。

### v1.3.0 变更（诊断可见性）
- **握手状态**：基于 conntrack 实时显示握手成功/握手中/未连接。优先报告活跃 SYN，避免被 5 天 ESTABLISHED 旧条目误导。
- **查看日志**：弹窗过滤后日志（保留错误/超时/关闭，过滤每次重试噪音）。
- **域名解析 IP 显示**：规则列表直接显示当前传给 phantun 的解析 IP。
- 后端新增 `rule_conn`、`rule_resolved`、`rule_log` 子命令。

### v1.3.13 变更（构建/发布）
- 修复 GitHub Actions APK 构建流程：固定 apk-tools 提交、移除非法字段、正确验证 adbdump。
- 同时发布 IPK + APK 到同一 Release。
- CI strip CRLF 修复包版本号。

### v1.4.x 变更（手动上传核心，未发布）
- **彻底移除自动下载**：删除 curl/unzip 依赖，删除 mirrors/竞速/API/进度/版本跟踪/仓库切换所有代码。
- 新增 `manage.sh upload_info` 输出目标 triple、ZIP 名、Releases URL。
- 新增 `manage.sh install_binary <client|server> <固定临时路径>` 验证 ELF 并原子安装。
- 上传前后停止/重启受影响服务。
- LuCI 状态卡完全重写：显示核心状态（已就绪/缺少 client/缺少 server/未安装）、目标架构、预期 ZIP 名、Releases 链接、两个独立上传按钮（上传中禁用防并发）。
- ACL 增加两个固定临时路径的 read/write 权限。
- Makefile/build-packages.sh 依赖去掉 curl/unzip。
- init_status 返回值简化为 ready / missing:client / missing:server / missing。

## 已知问题 / 待查（IPv6 场景，跨会话记录）
排查过一次「客户端 phantun v6 握手失败」的故障。最终结论：服务端运营商骨干网 source-specific 路由导致回程 SYN+ACK 走了不匹配的出口，返回 ICMP6 destination unreachable。修复方法：在服务端添加不受源地址限制的 IPv6 默认路由：
```sh
ip -6 route add default via fe80::xxxx dev pppoe-wan metric 1024
```
插件层面无法检测此类路径问题；`/proc/net/nf_conntrack` 的 `[UNREPLIED]` 标记是最直接的判断依据。

## 构建 & 发布
- 构建：GitHub Actions `build-apk.yml`，自动产出 IPK + APK 并附到 Release。
- 仓库：`github.com/Dage1819/luci-app-phantun`
- **当前状态：改动未提交，不要推送或打标签，需先在真机验证手动上传流程。**

## 真机验证状态
- ✅ 服务端自动防火墙：勾选后生成 v4+v6 两条端口转发；去勾/停止自动清除。
- ✅ 客户端隧道零防火墙可通。
- ✅ 外网接口下拉、握手状态、规则日志弹窗。
- ✅ v1.3.13 APK 已在真机 `apk add --allow-untrusted` 安装成功。
- ⬜ 手动上传 phantun_client/phantun_server（v1.4.x 新功能，待真机验证）。
