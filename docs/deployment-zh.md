# Debian 11 + mosdns + 3x-ui 顶级 DNS 架构部署教程

本文档对应本仓库的配置文件，目标是在 Debian 11 本地系统或 VPS 上部署一套高性能 DNS 网关：

- 国内域名走阿里 DNS 与腾讯 DNSPod 的 DoH/H3。
- 国外域名走 Cloudflare DoH/H3。
- 开启大容量内存缓存与 lazy cache，缓存命中时本机返回延迟接近 0ms。
- 开启 DNS 级广告与跟踪域名过滤，默认内置常用广告规则。
- 开启多上游并发竞速，优先使用最快返回的结果。
- 配合 3x-ui / Xray 做底层 direct/proxy 分流。

## 重要结论先说

1. 所谓 `0ms` 只可能发生在缓存命中、本机或局域网查询的情况下。第一次查询、缓存未命中、国外链路绕行、上游拥塞时，一定会有真实网络延迟。
2. 本仓库默认采用最安全策略：mosdns 只监听 `127.0.0.1:53`，只给同一台机器上的 3x-ui/Xray 或本机程序使用。需要局域网/VPN 客户端访问时，必须手动改监听地址并配置防火墙白名单。
3. 不建议把 `53` 端口暴露给公网。公网开放 DNS 很容易变成开放递归解析器，被用于 DNS 放大攻击。
4. H3/HTTP/3 依赖 UDP/443。如果 VPS 或本地网络阻断 UDP/443，上游可能失败或回退行为不符合预期。
5. 浏览器、系统、客户端如果启用了内置 DoH/Secure DNS，可能绕过 mosdns，导致广告过滤和国内外分流失效。
6. 3x-ui/Xray 的路由只负责流量走 direct 还是 proxy；DNS 解析逻辑由 mosdns 负责。不要在多个地方同时做互相冲突的 DNS 分流。

## 文件说明

仓库关键文件如下：

```text
mosdns/config.yaml                  mosdns 主配置
mosdns/hosts.txt                    本地 hosts 静态解析
mosdns/rules/ads.common.txt         内置常用广告规则，不会被脚本覆盖
mosdns/rules/ads.generated.txt      广告规则，脚本自动生成
mosdns/rules/ads.custom.txt         自定义广告规则，手动维护
mosdns/rules/domestic.generated.txt 国内域名规则，脚本自动生成
mosdns/rules/domestic.custom.txt    自定义国内域名规则，手动维护
mosdns/rules/whitelist.txt          广告过滤白名单
scripts/install-debian11.sh         Debian 11 一键安装脚本
scripts/update-rules.sh             规则更新脚本
scripts/benchmark-dns.sh            多线程 DNS 测速脚本
docs/3x-ui-xray-routing.md          3x-ui / Xray 配置片段
```

安装后，文件会被放到：

```text
/etc/mosdns/config.yaml
/etc/mosdns/hosts.txt
/etc/mosdns/rules/*.txt
/usr/local/bin/mosdns
/usr/local/bin/mosdns-update-rules
/usr/local/bin/mosdns-benchmark
/etc/systemd/system/mosdns.service
```

## 架构图

```text
本地客户端 / 路由器 / 3x-ui / Xray
        |
        | UDP/TCP 53
        v
mosdns 127.0.0.1:53
        |
        | 1. hosts 静态解析
        | 2. 白名单
        | 3. 广告过滤
        | 4. 大容量缓存
        | 5. 国内外域名规则
        |
        +-- 国内域名 -> 阿里 DoH/H3 + DNSPod DoH/H3 并发竞速
        |
        +-- 国外域名 -> Cloudflare DoH/H3 并发竞速
```

当前主配置里的上游：

```text
国内：
https://dns.alidns.com/dns-query     dial 223.5.5.5
https://dns.alidns.com/dns-query     dial 223.6.6.6
https://doh.pub/dns-query            dial 1.12.12.12
https://doh.pub/dns-query            dial 120.53.53.53

国外：
https://cloudflare-dns.com/dns-query dial 1.1.1.1
https://cloudflare-dns.com/dns-query dial 1.0.0.1
```

