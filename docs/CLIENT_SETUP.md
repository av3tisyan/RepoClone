# Client setup (automated)

**Mirror URLs and deb822 examples:** `docs/CLIENT_MIRROR_URLS.md`

Copy [`scripts/setup-apt-client.sh`](../scripts/setup-apt-client.sh) to the target host (USB, git clone, or config management) and run as **root**.

## Requirements

- **Debian** `bookworm` or `trixie`, or **Ubuntu** `noble` (matches mirrored suites).
- **`curl`** installed.
- Mirror must already serve **`/keys/`** and the repo trees (after `populate-mirror-keys.sh`, `apt-mirror`, and nginx on the airgap server). If **`/keys/`** is missing, the script falls back to **`/usr/share/keyrings/`** on the client when the same filenames exist (with a warning).
- DNS (or `/etc/hosts`) so the client can reach **`apt.example.com`** (or your `--mirror` URL).

## Examples

```bash
sudo ./setup-apt-client.sh
```

```bash
sudo APT_MIRROR_URL=https://apt.example.com ./setup-apt-client.sh --with-zabbix
```

```bash
sudo ./setup-apt-client.sh --with-zabbix --zabbix-major 7.4
sudo ./setup-apt-client.sh --with-zabbix --zabbix-major 7.0
```

```bash
sudo ./setup-apt-client.sh --with-hashicorp
```

```bash
sudo ./setup-apt-client.sh --with-openproject              # Debian bookworm only
```

```bash
sudo ./setup-apt-client.sh --with-postgresql               # bookworm / trixie / noble
```

```bash
# Trixie: some third-party repos (e.g. older Zabbix plugin feeds) fail apt’s sqv verifier after 2026-02-01; optional workaround:
sudo ./setup-apt-client.sh --use-gpg-not-sqv
```

Use **`--no-mirror-probe`** only if you intentionally configure clients before the mirror has finished first sync.

HTTP is only appropriate if you have not yet deployed TLS; prefer HTTPS once certificates exist.

## What it does

1. Downloads keyrings from **`${MIRROR}/keys/`** into **`/etc/apt/keyrings/`** (only the keys needed for this OS, plus Zabbix if `--with-zabbix`).
2. Writes **`/etc/apt/sources.list.d/example-*.sources`** (deb822) pointing at the mirror paths.
3. Backs up **`/etc/apt/sources.list`** and replaces it with a short stub so default distro entries do not duplicate the mirror (use **`--keep-sources`** to skip).
4. Runs **`apt-get update`** unless **`--no-apt-update`** is set.

## Zabbix

Use **`--with-zabbix`** and **`--zabbix-major`** to match what you mirror in **`config/mirror.list`** (default **`7.4`**; use **`7.0`** for the legacy path layout — see **`docs/ZABBIX_REPOS.md`**).

## HashiCorp

Use **`--with-hashicorp`** to fetch `hashicorp.gpg` and write `/etc/apt/sources.list.d/example-hashicorp.sources` (Terraform, Vault, Consul, etc.). Requires the HashiCorp block in **`config/mirror.list`** to have synced — see **`docs/CLIENT_MIRROR_URLS.md`**.

## OpenProject

Use **`--with-openproject`** to fetch `openproject.gpg` and write `/etc/apt/sources.list.d/example-openproject.list`. **Debian 12 (bookworm) only** — the script errors out on other suites/distros, since OpenProject does not publish trixie or noble. Override the tracked major with **`--openproject-major V`** (default **17**). Requires the OpenProject block in **`config/mirror.list`** to have synced — see **`docs/OPENPROJECT_REPO.md`**.

## PostgreSQL (PGDG)

Use **`--with-postgresql`** to fetch `postgresql.gpg` and write `/etc/apt/sources.list.d/example-postgresql.list` (suite `<codename>-pgdg`, component `main`). Works on **bookworm, trixie, and noble** — the suite is derived from the host codename. Then `sudo apt install postgresql-17`. Requires the PGDG block in **`config/mirror.list`** to have synced — see **`docs/POSTGRESQL_REPO.md`**.
