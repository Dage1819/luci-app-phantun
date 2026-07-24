# luci-app-phantun 项目总结（供跨会话续接）

> 把这份文件贴给新对话，或让助手读取它，即可无缝接上开发进度。

## 项目定位
LuCI 界面插件，管理 [Phantun](https://github.com/dndx/phantun)（UDP over FakeTCP 混淆工具）。
把 UDP 伪装成真实 TCP，穿透只允许 TCP / 对 UDP 限速封锁的网络，常配合 WireGuard 用。
参考同作者的姊妹项目 `luci-app-udp2raw-ultra`（在 `../luci-app-udp2raw-ultra`）对齐能力。

## 关键设计决策（重要，别推翻）
1. **不内置二进制**：首次点「初始化」，按架构从 GitHub 下载官方 release（.zip），插件轻量、适配任意内核。
2. **下载策略**：curl 并发 HEAD 竞速选最快镜像 → 停滞超时下载（`--speed-time 30 --speed-limit 2048`，无总超时，慢速不误杀）→ 失败自动轮询下一节点 → 直连 GitHub 作最后备援。gh-proxy.cn 已确认坏（压缩斜杠 404），已移除；gh.ddlc.top 可用。
3. **解压**：官方是 .zip，依赖 `unzip`（Makefile 声明 + 运行时兜底自动装）。
4. **地址族(family)**：只有**客户端**有（解析对端域名走 A/AAAA）；**服务端不选地址族**。
5. **自动防火墙**：只有**服务端**需要。勾选 `auto_fw` → 用 UCI 写 fw4 的端口转发（reload/重启不丢，网页端「端口转发」可见）。
   - v4/v6 **必须两条**（DNAT 目标不同：v4→`192.168.201.2`，v6→`fcc9::2`），服务端固定生成两条，用户不用选。
   - 去勾/停止/卸载自动清除（`phantun_` 前缀标识）。
   - **客户端不需要任何防火墙规则**（本机 WG→本机 phantun→出 wan，走 output/input 不走 forward，wan 默认 masq 兜底）。
6. **DNS 解析绕过代理**（bypass.sh，独立路由表 994）：防止隧道断开后 DNS 走隧道导致的重连死锁。有「外网接口」下拉配合。
7. **DDNS 域名监控**（monitor.sh）：客户端 remote 为域名 + 勾 monitor 时，定期重解析，IP 变化重启。

## 已修复的关键坑
- **auto_fw/Flag 不写入配置**：LuCI 的 Flag 等于默认值时不落配置 → 必须 `o.rmempty=false` 强制写入。（这是"自动防火墙勾了没生成规则"的真因）
- **外网接口不能下拉**：load() 要加 `network.getNetworks()`，wan_iface 用 ListValue + networks 填充。
- **prerm/postrm/postinst 必须写在 `include luci.mk` 之前**（luci.mk 在 include 时就 BuildPackage）。prerm 会被系统自动生成覆盖，故清理放 postrm；postinst 用于 enable 服务（开机自启）。
- **EXTRA_DEPENDS 写 OR 依赖**（`bind-host | drill`），不能用 LUCI_DEPENDS 的 select（select 不支持 OR）。

## 文件结构
- `Makefile` — 依赖 kmod-tun/unzip/curl + bind-host|drill；postinst(enable)/postrm(清理)
- `root/etc/init.d/phantun` — 服务：family解析、DNS bypass、nft apply、monitor、单规则控制(rule_start/stop/restart)
- `root/etc/config/phantun` — 默认配置
- `root/usr/share/phantun/manage.sh` — 初始化下载/竞速/进度/版本/检测更新/日志
- `root/usr/share/phantun/nftrules.sh` — 服务端自动防火墙（UCI 写 fw4，v4+v6 两条）
- `root/usr/share/phantun/monitor.sh` — DDNS 监控
- `root/usr/share/phantun/bypass.sh` — DNS 绕过代理（路由表 994）
- `root/usr/share/rpcd/acl.d/luci-app-phantun.json` — ACL（manage.sh/init.d 通配 exec）
- `root/usr/share/luci/menu.d/luci-app-phantun.json` — 菜单（服务→Phantun）
- `htdocs/luci-static/resources/view/phantun/phantun.js` — 前端（状态卡/初始化弹窗/规则表/poll实时刷新）

## 当前版本
v1.2.2（PKG_VERSION 在 Makefile）

### v1.2.0 变更
- 新增「服务端例外路由」（客户端选项，默认关）：WireGuard 全局代理场景下，为 Phantun 服务端 IP 添加走物理 WAN 的例外路由，破解「隧道要靠自己才能建立」的死锁。
- 例外路由跟随解析：按 family 分别加 v4(/32)/v6(/128)；开启后自动纳入域名监控，服务端域名 IP 变化时自动更新路由。
- 生命周期闭环：规则停止 / 取消勾选 / 卸载插件均自动清除对应例外路由（状态文件 `/var/run/phantun/<cfg>.route` 精确记录）。
- 修复 init.d 脚本 CRLF 换行导致在 OpenWrt 上无法运行的问题。

### v1.2.1 变更
- 修复致命 bug：`route.sh` 结尾的 CLI 分支（给 postrm 直接调用用）在被 `source` 进 init.d/monitor.sh 时，会拿 rc.common 的动作词（start/stop/rule_stop 等）去匹配、落入 `*)` 分支 `exit 1`，把整个 init.d 进程杀掉——导致启动/停止/重启按钮全部报错。已加 `$0` 判断，只有直接执行才走 CLI 分支。

### v1.2.2 变更
- **例外路由改为写 OpenWrt 标准静态路由**（`/etc/config/network` 的 `config route` / `config route6`），不再用独立路由表995 + ip rule。原因：用户环境的隧道默认路由本身就在 main 表，/32 或 /128 明细路由凭最长前缀匹配即可稳定压过 /0 默认路由，且写成标准静态路由后能直接在 LuCI「网络 → 静态路由」页面（IPv4/IPv6 分 tab，与 OpenWrt 原生一致）看到、手动核对、编辑，可管理性大幅提升。UCI 段命名 `phantun_<规则名>_v4`/`_v6`，`comment` 字段标注来源规则，卸载/停止/取消勾选/IP变化时精确删除对应段。
- 网关解析加内核路由表兜底：`network_get_gateway(6)` 在「网关是 link-local 地址」或「多条 source-specific 默认路由」的环境下可能取不到值，此时回退去解析 `ip [-6] route list default dev <wan>` 的实际 `via`，避免网关为空导致 on-link 路由（会在邻居解析阶段丢包，是 IPv6 握手失败的真实根因之一）。

## 构建 & 发布
- 构建：`wsl bash /mnt/c/Users/root/Pictures/wrt/build_phantun.sh`，产物 → `../build/luci-app-phantun_*.ipk`
- SDK：`/home/user/awg-build/kwrt-sdk-qualcommax-ipq60xx_*`（aarch64_cortex-a53）
- 仓库：`github.com/Dage1819/luci-app-phantun`
- 发布脚本：`../pub_phantun.sh`

## 真机验证状态（v1.1.1）
- ✅ 服务端自动防火墙：勾选后生成 v4+v6 两条端口转发，网页端可见；去勾/停止自动清除。
- ✅ 客户端隧道零防火墙可通。
- ✅ 初始化下载（多节点竞速 + 进度）真机正常。
- ✅ 外网接口下拉、版本检测更新、卸载清理均正常。

## 安全提醒
多个脚本含明文 GitHub token（`ghp_...`），**发布后务必去 GitHub 吊销重建**。
