# GPG keys and client trust

## Do you need a special key for the internal mirror?

**No.** apt-mirror copies upstream **`InRelease`** / **`Release`** (and related) files **unchanged**. Those files are still signed by **Debian**, **Ubuntu**, or **Zabbix** as usual. Your clients only change the **base URL** to `https://apt.example.com/...`; verification uses the **same** trusted keys as on the public internet.

What apt checks: the archive signature on **`InRelease`/`Release`**, then package integrity via **hashes** listed there (not a separate signature on every `.deb`).

## Client configuration

Use **`deb822`** `.sources` files with **`Signed-By=`** pointing at the right keyring file (see the per-vendor blocks in `docs/CLIENT_MIRROR_URLS.md`). Avoid deprecated **`apt-key add`**. You may use **`/etc/apt/trusted.gpg.d/`** instead of **`Signed-By=`**, but **`Signed-By=`** per vendor is narrower trust.

For a **one-shot client configuration** (fetch keys + write `.sources`), use **`scripts/setup-apt-client.sh`** — see **`docs/CLIENT_SETUP.md`**.

## Keyrings served from the mirror (recommended for airgap)

Populate **`/opt/apt/keys`** on the sync host and rsync it with the rest of **`/opt/apt`** so nginx exposes:

`https://apt.example.com/keys/debian-archive-keyring.gpg`  
`https://apt.example.com/keys/ubuntu-archive-keyring.gpg`  
`https://apt.example.com/keys/zabbix.gpg`  
`https://apt.example.com/keys/hashicorp.gpg`  
`https://apt.example.com/keys/openproject.gpg`  
`https://apt.example.com/keys/postgresql.gpg`

Use **`scripts/populate-mirror-keys.sh`** and read **`docs/MIRROR_HOST_KEYS.md`**. Clients **`curl`** those URLs into **`/etc/apt/keyrings/`** before **`apt update`**.

## Debian (archive)

- Package: `debian-archive-keyring` (install from your mirror, golden image, or **`curl`** from **`/keys/`** on the mirror host as above).
- Typical keyring path on clients: `/usr/share/keyrings/debian-archive-keyring.gpg` or `/etc/apt/keyrings/debian-archive-keyring.gpg` if copied from the mirror.
- Rotate when Debian publishes new archive keys (watch `debian-archive-keyring` changelog); re-run **`populate-mirror-keys.sh`** and rsync.

## Ubuntu (archive)

- Package: `ubuntu-keyring` / `ubuntu-archive-keyring` (exact name depends on Ubuntu release), or install **`ubuntu-archive-keyring.gpg`** from the mirror’s **`/keys/`** URL.
- Typical path on Ubuntu clients: `/usr/share/keyrings/ubuntu-archive-keyring.gpg` (verify with `dpkg -L ubuntu-keyring` on a reference host), or **`/etc/apt/keyrings/ubuntu-archive-keyring.gpg`** when bootstrapped from the mirror.

## Zabbix

- You need Zabbix’s **repository signing key** as a keyring file (not the Debian/Ubuntu archive keys).
- **On a connected machine**, fetch the key Zabbix documents (often `https://repo.zabbix.com/zabbix-official-repo.key`) and install:

```bash
sudo install -d -m0755 /etc/apt/keyrings
curl -fsSL https://repo.zabbix.com/zabbix-official-repo.key | sudo gpg --dearmor -o /etc/apt/keyrings/zabbix.gpg
sudo chmod 0644 /etc/apt/keyrings/zabbix.gpg
```

The upstream file is **armored**; **`gpg --dearmor`** is required for **`Signed-By=`** (see **`docs/TROUBLESHOOTING.md`** if you see **`NO_PUBKEY D913219AB5333005`**).

- **In an airgap:** clients cannot reach `repo.zabbix.com`. Prefer serving **`zabbix.gpg`** from **`https://apt.example.com/keys/zabbix.gpg`** (after **`populate-mirror-keys.sh`** + rsync). Alternatives: **config management**, **golden image**, or **USB** to `/etc/apt/keyrings/zabbix.gpg`.

