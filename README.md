# Debian 11/12/13 · VPS Proxy Manager

[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

单文件交互脚本：在 **Debian 11 / 12 / 13**（`x86_64` / `arm64`）上安装、管理与干净卸载代理节点。

| 协议 | 说明 |
|------|------|
| **REALITY-Vision**
| **VLESS + WebSocket**
| **Hysteria 2** | QUIC 抗丢包 |

- 沙盒：`/etc/vps_proxy_mgr/` · `/usr/local/bin/vps_*`
- 节点链接：**有公网 IPv6 则优先 IPv6**

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash
```

```bash
# 等价
sudo bash <(curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get)
```

---

## 主菜单

```text
[1] 安装协议     可多选，端口/路径自动随机
[2] 卸载协议     只显示已安装项
[3] 节点与链接   参数 / 导入 URI / 二维码
[4] 服务管理     重启 / 停止 / 状态
[0] 退出
```

安装时默认给出**随机高位端口**；VLESS+WS 另给**随机 path**（形如 `/api/v2/xxxx`）。直接回车即采用，也可改成自定义值。

### 安装 [1]

列出全部协议及当前状态，**多选要装哪些**：

| 输入 | 含义 |
|------|------|
| `1` | 安装 REALITY |
| `2` | 安装 Hysteria2 |
| `3` | 安装 VLESS+WS |
| `1 3` / `1,3` / `13` | 同时安装多个 |
| `a` | 三个都装 |
| `0` | 返回 |

### 卸载 [2]

**只显示已安装的协议**（未安装的不会出现，避免误选）。

- 编号按当前已装项动态排列（1、2…）
- 可多选，例如只装了 REALITY+Hy2 时输入 `1 2`
- `a` = 卸载当前列出的全部已装项；全部卸完后自动清理 TG 加速残留
- 若一个都没装：提示「当前没有任何已安装协议」

---

## 协议说明

### REALITY-Vision

- 自动 `x25519` / UUID / shortId；SNI 池**不含微软系**
- 默认 `443/TCP`，双栈 `::`
- 可与 VLESS+WS **共用同一 Xray 进程**（多 inbound）

### VLESS + WebSocket（CF 优选 IP）

源站由脚本监听（默认建议 `8080`，亦可 `80`），**无源站 TLS**，方便 Cloudflare 回源。

**Cloudflare 面板建议：**

1. 域名 A/AAAA 指向 VPS，开启**橙云代理**
2. SSL/TLS 模式：**Flexible**（源站 HTTP）或按你证书方案选 Full
3. 回源端口与脚本中「源站端口」一致

**客户端：**

| 项 | 值 |
|----|-----|
| 地址 | **CF 优选 IP**（或域名） |
| 端口 | **443** |
| 传输 | WebSocket |
| path / Host / SNI | 与安装时一致（Host=你的域名） |
| TLS | 开启 |

菜单 **[9]** 会生成「经 CF」与「直连源站调试」两种链接。

### Hysteria 2

- 自签证书 + masquerade；UDP 端口默认优先 `443` 否则 `8443`
- 可与 REALITY 同机：TCP 443 + UDP 443

### TG 加速（静默）

任一协议安装时自动：

- 写入 `/etc/vps_proxy_mgr/optimize/telegram_cidrs.txt` 与说明
- 写入本脚本专用 `/etc/sysctl.d/99-vps-proxy-mgr.conf`（**仅** UDP/socket 缓冲，不装 WARP、不改 DNS/路由表）

**全部协议卸完**（或菜单 [8]）后删除上述文件并 `sysctl --system`，不残留。

---

## 路径

| 路径 | 用途 |
|------|------|
| `/etc/vps_proxy_mgr/` | 配置 / 日志 / 状态 / TG 资料 |
| `/usr/local/bin/vps_xray` | Xray |
| `/usr/local/bin/vps_hysteria` | Hysteria2 |
| `xray-custom.service` / `hy2-custom.service` | systemd |

---

## 注意

- 仅支持 Debian 11/12/13；需 root
- 云厂商**安全组**需放行对应 TCP/UDP（本机防火墙脚本会尝试放行）
- 请遵守当地法律与服务商条款

## License

MIT
