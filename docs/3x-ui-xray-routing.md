# 3x-ui / Xray bottom routing

Use mosdns as the only DNS resolver exposed to local clients. Xray/3x-ui should route traffic by domain/IP, while mosdns handles encrypted DNS, cache, domestic/foreign upstream selection, and ad blocking.

## DNS

In 3x-ui panel, keep Xray DNS pointed at mosdns:

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

If mosdns runs on another LAN host, replace `127.0.0.1` with that host IP.
The default mosdns config listens on `127.0.0.1:53` only. For LAN/VPN clients, change both `udp_server` and `tcp_server` listen addresses to a LAN/VPN IP and restrict access with a firewall.

## Routing

Use this as the routing baseline in 3x-ui custom Xray config. Put the real proxy outbound tag in place of `proxy`.

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

## Client side

Set the client or router DNS to the mosdns host:

```text
DNS server: <mosdns_lan_ip>
Port: 53
Protocol: UDP/TCP DNS
```

Avoid enabling browser Secure DNS/DoH on clients, otherwise browser DNS may bypass mosdns and the ad filter.
Do not set an external backup DNS such as `8.8.8.8`, `1.1.1.1`, or `114.114.114.114`; clients may bypass mosdns by using the backup server.