- Point **`Signed-By=/etc/apt/keyrings/zabbix.gpg`** in Zabbix `.sources` files only.

## HashiCorp

- You need HashiCorp's **repository signing key** as a keyring file (not the Debian/Ubuntu archive keys).
- **On a connected machine**, fetch the key HashiCorp documents (`https://apt.releases.hashicorp.com/gpg`) and install:

```bash
sudo install -d -m0755 /etc/apt/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
sudo chmod 0644 /etc/apt/keyrings/hashicorp.gpg
```

The upstream file is **armored**; **`gpg --dearmor`** is required for **`Signed-By=`**.

- **In an airgap:** clients cannot reach `apt.releases.hashicorp.com`. Prefer serving **`hashicorp.gpg`** from **`https://apt.example.com/keys/hashicorp.gpg`** (after **`populate-mirror-keys.sh`** + rsync). Alternatives: **config management**, **golden image**, or **USB** to `/etc/apt/keyrings/hashicorp.gpg`.

- Point **`Signed-By=/etc/apt/keyrings/hashicorp.gpg`** in HashiCorp `.sources` files only.

## OpenProject

- You need OpenProject's **repository signing key** as a keyring file (not the Debian/Ubuntu archive keys).
- **On a connected machine**, fetch the key OpenProject documents (`https://packages.openproject.com/srv/deb/opf/openproject/gpg-key.asc`) and install:

```bash
sudo install -d -m0755 /etc/apt/keyrings
curl -fsSL https://packages.openproject.com/srv/deb/opf/openproject/gpg-key.asc | sudo gpg --dearmor -o /etc/apt/keyrings/openproject.gpg
sudo chmod 0644 /etc/apt/keyrings/openproject.gpg
```

The upstream file is **armored** (`.asc`); **`gpg --dearmor`** is required for **`Signed-By=`**.

- **In an airgap:** clients cannot reach `packages.openproject.com`. Prefer serving **`openproject.gpg`** from **`https://apt.example.com/keys/openproject.gpg`** (after **`populate-mirror-keys.sh`** + rsync). Alternatives: **config management**, **golden image**, or **USB** to `/etc/apt/keyrings/openproject.gpg`.

- Point **`Signed-By=/etc/apt/keyrings/openproject.gpg`** in OpenProject `.sources`/`.list` files only.
- OpenProject is only published for **Debian 12 (bookworm)** in this mirror; see **`docs/OPENPROJECT_REPO.md`**.

## PostgreSQL (PGDG)

- You need the **PGDG repository signing key** (key id `ACCC4CF8`) as a keyring file.
- **On a connected machine**, fetch the key PostgreSQL documents and install:

```bash
sudo install -d -m0755 /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
sudo chmod 0644 /etc/apt/keyrings/postgresql.gpg
```

The upstream file is **armored** (`.asc`); **`gpg --dearmor`** is required for **`Signed-By=`**.

- **In an airgap:** clients cannot reach `www.postgresql.org`. Prefer serving **`postgresql.gpg`** from **`https://apt.example.com/keys/postgresql.gpg`** (after **`populate-mirror-keys.sh`** + rsync). Alternatives: **config management**, **golden image**, or **USB** to `/etc/apt/keyrings/postgresql.gpg`.

- Point **`Signed-By=/etc/apt/keyrings/postgresql.gpg`** in PostgreSQL `.list` files only. See **`docs/POSTGRESQL_REPO.md`**.

## Airgap distribution

- Ship updated **`debian-archive-keyring`** / **`ubuntu-keyring`** packages through your mirror when upstream rotates keys.
- For third-party repos (**Zabbix**, **HashiCorp**, **OpenProject**, **PostgreSQL/PGDG**), re-run **`populate-mirror-keys.sh`** when upstream rotates a key and re-`rsync` `/opt/apt/keys` (which serves `zabbix.gpg`, `hashicorp.gpg`, `openproject.gpg`, `postgresql.gpg`), or push the updated `.gpg` via configuration management.

Do **not** use deprecated `apt-key add`.
