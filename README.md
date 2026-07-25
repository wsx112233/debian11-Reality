# Debian 11/12/13 · VPS Proxy Manager

[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)

单文件脚本：安装 / 管理 / 干净卸载 **REALITY** · **Hysteria2** · **VLESS+WS（Cloudflare）**。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash
```

## 主菜单（v1.7）

```text
[1] 安装     多选协议 · 智能端口
[2] 卸载     仅已安装项
[3] 节点     链接 / 二维码 / 导出文件
[4] 服务     启停 / 日志 / 诊断
[5] 诊断     一键检查源站与 CF 端口
[0] 退出
```

## 协议要点

| 协议 | 端口策略 | 是否走 CF |
|------|----------|-----------|
| REALITY | 随机高位 TCP | 否（直连） |
| Hysteria2 | 随机高位 UDP + 可选跳跃/混淆 | 否（直连） |
| VLESS+WS | **仅 CF 允许端口**（HTTP 8080… / HTTPS 8443…） | 是（橙云） |

- Hy2 分享链接：`主端口 + mport=段`（勿写成 `ip:start-end`）
- WS 客户端：**无 flow**；CF 源站须在官方端口列表内
- 节点自动导出：`/etc/vps_proxy_mgr/share/client-links.txt`

## 非交互

```bash
sudo bash proxy_manager.sh --status
sudo bash proxy_manager.sh --diagnose
sudo bash proxy_manager.sh --links
```

## License

MIT
