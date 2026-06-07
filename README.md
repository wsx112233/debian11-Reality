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
  --protocol hysteria2 \
  --hysteria-port 8443
```

同时安装：

```bash
sudo ./install.sh \
  --protocol reality-vision+hysteria2 \
  --hysteria-port 8443 \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

## 卸载

```bash
sudo ./install.sh uninstall
```

卸载时可以选择：

```text
1) 全部
2) reality-vision
3) hysteria2
4) reality-vision + hysteria2
```

只卸载某个协议时默认保留 mosdns。

## 预检

```bash
sudo ./install.sh --preflight-only
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

## 安全边界

- 不修改 `/etc/resolv.conf`。
- 不关闭宿主机已有 DNS 服务。
- mosdns 默认只监听 `127.0.0.1:53`。
- 检测到已有 mosdns、Xray、Hysteria 时默认拒绝覆盖，除非显式添加允许参数。
- 安装状态记录在 `/var/lib/reality-mosdns-stack/manifest.env`。
- 安装日志记录在 `/var/lib/reality-mosdns-stack/install.log`。
- 安装失败默认保留文件，方便排查；需要失败后自动回滚时，添加 `--rollback-on-failure`。
