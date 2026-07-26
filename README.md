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
| VLESS+WS | **仅 CF HTTPS 端口**（8443/2053/…/443） | 是（橙云） |

### VLESS+WS · 仅支持 CF SSL = Full

- 源站：**HTTPS + 自签证书**（脚本自动生成）
- CF 面板：**SSL/TLS = Full**（不要 Flexible，不要 Full strict）
- 源站端口必须在：`8443 2053 2083 2087 2096 443`（默认优先 **8443**）
- 客户端：域名/优选 IP · **443** · TLS · WS · **无 flow**
- 安全组放行源站 TCP 端口（如 8443）

- Hy2 分享链接：`主端口 + mport=段`（勿写成 `ip:start-end`）
- 节点导出：`/etc/vps_proxy_mgr/share/client-links.txt`

## 非交互

```bash
sudo bash proxy_manager.sh --status
sudo bash proxy_manager.sh --diagnose
sudo bash proxy_manager.sh --links              # 导出到文件，终端脱敏
SHOW_SECRETS=1 sudo bash proxy_manager.sh --links --show-secrets  # 终端明文（慎用）
```

## 隐私

- 终端**默认不显示** UUID / 密码 / PBK / 完整导入链接 / 二维码明文
- 完整内容写入：`/etc/vps_proxy_mgr/share/client-links.txt`（`chmod 600`）
- 查看：`sudo cat /etc/vps_proxy_mgr/share/client-links.txt`
- 菜单 [3] 可选择是否临时在终端显示明文

## License

MIT