## 一、部署前准备

### 1. 系统要求

推荐环境：

```text
系统：Debian 11
内存：至少 256MB，建议 512MB 以上
权限：root 或 sudo
网络：能访问 GitHub、阿里 DNS、DNSPod、Cloudflare
端口：本机或局域网可访问 UDP/TCP 53
```

如果是 VPS，还需要确认安全组、防火墙、运营商策略没有阻断：

```text
UDP 53    本机访问 mosdns；局域网/VPN 访问需要手动放开
TCP 53    本机访问 mosdns；局域网/VPN 访问需要手动放开
UDP 443   mosdns 访问 H3 上游
TCP 443   下载文件、规则更新、必要时访问 DoH
```

### 2. 检查 53 端口是否被占用

在 Debian 上执行：

```bash
sudo ss -lntup | grep ':53 '
sudo ss -lnuap | grep ':53 '
```

如果没有输出，说明 53 端口没有监听。

如果看到 `systemd-resolved`、`dnsmasq`、`named`、`unbound`、`adguardhome` 等程序占用，需要先决定谁来负责 53 端口。

常见处理方式：

```bash
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf
```

特别注意：如果你当前 SSH 到 VPS 后依赖系统 DNS 解析域名，先不要急着改 `/etc/resolv.conf`。建议先完成 mosdns 安装并确认 `dig @127.0.0.1 google.com` 正常，再把系统 DNS 指向 `127.0.0.1`。

### 3. 防火墙原则

最安全默认策略是不开放 53 给局域网或公网，只监听 `127.0.0.1`。如果你确认要给局域网用，可以先把 `mosdns/config.yaml` 里的 `udp_server` 和 `tcp_server` 监听地址改成局域网 IP，例如：

```yaml
listen: "192.168.1.2:53"
```

然后只允许局域网访问 53：

```bash
sudo ufw allow from 192.168.0.0/16 to any port 53
sudo ufw allow from 10.0.0.0/8 to any port 53
sudo ufw allow from 172.16.0.0/12 to any port 53
```

VPS 禁止直接：

```bash
sudo ufw allow 53
```

如果 VPS 必须给外部客户端使用，最安全做法是只监听 VPN 网卡 IP，或只允许固定客户端 IP：

```bash
sudo ufw allow from <你的固定公网IP> to any port 53
```

或者只允许 VPN 网段：

```bash
sudo ufw allow from 10.8.0.0/24 to any port 53
```

## 二、把仓库复制到 Debian 11

在你的 Debian 11 机器上准备目录，例如：

```bash
mkdir -p /opt/dns-stack
```

把本仓库内容复制过去。可以用 `scp`、`rsync`、Git 或面板文件管理器。

例如从本地上传到 VPS：

```bash
scp -r ./DNS root@<VPS_IP>:/opt/dns-stack
```

进入目录：

```bash
cd /opt/dns-stack/DNS
```

确认能看到：

```bash
ls
ls mosdns
ls scripts
```

## 三、一键安装

执行：

```bash
sudo bash scripts/install-debian11.sh
```

安装脚本会做这些事：

1. 安装 `ca-certificates`、`curl`、`unzip`、`dnsutils`。
2. 下载 mosdns 二进制文件。
3. 安装 `/usr/local/bin/mosdns`。
4. 创建 `/etc/mosdns` 配置目录。
5. 复制主配置和规则文件。
6. 安装 `mosdns-update-rules` 和 `mosdns-benchmark`。
7. 下载最新广告规则和国内规则。
8. 创建 systemd 服务。
9. 启动并设置 mosdns 开机自启。

如果 GitHub 下载慢或失败，可以指定镜像地址：

```bash
sudo MOSDNS_DOWNLOAD_URL="https://你的镜像地址/mosdns-linux-amd64.zip" bash scripts/install-debian11.sh
```

