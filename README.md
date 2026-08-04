# luci-app-phantun

LuCI 界面，用于管理 [Phantun](https://github.com/Dage1819/phantun) —— 一个把 UDP 流量伪装成真实 TCP 连接（FakeTCP）的高性能混淆工具，常用于穿透只允许 TCP、或对 UDP 限速/封锁的网络，配合 WireGuard 使用效果尤佳。

![界面预览](1.jpg)

## 特性

- **中文 Web 界面**，服务端 / 客户端多规则管理，每条规则独立启停，状态实时刷新。
- **自动下载核心**：点击「初始化」自动检测架构、从 GitHub 下载对应版本并安装，支持 ghproxy.net 加速。
- **握手状态实时显示**：基于 conntrack 显示握手成功 / 握手中 / 未连接，反映当前真实状态。
- **查看日志**：弹窗显示该规则的过滤日志（保留错误/超时/关闭事件）。
- **域名解析 IP 显示**：对端为域名时显示当前实际解析 IP。
- **自动防火墙（服务端）**：勾选后自动写入端口转发（DNAT），同时覆盖 IPv4 与 IPv6；取消勾选或卸载自动清除。
- **域名监控 / DDNS（客户端）**：对端为域名时定期重解析，IP 变化自动重启隧道。
- **DNS 解析绕过代理**：强制 DNS 走物理 WAN，避免隧道断开后无法重连的死锁。
- **服务端例外路由**：全局代理场景下，自动为服务端 IP 写入走物理 WAN 的静态路由，解除隧道死锁。
- **可配置核心仓库**：默认使用 `Dage1819/phantun`（含 TCP 指纹增强），支持切换到其他仓库。
- **干净卸载**：停止进程、移除二进制、清理配置与残留文件。

## 依赖

| 依赖 | 用途 |
|------|------|
| `kmod-tun` | Phantun 创建 TUN 接口 |
| `curl` | 下载核心程序 |
| `unzip` | 解压发布包 |
| `bind-host` | 域名解析（对端为域名时必须） |

安装插件时自动拉取上述依赖（请先执行 `opkg update` 或 `apk update`）。

## 安装

### APK（OpenWrt 25.x+）

```sh
# 从加速节点下载（国内推荐）
curl -fL --connect-timeout 15 \
  -o /tmp/luci-app-phantun.apk \
  "https://ghproxy.net/https://github.com/Dage1819/luci-app-phantun/releases/latest/download/luci-app-phantun-1.4.0-r1.apk"

apk add --allow-untrusted /tmp/luci-app-phantun.apk
```

### IPK（OpenWrt 24.10 及以前）

```sh
# 从加速节点下载（国内推荐）
curl -fL --connect-timeout 15 \
  -o /tmp/luci-app-phantun.ipk \
  "https://ghproxy.net/https://github.com/Dage1819/luci-app-phantun/releases/latest/download/luci-app-phantun_1.4.0-1_all.ipk"

opkg install /tmp/luci-app-phantun.ipk
```

> 如果 ghproxy.net 不可用，也可以直接访问 [Releases 页面](https://github.com/Dage1819/luci-app-phantun/releases/latest) 下载后通过 SCP 传到路由器安装。

安装后进入 LuCI：**服务 → Phantun**，点击「初始化」下载核心程序，就绪后即可添加规则。

## 使用说明

Phantun 创建 TUN 虚拟网卡（客户端 `192.168.200.2`/`fcc8::2`，服务端 `192.168.201.2`/`fcc9::2`），插件自动开启 IP 转发。

### 服务端（有公网 IP 的一方）

| 参数 | 说明 |
|------|------|
| 模式 | 服务端 |
| 本地端口 | 对外监听的 TCP 端口，客户端连接此端口 |
| 对端地址 | 要转发到的 UDP 服务地址，通常 `127.0.0.1` |
| 对端端口 | 要转发到的 UDP 端口，通常是 WireGuard 端口 |
| 自动防火墙 | 建议勾选，自动添加 IPv4 + IPv6 端口转发规则 |

### 客户端（NAT 后需要连接服务端的一方）

| 参数 | 说明 |
|------|------|
| 模式 | 客户端 |
| 本地地址 | 本地 UDP 端点地址，通常 `127.0.0.1` |
| 本地端口 | 本地 UDP 端口，WireGuard 连接此端口 |
| 对端地址 | Phantun 服务端 IP 或域名 |
| 对端端口 | Phantun 服务端 TCP 端口 |
| 地址族 | 对端为域名时选择解析 IPv4 还是 IPv6 |
| 域名监控 | 对端为动态域名时勾选，IP 变化自动重连 |
| 服务端例外路由 | 全局代理场景下勾选，防止隧道死锁 |

### MTU 建议

Phantun 每包额外开销 12 字节，WireGuard 接口 MTU 建议：

| 链路 | 计算 | 建议值 |
|------|------|--------|
| IPv4 链路 | 1500 - 20(IP) - 20(TCP) - 32(WG) | **1428** |
| IPv6 链路 | 1500 - 40(IP) - 20(TCP) - 32(WG) | **1408** |

两端 MTU 必须一致，否则可能出现难以排查的丢包。

### TCP 指纹伪装（可选）

在「额外参数」两端同时填写 `--time`，可开启 TCP 指纹伪装，使握手包更接近真实系统的 TCP 连接，降低被 DPI 识别的概率。需使用支持该参数的版本（默认仓库 `Dage1819/phantun` 已支持）。

## 注意事项

### ⚠ IPv6 客户端必须开启 IPv6 伪装

Phantun TUN 接口的 IPv6 源地址为 ULA 私有地址（`fcc8::2`），在公网不可路由。若不开启伪装，服务端无法将 SYN+ACK 回包发回客户端，导致握手持续失败。

**解决方法**：在 LuCI 中进入「网络 → 防火墙」，编辑 **wan** 区域，勾选「**IPv6 伪装（Masquerading）**」并保存。

### ⚠ 域名对端需安装 bind-host

对端地址为域名时，插件依赖 `bind-host` 进行 DNS 解析。如果规则日志显示 `cannot resolve xxx, skipping`，请执行：

```sh
apk add bind-host   # OpenWrt 25.x+
# 或
opkg install bind-host   # OpenWrt 24.10 及以前
```

### ⚠ WireGuard 全局代理需勾选「服务端例外路由」

使用 WireGuard 全局代理（`AllowedIPs = 0.0.0.0/0`）时，去往 Phantun 服务端的流量会被路由进隧道，形成死锁。请在客户端规则中勾选「**服务端例外路由**」，插件会自动为服务端 IP 添加走物理 WAN 的静态路由。

### ⚠ WireGuard 需配置路由允许 IP

OpenWrt 的 WireGuard 接口不会自动根据 `AllowedIPs = 0.0.0.0/0` 添加默认路由，需手动开启：

```sh
uci set network.wg0.route_allowed_ips='1'
uci commit network
/etc/init.d/network restart
```

或在 LuCI 的 WireGuard 接口配置中勾选「路由允许的 IP」。

### ⚠ IPv6 握手失败排查思路

1. 确认 wan 区域已开启 IPv6 伪装
2. 在客户端运行 `cat /proc/net/nf_conntrack | grep <服务端端口>`，确认 SYN 包是否发出
3. 在服务端运行同样命令，确认 SYN 是否到达
4. 若服务端有 `source-specific` 默认路由（`from xxx` 格式），需添加无源限制路由：
   ```sh
   ip -6 route add default via <网关fe80地址> dev <wan接口> metric 1024
   ```

## 手动安装核心（SSH 方式）

如需通过 SSH 手动替换核心程序：

```sh
# 上传文件后
chmod +x /usr/bin/phantun_client /usr/bin/phantun_server
/etc/init.d/phantun restart
```

手动安装的版本号在插件界面中显示为「未知」。

## 说明

- 本插件仅提供管理界面，Phantun 二进制版权归 [原作者](https://github.com/dndx/phantun) 所有。
- 核心程序安装路径：`/usr/bin/phantun_client`、`/usr/bin/phantun_server`。

## 许可

Apache-2.0
