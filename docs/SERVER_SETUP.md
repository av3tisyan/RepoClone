# Server setup (automated)

Use [`scripts/setup-apt-mirror-server.sh`](../scripts/setup-apt-mirror-server.sh) on **Debian** (13 recommended) as **root**, from a checkout of this repository.

## Roles

| `--role` | Use on | What it installs |
|----------|--------|------------------|
| **`sync`** | Internet-connected sync host | `apt-mirror`, `/etc/apt/mirror.list`, systemd timer, logrotate, `/opt/apt/keys` via `populate-mirror-keys.sh` |
| **`airgap`** | Isolated mirror web server | `nginx`, vhost for `apt.example.com`, empty `/opt/apt` tree (you **rsync** content from sync) |
| **`both`** | One box that syncs and serves | All of the above (default) |

## How to run the script

The path depends on your **current directory**:

| You are in | Command |
|------------|---------|
| Repo root (`.../apt-mirror`) | `sudo ./scripts/setup-apt-mirror-server.sh` |
| `.../apt-mirror/scripts` | `sudo ./setup-apt-mirror-server.sh` |

Using `sudo ./scripts/setup-...` **while already inside `scripts/`** fails (`command not found`), because that looks for `scripts/scripts/...`.

## Examples

```bash
cd /path/to/apt-mirror
sudo ./scripts/setup-apt-mirror-server.sh
```

**Split topology** (sync host vs airgap):

```bash
# On connected sync host
sudo ./scripts/setup-apt-mirror-server.sh --role sync
```

```bash
# On airgap mirror (after copying /opt/apt or before rsync — dirs will exist)
sudo ./scripts/setup-apt-mirror-server.sh --role airgap
```

## Options

| Flag | Meaning |
|------|---------|
| `--no-keys` | Skip `populate-mirror-keys.sh` (e.g. keys copied manually) |
| `--no-timer` | Do not enable `apt-mirror.timer` (manual `apt-mirror` only) |
| `--keep-nginx-default` | Keep Debian’s default nginx site on port 80 |
| `--run-mirror-now` | Run `apt-mirror` once at the end (**long**; optional) |

## After setup

1. Edit **`/etc/apt/mirror.list`** if needed (Zabbix major, Debian codenames).
2. **Sync role:** run **`sudo apt-mirror`** once or wait for the timer; then **`scripts/rsync-to-airgap.sh`**.
3. **Airgap:** **`rsync`** `/opt/apt` from sync, **`sudo nginx -t && sudo systemctl reload nginx`**, DNS for **`apt.example.com`**.
4. Add TLS by uncommenting/editing the **`443`** server block in **`/etc/nginx/sites-available/apt.example.com.conf`** (or use the shipped vhost and fix **`ssl_certificate`** paths).

## Tear down and reconfigure from scratch

See **`docs/RESET.md`** and **`scripts/remove-apt-mirror-config.sh`**.