如果是 ARM64 机器，镜像文件应对应 `mosdns-linux-arm64.zip`。

## 四、检查服务状态

安装完成后执行：

```bash
systemctl status mosdns
```

正常情况下应该看到：

```text
Active: active (running)
```

查看实时日志：

```bash
journalctl -u mosdns -f
```

查看 mosdns 文件日志：

```bash
sudo tail -f /var/log/mosdns.log
```

检查端口：

```bash
sudo ss -lntup | grep ':53 '
sudo ss -lnuap | grep ':53 '
```

默认应看到 `mosdns` 正在监听 `127.0.0.1:53`。如果你手动改成局域网或 VPN IP，应确认监听地址不是公网 `0.0.0.0:53`，除非防火墙已经限制来源。

## 五、DNS 功能验证

### 1. 国内域名

```bash
dig @127.0.0.1 baidu.com
dig @127.0.0.1 qq.com
dig @127.0.0.1 bilibili.com
```

这些域名应命中国内规则，走阿里 DNS / DNSPod。

### 2. 国外域名

```bash
dig @127.0.0.1 google.com
dig @127.0.0.1 github.com
dig @127.0.0.1 cloudflare.com
```

这些域名如果不在国内规则中，会走 Cloudflare。

### 3. 广告过滤

```bash
dig @127.0.0.1 doubleclick.net A
dig @127.0.0.1 googleadservices.com A
dig @127.0.0.1 googlesyndication.com A
```

命中广告规则时，A 记录应返回：

```text
0.0.0.0
```

AAAA 记录应返回：

```text
::
```

其他类型会返回 NXDOMAIN，避免广告域名继续解析。

### 4. 缓存效果

连续执行两次：

```bash
dig @127.0.0.1 github.com
dig @127.0.0.1 github.com
```

第二次通常会明显更快。`Query time` 如果显示 `0 msec` 或 `1 msec`，说明本地缓存命中。

注意：`dig` 显示 `0 msec` 不代表真实网络 0 延迟，而是本地缓存返回太快，低于工具显示精度。

## 六、多线程并发测速

执行：

```bash
mosdns-benchmark 127.0.0.1 53
```

默认参数：

```text
JOBS=32
ROUNDS=3
```

自定义并发：

```bash
JOBS=64 ROUNDS=5 mosdns-benchmark 127.0.0.1 53
```

输出示例：

```text
queries=72 ok=72 fail=0 avg=3.4ms p50=1ms p90=9ms min=0ms max=31ms
```

指标解释：

```text
queries 总查询数
ok      成功查询数
fail    失败查询数
avg     平均耗时
p50     50% 查询低于这个耗时
p90     90% 查询低于这个耗时
min     最快查询
max     最慢查询
```

如果第一次测速较慢，先跑一遍预热缓存，再跑第二遍：

```bash
mosdns-benchmark 127.0.0.1 53
mosdns-benchmark 127.0.0.1 53
```

## 七、规则更新与自定义

### 1. 更新规则

执行：

```bash
sudo mosdns-update-rules
```

脚本会更新：

```text
/etc/mosdns/rules/ads.generated.txt
/etc/mosdns/rules/domestic.generated.txt
```

更新完成后，如果 mosdns 正在运行，脚本会自动重启 mosdns。

内置常用广告规则位于：

```text
/etc/mosdns/rules/ads.common.txt
```

这个文件由安装脚本部署，规则更新脚本不会覆盖它。默认过滤链路会依次检查：

```text
whitelist.txt        白名单，最高优先级
ads.common.txt       内置常用广告规则
ads.generated.txt    在线广告规则
ads.custom.txt       你的自定义广告规则
```

### 2. 自定义广告过滤

编辑：

```bash
sudo nano /etc/mosdns/rules/ads.custom.txt
```

示例：

```text
domain:ads.example.com
full:track.example.com
keyword:adservice
regexp:(^|\.)ad[0-9]+\.
```

