# Debian 11/12/13 · VPS Proxy Manager

[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)

单文件脚本：安装 / 管理 / 干净卸载 **REALITY** · **Hysteria2** · **VLESS+WS（Cloudflare）**。

## 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash
```

## 主菜单

```text
[1] 安装  [2] 卸载  [3] 节点
[4] 服务  [5] 诊断  [0] 退出
```

## 协议要点

| 协议 | 端口策略 | 是否走 CF |
|------|----------|-----------|
| REALITY | 随机高位 TCP | 否（直连） |
| Hysteria2 | 随机高位 UDP + 可选跳跃/混淆 | 否（直连） |
| VLESS+WS | **仅 CF HTTPS 端口**（8443…） | 是（橙云 Full） |

### VLESS+WS · CF SSL = Full

- 源站：HTTPS + 自签证书
- CF：SSL/TLS = **Full**（非 Flexible / 非 Full strict）
- 源站端口：`8443 2053 2083 2087 2096 443`
- 客户端（走 CF）：域名/优选 IP · **与源站同端口**（如 8443）· TLS · 无 flow  
  （CF 默认同端口回源；客户端写 443 而源站 8443 会 **521**。若必须客户端 443，在 CF 建 Origin Rule 把目标端口改写为源站端口）
- 直连调试：服务器 IP · 源站端口 · TLS + allowInsecure（自签）· 无 flow

### 节点链接

- 安装完成与菜单 **[3]** 会在终端打印**完整导入链接**并显示**二维码**
- 同时写入：`/etc/vps_proxy_mgr/share/client-links.txt`（`chmod 600`）
- **卸载全部协议**时删除该文件及脚本产生的其它文件

## 非交互

```bash
sudo bash proxy_manager.sh --status
sudo bash proxy_manager.sh --diagnose
sudo bash proxy_manager.sh --links
```

## License

MIT
