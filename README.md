# Debian 11 Reality + mosdns 一键安装

本项目用于在 Debian 11 上部署 Reality 代理，并与 mosdns 组合使用。

默认不会修改 `/etc/resolv.conf`，不会关闭宿主机已有 DNS 服务。mosdns 默认只监听 `127.0.0.1:53`，避免把 VPS 变成公网开放 DNS。

## 快速安装

```bash
cd /opt
git clone https://github.com/wsx112233/debian11-Reality.git Reality
cd /opt/Reality
chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

直接回车会使用默认选项：

```text
安装
reality-vision
Reality 监听端口自动选择未占用高位端口
```

安装前会显示确认信息，输入 `y` 才会继续。

如果所选协议已经安装，脚本会在协议选择后提示“无需重复安装”并退出，不会继续询问端口或覆盖已有 mosdns。

## 可选协议

```text
1) reality-vision
2) hysteria2
3) reality-vision + hysteria2
```

安装成功后会输出 Nekoray 可导入链接：

```text
vless://...
hy2://...
```

Hysteria2 使用 UDP。客户端测速里如果出现 `UDPLatency: Timeout`、`Out: Error`，优先检查服务器防火墙和云厂商安全组是否放行安装输出中的 UDP 端口。

链接也会保存到：

```text
/usr/local/etc/xray/client-link.txt
/etc/hysteria/client-link.txt
```

默认优先使用服务器公网 IPv6 生成客户端链接；如果没有可用 IPv6，则自动使用 IPv4。

## 非交互安装

安装 reality-vision：

```bash
sudo ./install.sh \
  --protocol reality-vision \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

如需指定 Reality 端口：

```bash
sudo ./install.sh \
  --protocol reality-vision \
  --port 29186 \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

如果已有 mosdns，并确认允许复用或更新：

```bash
sudo ./install.sh \
  --protocol reality-vision \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com \
  --allow-existing-mosdns
```

安装 hysteria2：

```bash
sudo ./install.sh \
  --protocol hysteria2
```

同时安装：

```bash
sudo ./install.sh \
  --protocol reality-vision+hysteria2 \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

如需指定 Hysteria2 UDP 端口：

```bash
sudo ./install.sh \
  --protocol hysteria2 \
  --hysteria-port 29187
```

Hysteria2 安装后检查 UDP 监听：

```bash
systemctl status hysteria2 --no-pager
ss -lunp | grep hysteria
```

如果 `systemctl` 显示服务正常，但 `ss` 没有输出，先看日志确认：

```bash
journalctl -u hysteria2 -n 100 --no-pager
```

## 卸载

```bash
sudo reality-mosdns uninstall
```

如果安装中途失败但已经生成安装清单，也可以使用同一条命令清理。

卸载时可以选择：

```text
1) 全部
2) reality-vision
3) hysteria2
4) reality-vision + hysteria2
```

只卸载某个协议时默认保留 mosdns。

选择“全部”卸载时，会在安全校验通过后删除安装目录，例如 `/opt/Reality`。只卸载某个协议时不会删除安装目录。

## 预检

```bash
sudo ./install.sh --preflight-only
```

## 更新已有目录

如果 `/opt/Reality` 已经存在，不要重复 `git clone`。进入目录后更新：

```bash
cd /opt/Reality
git pull
chmod +x install.sh scripts/*.sh
```

如果上一次安装失败后留下安装清单，先卸载再重新安装：

```bash
sudo reality-mosdns uninstall
sudo ./install.sh
```

## 常用检查

```bash
systemctl status mosdns
systemctl status xray
systemctl status hysteria2

journalctl -u mosdns -n 100 --no-pager
journalctl -u xray -n 100 --no-pager
journalctl -u hysteria2 -n 100 --no-pager

dig @127.0.0.1 google.com
```

## 失败处理

- mosdns 会先安装并完成启动检查，确认稳定后才继续安装 Reality 或 Hysteria2。
- mosdns 启动失败时，脚本会输出 `systemctl status mosdns` 和最近的 `journalctl` 日志，并停止后续安装。
- 如果安装前已有 mosdns 配置或服务，失败时会尝试恢复安装前备份。
- 如果是新装 mosdns 失败，脚本会停止失败服务并清理 failed 状态，避免 systemd 一直重启刷日志。

## 安全边界

- 不修改 `/etc/resolv.conf`。
- 不关闭宿主机已有 DNS 服务。
- mosdns 默认只监听 `127.0.0.1:53`。
- 检测到已有 mosdns、Xray、Hysteria 时默认拒绝覆盖，除非显式添加允许参数。
- 安装状态记录在 `/var/lib/reality-mosdns-stack/manifest.env`。
- 安装日志记录在 `/var/lib/reality-mosdns-stack/install.log`。
- 安装失败默认保留文件，方便排查；需要失败后自动回滚时，添加 `--rollback-on-failure`。