保存后重启：

```bash
sudo systemctl restart mosdns
```

### 3. 自定义国内域名

如果某个域名必须走国内上游，编辑：

```bash
sudo nano /etc/mosdns/rules/domestic.custom.txt
```

示例：

```text
domain:example.cn
domain:mybank.com
full:api.internal.example.com
```

重启：

```bash
sudo systemctl restart mosdns
```

### 4. 广告白名单

如果某个域名被误杀，编辑：

```bash
sudo nano /etc/mosdns/rules/whitelist.txt
```

示例：

```text
domain:example.com
full:login.example.com
```

白名单逻辑是：先跳过广告过滤，然后继续进入国内/国外路由。误杀只加白名单，不要删除 `ads.common.txt` 或 `ads.generated.txt` 里的规则。

### 5. 本地 hosts

编辑：

```bash
sudo nano /etc/mosdns/hosts.txt
```

示例：

```text
192.168.1.1 router.lan
10.0.0.2 nas.lan
```

重启：

```bash
sudo systemctl restart mosdns
```

## 八、接入 3x-ui / Xray

### 1. 核心原则

mosdns 负责：

```text
DNS 缓存
广告过滤
国内/国外 DNS 上游选择
DoH/H3 加密查询
```

Xray/3x-ui 负责：

```text
流量 direct/proxy 分流
入站协议
出站代理
连接策略
```

不要让 Xray 再去使用一堆外部 DNS，否则容易出现：

```text
DNS 分流和流量分流不一致
广告过滤被绕过
国内域名解析到国外 CDN
国外域名被国内 DNS 污染
```

### 2. mosdns 和 3x-ui 在同一台机器

3x-ui 的 Xray DNS 配置建议：

```json
{
  "dns": {
    "servers": [
      "127.0.0.1",
      "localhost"
    ],
    "queryStrategy": "UseIP"
  }
}
```

### 3. mosdns 在局域网另一台机器

把 `127.0.0.1` 改成 mosdns 主机 IP：

```json
{
  "dns": {
    "servers": [
      "192.168.1.2"
    ],
    "queryStrategy": "UseIP"
  }
}
```

### 4. Xray 路由基线

根据你的 3x-ui 实际 outbound tag 修改 `proxy`。

```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:private",
          "geosite:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:geolocation-!cn"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
```

特别注意：如果你的 3x-ui 面板里实际代理出站不是 `proxy`，必须改成真实 tag。常见 tag 可能是：

```text
proxy
direct
blocked
freedom
```

以 3x-ui 当前生成的 Xray 配置为准。

## 九、客户端接入

### 1. 路由器接入

如果 mosdns 只给同机 3x-ui 使用，不需要配置路由器 DNS。

如果你确认要给全局局域网客户端使用，必须先把 mosdns 监听地址从 `127.0.0.1:53` 改成局域网 IP，并配置防火墙只允许局域网来源。然后在路由器 DHCP 设置里，把 DNS 下发为 mosdns 主机 IP：

```text
DNS 1: <mosdns_lan_ip>
DNS 2: 留空，或同样填 <mosdns_lan_ip>
```

DNS 2 必须留空，或同样填 mosdns IP。不要填 `8.8.8.8`、`1.1.1.1`、`114.114.114.114`，因为客户端可能随机选择 DNS 2，从而绕过 mosdns。

### 2. Windows 客户端

如果 Windows 和 mosdns 在同一台机器，网络适配器 DNS 可以使用：

```text
首选 DNS: 127.0.0.1
备用 DNS: 留空
```

如果 Windows 是局域网客户端，并且你已经手动放开 mosdns 局域网监听，网络适配器 DNS：

```text
首选 DNS: <mosdns_lan_ip>
备用 DNS: 留空
```

清缓存：

```powershell
ipconfig /flushdns
```

测试：

```powershell
nslookup github.com <mosdns_lan_ip>
nslookup doubleclick.net <mosdns_lan_ip>
```

