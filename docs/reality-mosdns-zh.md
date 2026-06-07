# Reality + mosdns 无 3x-ui 一体化部署

这份教程把两件事合成一套最小职责架构：

- `wsx112233/debian11-Reality` 只负责安装 Xray / Reality 入站，必要时可加 Hysteria2。
- mosdns 只负责本机和局域网的 DNS 缓存、广告过滤、国内外分流。
- 不使用 3x-ui 面板，Xray 直接由脚本落地到系统服务。

## 推荐拓扑

```text
客户端
  |
  | DNS -> mosdns
  v
mosdns 127.0.0.1:53
  |
  | Reality / Hysteria2
  v
Xray / Hysteria2 服务器
```

如果 Xray 和 mosdns 在同一台机器上，默认让 mosdns 只监听 `127.0.0.1:53`，这是最安全、最干净的默认方式。

## 先说结论

1. Reality 安装脚本不会接管 53 端口。
2. mosdns 不需要和 Reality 脚本互相依赖。
3. 客户端 DNS 必须统一指向 mosdns，否则广告过滤和国内外分流会被绕过。
4. 如果你开启了 Hysteria2，脚本会另外放行一个 UDP 高位端口，但这和 DNS 无关。

## 一、安装顺序

推荐顺序：

1. 先装 mosdns。
2. 再跑 Reality 安装脚本。
3. 再把客户端 DNS、浏览器 Secure DNS、Android Private DNS 清掉。
4. 最后做一次 `dig` 和客户端连通性测试。

这样做的原因很简单：

- mosdns 先就位，系统和客户端从一开始就走统一 DNS。
- Reality 脚本只负责 443/高位端口入站，不会干扰 DNS。
- 先搭 DNS 再搭代理，更容易排查“到底是 DNS 问题还是代理问题”。

## 二、安装 mosdns

在 Debian 11 上进入仓库目录后执行：

```bash
sudo bash scripts/install-debian11.sh
```

默认会安装：

- `/usr/local/bin/mosdns`
- `/etc/mosdns/config.yaml`
- `/etc/mosdns/rules/ads.common.txt`
- `/etc/mosdns/rules/ads.generated.txt`
- `/etc/mosdns/rules/domestic.generated.txt`

默认监听：

```text
127.0.0.1:53
```

## 三、安装 Reality

先下载脚本，再看一眼源码：

```bash
curl -fsSLO https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/install.sh
sed -n '1,260p' install.sh
chmod +x install.sh
sudo ./install.sh --protocol reality
```

如果你只想装 Reality，不想装 Hysteria2，就明确指定 `--protocol reality`。

### 建议参数

如果你要自己决定端口和落地站点，可以这样：

```bash
sudo ./install.sh \
  --protocol reality \
  --port 443 \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

如果 443 已经被别的服务占用，就让脚本自动挑一个高位端口。

## 四、Reality 脚本的安全边界

这个脚本主要做这些事：

- 安装 Xray 官方程序。
- 生成 VLESS + Reality 配置。
- 创建 systemd 服务。
- 放行 Xray 监听端口。
- 可选地做 sysctl 调优。

它不负责：

- mosdns 配置。
- 53 端口。
- 广告过滤。
- 客户端备用 DNS。
- 浏览器 Secure DNS。

所以两者融合的关键不是“让脚本替代 mosdns”，而是“让 mosdns 成为唯一 DNS 出口”。

## 五、把 DNS 统一到 mosdns

### 1. 同机部署

如果 Reality 和 mosdns 在同一台服务器上：

- 保持 mosdns 监听 `127.0.0.1:53`
- 系统本机 DNS 指向 `127.0.0.1`
- 客户端也尽量指向这台机器的 mosdns

检查：

```bash
dig @127.0.0.1 baidu.com
dig @127.0.0.1 google.com
dig @127.0.0.1 doubleclick.net A
```

### 2. 远程客户端

如果客户端在家里路由器后面：

- 路由器 DHCP 下发 mosdns IP
- 备用 DNS 留空
- 浏览器 Secure DNS 关掉
- Android Private DNS 关掉

### 3. 代理客户端

如果客户端通过 Reality 连接服务器，DNS 仍然不要乱跳：

- 客户端系统 DNS 指向 mosdns
- 代理客户端里不要单独填外部 DNS
- 代理客户端如果有“远程 DNS / 增强模式”，要确认它不会绕开 mosdns

## 六、Reality + mosdns 的典型配置

### 服务器

```text
mosdns: 127.0.0.1:53
Reality: TCP 高位端口或 443
客户端: DNS -> mosdns
```

### 客户端

```text
首选 DNS: mosdns IP
备用 DNS: 留空
Secure DNS: 关闭
Private DNS: 关闭
```

## 七、不要这样做

1. 不要把 `53` 开给公网。
2. 不要给客户端再塞一个外部备用 DNS。
3. 不要让浏览器启用 Secure DNS。
4. 不要让 Android Private DNS 常开。
5. 不要把 generated 规则文件手工改掉。
6. 不要同时让多个 DNS 服务抢 53。
7. 不要把 Reality 误当成 DNS 服务。

## 八、验证流程

先验证 DNS：

```bash
dig @127.0.0.1 baidu.com
dig @127.0.0.1 google.com
dig @127.0.0.1 doubleclick.net A
```

再验证 Reality 入站：

- 客户端导入脚本输出的链接
- 连上服务器后访问国内外网站
- 确认广告域名没有绕过 mosdns

最后看日志：

```bash
journalctl -u mosdns -f
journalctl -u xray -f
```

## 九、最稳的默认值

如果你想要最省心的组合，直接记住这组默认值：

```text
mosdns = 本机 127.0.0.1:53
Reality = 脚本自动生成的高位端口或 443
客户端 DNS = mosdns
浏览器 Secure DNS = 关
Android Private DNS = 关
备用 DNS = 空
```

## 十、和 3x-ui 的区别

不用 3x-ui 的好处：

- 少一层面板。
- 少一套配置生成逻辑。
- 排错更直接。
- Reality 和 mosdns 的职责更清楚。

代价是：

- 你要接受手工看配置文件。
- 以后改端口、改证书、改服务，需要直接改系统配置。

## 十一、结论

这两者最合理的融合方式就是：

- Reality 脚本负责传输层代理。
- mosdns 负责 DNS。
- 客户端只认 mosdns。
- 不让任何外部 DNS 绕路。

