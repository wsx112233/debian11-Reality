# Debian 11/12/13 · VPS Proxy Manager

[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

单文件交互脚本：在 **Debian 11 / 12 / 13**（`x86_64` / `arm64`）上安装、管理与干净卸载代理节点。

| 协议 | 说明 |
|------|------|
| **REALITY-Vision** | `VLESS + TCP + REALITY + Vision` |
| **VLESS + WebSocket** | 可走 **Cloudflare 优选 IP**（橙云回源） |
| **Hysteria 2** | QUIC 抗丢包 |

- **随机高位端口**（20000–60000）与 **随机 WebSocket 路径**（回车采用，可手改）
- **TG 加速**随协议静默启用；全部卸载后清干净
- 沙盒：`/etc/vps_proxy_mgr/` · `/usr/local/bin/vps_*`
- 节点链接：**有公网 IPv6 则优先 IPv6**

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash
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

### 安装 [1]

| 输入 | 含义 |
|------|------|
| `1` | REALITY |
| `2` | Hysteria2 |
| `3` | VLESS+WS |
| `1 3` / `13` | 多选 |
| `a` | 全装 |
| `0` | 返回 |

每个协议安装时：

- **端口**：自动生成空闲高位端口，直接回车即可
- **VLESS+WS path**：随机伪装路径（如 `/api/v2/xxxx`），回车采用

### 卸载 [2]

- **只列出已安装协议**（未安装的不会出现）
- 可多选；`a` = 卸当前全部；卸完自动清 TG 加速
- 若一个都没装：提示无需卸载

---

## VLESS+WS + CF 优选

1. 脚本在源站监听**随机高位端口** + **随机 path**（无源站 TLS）
2. CF 橙云，回源到该端口
3. 客户端：地址=**优选 IP**，端口 **443**，TLS 开，Host/SNI=域名，path 与安装一致

---

## License

MIT