### 3. Android / iOS

如果连接家里 Wi-Fi，通常在 Wi-Fi 详情里手动设置 DNS 为 mosdns IP。

最安全策略是关闭或避免使用：

```text
Android Private DNS
iOS 第三方加密 DNS 描述文件
浏览器 Secure DNS
代理客户端内置远程 DNS
```

### 4. 浏览器

Chrome / Edge / Firefox 里如果开启了 Secure DNS，会绕过系统 DNS。最安全策略是关闭 Secure DNS。

Chrome / Edge：

```text
设置 -> 隐私和安全 -> 安全 -> 使用安全 DNS
```

Firefox：

```text
设置 -> 隐私与安全 -> DNS over HTTPS
```

## 十、安全加固

### 1. 避免开放递归 DNS

当前最安全配置监听：

```yaml
listen: "127.0.0.1:53"
```

这表示只接受本机查询，适合同机 3x-ui/Xray。它不会把 VPS 变成公网开放 DNS。

如果要给 WireGuard/Tailscale 或局域网使用，可以改成对应内网/VPN 地址，例如：

```yaml
listen: "10.8.0.1:53"
```

配置里有两个位置都要改：

```text
udp_server listen
tcp_server listen
```

改完重启：

```bash
sudo systemctl restart mosdns
```

### 2. VPS 推荐访问方式

推荐优先级：

```text
1. mosdns 只监听 127.0.0.1，给同机 3x-ui 使用
2. mosdns 监听 VPN 网卡 IP，只给 WireGuard/Tailscale 客户端使用
3. mosdns 监听局域网 IP，只给 LAN 客户端使用
4. mosdns 监听 0.0.0.0，但防火墙只允许固定 IP
5. 禁止公网裸开 53
```

### 3. 日志隐私

mosdns 日志在：

```text
/var/log/mosdns.log
```

DNS 日志可能暴露访问域名。多人共用机器时，注意日志权限和留存周期。

可以用 logrotate 管理日志：

```bash
sudo nano /etc/logrotate.d/mosdns
```

示例：

```text
/var/log/mosdns.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
```

## 十一、性能调优

### 1. 缓存大小

当前配置：

```yaml
size: 200000
lazy_cache_ttl: 86400
lazy_cache_reply_ttl: 30
dump_file: "/etc/mosdns/cache.dump"
dump_interval: 600
```

含义：

```text
size                 最多缓存 200000 条
lazy_cache_ttl       过期后最多继续保留 86400 秒
lazy_cache_reply_ttl lazy cache 返回给客户端的 TTL
dump_file            缓存持久化文件
dump_interval        每 600 秒落盘一次
```

如果机器内存较小，可以改成：

```yaml
size: 50000
```

如果是大内存 VPS 或旁路由，可以改成：

```yaml
size: 500000
```

改完：

```bash
sudo systemctl restart mosdns
```

### 2. 并发竞速

当前国内上游：

```yaml
concurrent: 4
```

表示 4 个国内上游并发查询，谁先返回用谁。

当前国外上游：

```yaml
concurrent: 2
```

表示 2 个 Cloudflare 上游并发查询。

并发越高，延迟可能越低，但上游请求数也越多。家用和个人 VPS 不建议盲目拉太高。

### 3. H3 失败处理

如果发现国外域名全部失败，先检查 UDP/443：

```bash
curl -I https://cloudflare-dns.com/dns-query
```

然后查看日志：

```bash
journalctl -u mosdns -n 100 --no-pager
```

如果明确是 UDP/443 被阻断，可以临时把 `enable_http3: true` 改成：

```yaml
enable_http3: false
```

然后重启。这样会使用常规 HTTPS DoH，延迟可能略高，但兼容性更好。

## 十二、常见故障排查

### 1. mosdns 启动失败

查看状态：

```bash
systemctl status mosdns
journalctl -u mosdns -n 100 --no-pager
```

常见原因：

