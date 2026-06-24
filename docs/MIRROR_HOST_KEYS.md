# GPG keyrings on the mirror host (`/opt/apt/keys`)

The airgap **nginx** server can serve **pre-copied** archive key files so clients never need outbound access to `deb.debian.org`, `archive.ubuntu.com`, or `repo.zabbix.com` **just to obtain keys**.

## Layout

| Path on mirror server | Served at |
|-----------------------|-----------|
| `/opt/apt/keys/debian-archive-keyring.gpg` | `https://apt.example.com/keys/debian-archive-keyring.gpg` |
| `/opt/apt/keys/ubuntu-archive-keyring.gpg` | `https://apt.example.com/keys/ubuntu-archive-keyring.gpg` |
| `/opt/apt/keys/zabbix.gpg` | `https://apt.example.com/keys/zabbix.gpg` |
| `/opt/apt/keys/hashicorp.gpg` | `https://apt.example.com/keys/hashicorp.gpg` |
| `/opt/apt/keys/SHA256SUMS` | checksums for the `.gpg` files |

`location /keys/` is defined in `deploy/nginx/apt.example.com.conf`.

## Populate (connected sync host)

On a machine that can reach the public internet:

```bash
sudo ./scripts/populate-mirror-keys.sh
```

This creates **`/opt/apt/keys`**, fills it using:

- **`debian-archive-keyring.gpg`** — copied from `/usr/share/keyrings/` if `debian-archive-keyring` is installed (typical on Debian 13).
- **`ubuntu-archive-keyring.gpg`** — extracted from the official **`ubuntu-keyring`** `.deb` on Ubuntu’s pool (version set by **`UBUNTU_KEYRING_VER`**, default pinned in the script).
- **`zabbix.gpg`** — downloaded from Zabbix’s documented key URL and **dearmored** with `gpg --dearmor` (required for client **`Signed-By=`**).
- **`hashicorp.gpg`** — downloaded from `https://apt.releases.hashicorp.com/gpg` and **dearmored** with `gpg --dearmor` (required for client **`Signed-By=`**).

If the Ubuntu download fails, pick a current **`ubuntu-keyring_*_all.deb`** from [pool](http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/) and set:

```bash
export UBUNTU_KEYRING_VER='2023.11.28.1'
sudo -E ./scripts/populate-mirror-keys.sh
```

## Airgap

`rsync` of **`/opt/apt`** (see `scripts/rsync-to-airgap.sh`) includes **`keys/`**. After transfer, **`nginx -t && systemctl reload nginx`** on the airgap host.

## Clients (first boot or automation)

After trust in TLS / DNS for `apt.example.com`, install keyrings before pointing `.sources` at the mirror:

```bash
sudo install -d -m0755 /etc/apt/keyrings
sudo curl -fsSL https://apt.example.com/keys/debian-archive-keyring.gpg \
  -o /etc/apt/keyrings/debian-archive-keyring.gpg
sudo curl -fsSL https://apt.example.com/keys/ubuntu-archive-keyring.gpg \
  -o /etc/apt/keyrings/ubuntu-archive-keyring.gpg
sudo curl -fsSL https://apt.example.com/keys/zabbix.gpg \
  -o /etc/apt/keyrings/zabbix.gpg
sudo curl -fsSL https://apt.example.com/keys/hashicorp.gpg \
  -o /etc/apt/keyrings/hashicorp.gpg
sudo chmod 0644 /etc/apt/keyrings/*.gpg
```

Optional: verify **`SHA256SUMS`** against published checksums after download.

Then use the same **`Signed-By=`** paths as in `docs/examples/` (paths under `/etc/apt/keyrings/` match).
