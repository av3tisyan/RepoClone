# Reset configuration and start from scratch

Use this when you want to **drop** the files this project installs on a server and run **`setup-apt-mirror-server.sh`** again with a clean tree.

## 1. Remove deployed configs (and optionally data)

From your clone:

```bash
cd ~/apt-mirror   # or your path
sudo ./scripts/remove-apt-mirror-config.sh --yes
```

**Also delete mirror content** (everything under **`/opt/apt`**):

```bash
sudo ./scripts/remove-apt-mirror-config.sh --yes --purge-opt-apt
```

### Roles

| Flag | Removes |
|------|---------|
| `--role sync` (default with `--role both`) | `apt-mirror` systemd units, `/etc/apt/mirror.list`, logrotate |
| `--role airgap` | nginx `apt.example.com` site files under `sites-available` / `sites-enabled` |
| `--role both` | All of the above |

Optional **`--restore-nginx-default`**: re-enable Debian’s default **`sites-enabled/default`** if you removed it earlier and the file still exists.

**Packages** (`apt-mirror`, `nginx`, …) stay installed; remove with **`apt purge`** only if you want them gone.

If **`rm: cannot remove '/opt/apt': Device or resource busy`**: usually **`/opt/apt` is a mount point** (separate disk) or something still had files open. The script stops **nginx** first, then deletes **contents** with **`find`**. If it still fails: **`sudo umount /opt/apt`** (only if that mount is correct for your layout), then **`sudo rmdir /opt/apt`** or **`sudo mkdir -p /opt/apt`** after cleanup.

## 2. Configure again from the repository

```bash
sudo ./scripts/setup-apt-mirror-server.sh --role sync    # or airgap, or both
sudo ./scripts/populate-mirror-keys.sh                     # if not run by setup
```

Edit **`/etc/apt/mirror.list`** before the first long **`apt-mirror`** run if you need a smaller scope.

## 3. Clients

Hosts that used **`setup-apt-client.sh`** keep their **`/etc/apt/sources.list.d/example-*.sources`** until you change them. To point clients elsewhere, remove those files and restore **`/etc/apt/sources.list`** from your backup (see **`setup-apt-client.sh`** / **`SYSTEM_CLEANUP.md`**).