```text
配置 YAML 格式错误
53 端口被占用
规则文件路径不存在
mosdns 二进制架构不匹配
```

### 2. 端口 53 被占用

查看：

```bash
sudo ss -lntup | grep ':53 '
sudo ss -lnuap | grep ':53 '
```

如果是 `systemd-resolved`：

```bash
sudo systemctl disable --now systemd-resolved
```

如果是 `dnsmasq`：

```bash
sudo systemctl disable --now dnsmasq
```

如果是其他服务，需要按你的系统实际情况处理。

### 3. 客户端没有走 mosdns

检查客户端实际 DNS：

```bash
nslookup github.com
```

或指定 mosdns：

```bash
nslookup github.com <mosdns_lan_ip>
```

常见原因：

```text
路由器 DHCP 还在下发旧 DNS
客户端有备用 DNS
浏览器开启 Secure DNS
代理客户端启用了远程 DNS
Android Private DNS 绕过本地 DNS
```

### 4. 广告过滤没生效

先直接查 mosdns：

```bash
dig @127.0.0.1 doubleclick.net A
```

如果返回 `0.0.0.0`，说明 mosdns 正常，问题在客户端绕过了 DNS。

如果没有返回 `0.0.0.0`，检查规则：

```bash
grep -i doubleclick /etc/mosdns/rules/ads.generated.txt
grep -i doubleclick /etc/mosdns/rules/ads.common.txt
grep -i doubleclick /etc/mosdns/rules/ads.custom.txt
```

然后重启：

```bash
sudo systemctl restart mosdns
```

### 5. 国内网站打开慢

可能原因：

```text
域名没有命中国内规则，走了 Cloudflare
Xray 路由把国内流量代理出去了
客户端没有使用 mosdns
国内 CDN 本身调度异常
```

处理方式：

```bash
dig @127.0.0.1 example.com
sudo nano /etc/mosdns/rules/domestic.custom.txt
sudo systemctl restart mosdns
```

把域名加入：

```text
domain:example.com
```

### 6. 国外网站打不开

可能原因：

```text
Cloudflare DoH/H3 被阻断
Xray proxy 出站不可用
3x-ui routing tag 写错
国外域名被误加入国内规则
```

先测 DNS：

```bash
dig @127.0.0.1 google.com
dig @127.0.0.1 github.com
```

再看 Xray 出站日志和 3x-ui 面板状态。

### 7. 规则更新失败

执行：

```bash
sudo mosdns-update-rules
```

如果报 GitHub 连接失败，说明机器访问规则源不稳定。可以手动下载规则文件，或把脚本里的规则源改成你的镜像。

注意：`ads.generated.txt` 和 `domestic.generated.txt` 会被脚本覆盖。自定义内容必须放到：

```text
ads.custom.txt
domestic.custom.txt
whitelist.txt
```

`ads.common.txt` 是内置常用广告规则，默认安装并参与过滤；如果确实要改，先备份，误杀优先用 `whitelist.txt` 解决。

## 十三、升级与回滚

### 1. 修改配置前备份

```bash
sudo cp -a /etc/mosdns/config.yaml /etc/mosdns/config.yaml.bak.$(date +%Y%m%d%H%M%S)
sudo cp -a /etc/mosdns/rules /etc/mosdns/rules.bak.$(date +%Y%m%d%H%M%S)
```

### 2. 重启服务

```bash
sudo systemctl restart mosdns
```

### 3. 回滚配置

找出备份：

```bash
ls -lh /etc/mosdns/config.yaml.bak.*
```

恢复：

```bash
sudo cp -a /etc/mosdns/config.yaml.bak.<时间戳> /etc/mosdns/config.yaml
sudo systemctl restart mosdns
```

## 十四、卸载

如果要卸载：

```bash
sudo systemctl disable --now mosdns
sudo rm -f /etc/systemd/system/mosdns.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/mosdns
sudo rm -f /usr/local/bin/mosdns-update-rules
sudo rm -f /usr/local/bin/mosdns-benchmark
sudo rm -rf /etc/mosdns
```

