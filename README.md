# mosdns DNS architecture for Debian 11 + 3x-ui

This package builds a local DNS gateway:

- Large in-memory cache with lazy cache for near-zero local cache-hit latency.
- Domestic domains route to AliDNS + DNSPod over DoH/H3 with concurrent racing.
- Non-domestic domains route to Cloudflare over DoH/H3.
- DNS-level ad/tracker filtering is enabled before cache/upstream lookup, with built-in common ad rules.
- Safest default: UDP/TCP port 53 listens on `127.0.0.1` only for same-host 3x-ui/Xray. Open LAN/VPN access only after adding firewall limits.

## Install on Debian 11

For a detailed Chinese deployment guide, see [docs/deployment-zh.md](docs/deployment-zh.md).

Copy this directory to the VPS or Debian host, then run:

```bash
sudo bash scripts/install-debian11.sh
```

The installer places config in `/etc/mosdns`, installs `/usr/local/bin/mosdns`, creates a systemd service, downloads rules, and starts mosdns.

If GitHub download is slow or blocked, provide a mirror URL:

```bash
sudo MOSDNS_DOWNLOAD_URL="https://your-mirror/mosdns-linux-amd64.zip" bash scripts/install-debian11.sh
```

## Validate

```bash
dig @127.0.0.1 baidu.com
dig @127.0.0.1 google.com
dig @127.0.0.1 doubleclick.net
mosdns-benchmark 127.0.0.1 53
systemctl status mosdns
journalctl -u mosdns -f
```

`doubleclick.net` should return `0.0.0.0` or `::` for A/AAAA queries; other query types are blocked with NXDOMAIN.

## Update Rules

```bash
sudo mosdns-update-rules
```

Add custom entries without touching generated files:

- `/etc/mosdns/rules/ads.common.txt`
- `/etc/mosdns/rules/ads.custom.txt`
- `/etc/mosdns/rules/domestic.custom.txt`
- `/etc/mosdns/rules/whitelist.txt`

## 3x-ui

Use [docs/3x-ui-xray-routing.md](docs/3x-ui-xray-routing.md) for Xray DNS and routing snippets. The key point is that clients and Xray should use mosdns as their DNS, while Xray routing still decides direct/proxy traffic.

## Reality + mosdns

If you are not using 3x-ui and want to combine `wsx112233/debian11-Reality` with mosdns on Debian 11, use [docs/reality-mosdns-zh.md](docs/reality-mosdns-zh.md).

### One-click Reality + mosdns install

This repository also includes a conservative wrapper that combines this mosdns
project with `wsx112233/debian11-Reality`:

```bash
sudo bash scripts/install-reality-mosdns.sh
```

For compatibility with the old root entrypoint, this also works:

```bash
sudo ./install.sh
```

Non-interactive example:

```bash
sudo ./install.sh \
  --yes \
  --protocol reality \
  --port 443 \
  --dest www.microsoft.com:443 \
  --server-name www.microsoft.com
```

Run checks without installing:

```bash
sudo ./install.sh --preflight-only
```

Production-safety defaults:

- mosdns still listens on `127.0.0.1:53` only.
- The wrapper does not edit `/etc/resolv.conf` and does not disable existing DNS services.
- If mosdns, Xray, or Hysteria files already exist, installation stops unless you explicitly pass `--allow-existing-mosdns` or `--allow-existing-xray`.
- Reality/Xray is installed by the local `scripts/install-xray-reality.sh` script by default.
- Legacy external Reality installers are still supported with `--reality-script` or `REALITY_INSTALL_URL`, but are not required.
- Set `XRAY_ZIP_SHA256=<sha256>` if you want to pin the downloaded Xray archive.
- Install state is recorded in `/var/lib/reality-mosdns-stack/manifest.env` for uninstall.
- A lock prevents concurrent install/uninstall runs.
- If the wrapper fails after changes begin, it runs a best-effort rollback by calling the uninstall script.
- Install logs are written to `/var/lib/reality-mosdns-stack/install.log`.
- The mosdns systemd service uses basic hardening options and installs `/etc/logrotate.d/mosdns`.

To use a reviewed local copy of another Reality installer instead of the built-in
local Xray installer:

```bash
sudo ./install.sh --reality-script ./legacy-install.sh
```

Uninstall:

```bash
sudo bash scripts/uninstall-reality-mosdns.sh
```

The uninstall script removes mosdns and common Xray/Hysteria artifacts only when
the manifest shows they were not present before this wrapper ran. It does not
remove apt packages because they may be shared by other production workloads.

## Notes

- H3/HTTP/3 requires outbound UDP/443 to AliDNS, DNSPod, and Cloudflare.
- If another service already binds port 53, stop it or change `listen` in `mosdns/config.yaml`.
- The default `listen` value is `127.0.0.1:53` to avoid creating an open public DNS resolver on a VPS.
- Cache hits are local memory responses; upstream misses still depend on network latency and provider routing.
