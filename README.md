# Debian 11/12/13 · VPS Proxy Manager

[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](proxy_manager.sh)

单文件交互式运维脚本：在 **Debian 11 (Bullseye) / 12 (Bookworm) / 13 (Trixie)** 上安装、管理与干净卸载：

| 模块 | 说明 |
|------|------|
| **Xray REALITY-Vision** | `VLESS + TCP + REALITY + xtls-rprx-vision` |
| **Hysteria 2** | QUIC 抗丢包，自签证书 + HTTPS 伪装 |
| **内核 / TG 加速** | BBR + fq、UDP/TCP 缓冲分档、可选 Cloudflare WARP Socks5 |

- 架构：`x86_64` / `arm64`
- 沙盒隔离：二进制与配置集中在 `/etc/vps_proxy_mgr/`、`/usr/local/bin/vps_*`
- **有公网 IPv6 时节点链接优先 IPv6**，并附带 IPv4 备用链接
- 安装速度优化：并行 SNI 探测、IP/版本/apt 缓存、多镜像下载
- 传输性能：按内存分档 sysctl、Hy2 按网卡速率声明带宽

> **仓库说明**：本仓库已用当前 `proxy_manager.sh` 全量覆盖旧版（原 mosdns / 多脚本结构已移除）。

---

## 快速开始

```bash
# 方式一：curl 一键拉取并运行（推荐）
curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/proxy_manager.sh \
  -o proxy_manager.sh
chmod +x proxy_manager.sh
sudo ./proxy_manager.sh
```

```bash
# 方式二：克隆仓库
git clone https://github.com/wsx112233/debian11-Reality.git
cd debian11-Reality
chmod +x proxy_manager.sh
sudo ./proxy_manager.sh
```

```bash
# 仅查看组件状态
sudo ./proxy_manager.sh --status
sudo ./proxy_manager.sh -v
```

---

## 主菜单

```text
安装
  [1] 单独安装 REALITY-Vision
  [2] 单独安装 Hysteria 2
  [3] Cloudflare WARP / TG 加速 + 内核 BBR 调优
  [4] 一键组合安装 (REALITY + Hy2 + TG加速 + 内核调优)

卸载
  [5] 单独彻底卸载 REALITY
  [6] 单独彻底卸载 Hysteria 2
  [7] 单独彻底卸载 WARP / 网络优化
  [8] 彻底一键清理所有组件与残留

运维
  [9]  查看节点参数 / 导入链接 / 终端二维码
  [10] 重启 / 停止 / 查看服务状态
  [0]  退出
```

菜单顶部会彩色显示 REALITY / Hy2 / WARP / 内核调优状态。

---

## 协议说明

### 1. Xray REALITY-Vision

- 协议栈：`VLESS` + `TCP` + `REALITY` + `Vision (xtls-rprx-vision)`
- 自动生成：`x25519` 密钥、UUID、16 位 Hex `shortId`
- 伪装 SNI：内置 Apple / Google / Amazon / Cloudflare / Fastly 等池，**禁用微软系域名**
- 安装时并行 TLS 探测，选取可用 SNI；默认端口 `443/TCP`（可自定义）
- 监听 `::` 双栈；systemd 服务名：`xray-custom.service`
- 导入示例：

```text
vless://UUID@HOST:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=...&fp=chrome&pbk=...&sid=...&type=tcp#...
```

IPv6 主机在链接中自动写成 `[2001:db8::1]` 形式。

### 2. Hysteria 2

- 自签名证书 + `masquerade` 反代大厂 HTTPS（默认 Apple）
- 强随机密码；默认优先 `443/UDP`，占用则建议 `8443/UDP`
- 与 REALITY 可同机：**443/TCP + 443/UDP** 协同
- QUIC 窗口与带宽按 **内存档位 / 网卡速率** 自动配置
- systemd 服务名：`hy2-custom.service`
- 导入示例：

```text
hysteria2://PASSWORD@HOST:PORT?insecure=1&sni=www.apple.com#...
```

### 3. 内核调优与 Telegram

- BBR + `fq`，UDP/TCP 缓冲按内存分档（small / medium / large）
- 写入 `/etc/sysctl.d/99-vps-proxy-mgr.conf`，卸载时删除并 `sysctl --system`
- 可选安装 Cloudflare WARP 本地 Socks5（默认 `127.0.0.1:40000`）
- Telegram 官方 CIDR 列表写入沙盒，供客户端分流参考

装 REALITY 或 Hy2 时，若尚未调优会**自动应用**内核参数。

---

## 路径与沙盒（零破坏）

| 路径 | 用途 |
|------|------|
| `/etc/vps_proxy_mgr/` | 配置、日志、状态、缓存 |
| `/usr/local/bin/vps_xray` | Xray 二进制 |
| `/usr/local/bin/vps_hysteria` | Hysteria2 二进制 |
| `/etc/systemd/system/xray-custom.service` | Xray 单元 |
| `/etc/systemd/system/hy2-custom.service` | Hy2 单元 |
| `/etc/sysctl.d/99-vps-proxy-mgr.conf` | 内核网络参数 |

卸载会停止服务、删单元、清沙盒、还原防火墙规则与 sysctl 自定义文件。  
**不会**卸载你系统里原先就有的 apt 依赖包。

---

## 防火墙与云安全组

脚本自动检测：

- **UFW**（活动时）
- **nftables**（专用 `inet vps_proxy_mgr` 表）
- **iptables + ip6tables**

安装时放行对应 TCP/UDP 端口，卸载时删除。

> 若客户端仍连不上，请到 **云厂商安全组 / 防火墙** 放行相同端口（本机规则 ≠ 控制台安全组）。

---

## 客户端

安装完成或菜单 **[9]** 可查看：

- 明文参数
- `vless://` / `hysteria2://` 链接（IPv6 优先 + IPv4 备用）
- 终端二维码（依赖 `qrencode`）

兼容常见客户端：v2rayNG、NekoBox、Shadowrocket、Hiddify、Clash Meta（需自行转换）等。

---

## 系统要求

- 仅支持 **Debian** 11 / 12 / 13（非 Debian 会提示并退出）
- Root 权限：`sudo`
- 出网：下载 GitHub Release、探测 SNI、获取公网 IP
- 按需安装依赖：`curl` `wget` `jq` `openssl` `tar` `unzip` `qrencode` `iptables` 等

---

## 设计要点

1. **`set -euo pipefail`**，模块函数化  
2. Systemd：`Restart=on-failure`，`RestartSec=5s`  
3. 安装加速：并行 SNI、缓存、镜像链、apt 节流  
4. 传输向：BBR、分档缓冲、Hy2 大窗口、关闭 Xray access 日志减少 I/O  

脚本版本见：

```bash
sudo ./proxy_manager.sh -v
# 当前文档对应：proxy_manager.sh v1.3.0+
```

---

## 卸载

交互菜单选择 **[5]–[8]**，或使用 **[8] 彻底一键清理** 后脚本会做残留自检。

---

## 免责声明

本项目仅供学习与网络技术研究。请遵守当地法律法规及服务商条款；使用者自行承担风险。

---

## License

MIT