注意：删除 `/etc/mosdns` 会清掉你的自定义规则和缓存文件，执行前请确认已经备份。

## 十五、上线前检查清单

上线前逐项确认：

```text
[ ] mosdns 服务 active(running)
[ ] UDP/TCP 53 默认只监听 127.0.0.1
[ ] 53 端口没有被其他 DNS 服务抢占
[ ] VPS 防火墙没有把 53 裸露给全网
[ ] UDP/443 可以访问上游 H3 DNS
[ ] dig @127.0.0.1 baidu.com 正常
[ ] dig @127.0.0.1 google.com 正常
[ ] dig @127.0.0.1 doubleclick.net A 返回 0.0.0.0
[ ] mosdns-benchmark 无大量 fail
[ ] 3x-ui DNS 指向 mosdns
[ ] 3x-ui routing 里的 proxy tag 和实际出站一致
[ ] 如果要给 LAN/VPN 使用，已手动改监听地址并限制来源 IP
[ ] 客户端没有配置备用外部 DNS
[ ] 浏览器 Secure DNS 已关闭
[ ] Android Private DNS / iOS 加密 DNS 描述文件已关闭或未绕过 mosdns
```

## 十六、推荐运维命令速查

```bash
# 服务状态
systemctl status mosdns

# 重启
sudo systemctl restart mosdns

# 查看实时日志
journalctl -u mosdns -f

# 查看最近 100 行日志
journalctl -u mosdns -n 100 --no-pager

# 查看 53 端口
sudo ss -lntup | grep ':53 '
sudo ss -lnuap | grep ':53 '

# 更新规则
sudo mosdns-update-rules

# 测速
mosdns-benchmark 127.0.0.1 53

# 测国内
dig @127.0.0.1 baidu.com

# 测国外
dig @127.0.0.1 google.com

# 测广告过滤
dig @127.0.0.1 doubleclick.net A
```

## 十七、默认最安全策略

以下 10 项已经按“默认安全、手动放开”的原则处理：

1. 公网开放 53：默认只监听 `127.0.0.1:53`，不会对公网开放。VPS 需要远程使用时，优先通过 WireGuard/Tailscale，并只监听 VPN IP；必须公网访问时，只允许固定来源 IP。
2. 客户端备用 DNS：教程默认要求备用 DNS 留空，或同样填写 mosdns IP。禁止把外部 DNS 当备用 DNS。
3. 浏览器 Secure DNS：教程默认要求关闭 Chrome、Edge、Firefox 的 Secure DNS/DoH，避免浏览器绕过 mosdns。
4. Android Private DNS：教程默认要求关闭 Android Private DNS；iOS 不安装会绕过本地 DNS 的加密 DNS 描述文件。
5. 3x-ui 出站 tag：教程要求把示例里的 `proxy` 改成 3x-ui 实际出站 tag，不能照抄不检查。
6. UDP/443：H3 依赖 UDP/443。默认保留 H3；如果 UDP/443 不通，先确认网络策略，再临时把 `enable_http3` 改为 `false` 使用常规 DoH。
7. 规则误杀：误杀域名只写入 `whitelist.txt`，不直接删除广告规则。
8. generated 文件覆盖：`ads.generated.txt` 和 `domestic.generated.txt` 只由脚本管理；自定义只写 `ads.custom.txt`、`domestic.custom.txt`、`whitelist.txt`。
9. 端口冲突：安装前必须检查 `systemd-resolved`、`dnsmasq`、AdGuard Home、named、unbound 是否占用 53。
10. `0ms` 预期：文档明确说明只有缓存命中才可能显示 0ms，首次查询一定有真实网络延迟。

默认还内置了常用广告过滤规则：

```text
/etc/mosdns/rules/ads.common.txt
```

这部分规则不依赖在线更新，安装后立即参与过滤。在线规则更新失败时，基础广告过滤仍然有效。
