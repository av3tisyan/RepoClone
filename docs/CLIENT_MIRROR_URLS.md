# Client mirror URLs

Reference for hosts that use the internal APT mirror at **`https://apt.example.com`**.

apt-mirror keeps upstream **host/path** segments under `/opt/apt/mirror/`, so client **`URIs=`** values include those segments (for example `.../deb.debian.org/debian`, not `.../debian` alone). See `docs/TROUBLESHOOTING.md` if `apt update` cannot find `InRelease`.

**Base URL:** `https://apt.example.com`  
Override on clients with `APT_MIRROR_URL` or `setup-apt-client.sh --mirror <url>` (trailing slash is stripped).

**DNS:** `apt.example.com` must resolve to the airgap mirror (A/AAAA, CNAME, or `/etc/hosts`).

---

## GPG keyrings

Install these into **`/etc/apt/keyrings/`** before enabling repository sources (or run `scripts/setup-apt-client.sh`, which fetches them automatically).

| Keyring | URL | Client path |
|---------|-----|-------------|
| Debian archive | `https://apt.example.com/keys/debian-archive-keyring.gpg` | `/etc/apt/keyrings/debian-archive-keyring.gpg` |
| Ubuntu archive | `https://apt.example.com/keys/ubuntu-archive-keyring.gpg` | `/etc/apt/keyrings/ubuntu-archive-keyring.gpg` |
| Zabbix repo | `https://apt.example.com/keys/zabbix.gpg` | `/etc/apt/keyrings/zabbix.gpg` |
| HashiCorp repo | `https://apt.example.com/keys/hashicorp.gpg` | `/etc/apt/keyrings/hashicorp.gpg` |
| OpenProject repo | `https://apt.example.com/keys/openproject.gpg` | `/etc/apt/keyrings/openproject.gpg` |
| PostgreSQL (PGDG) repo | `https://apt.example.com/keys/postgresql.gpg` | `/etc/apt/keyrings/postgresql.gpg` |

The mirror publishes **`zabbix.gpg`** already **dearmored** (after `populate-mirror-keys.sh`). If you copy an old armored file or fetch `zabbix-official-repo.key` directly, run **`gpg --dearmor`** — see **`docs/TROUBLESHOOTING.md`** (`NO_PUBKEY D913219AB5333005`).

Manual install (Debian/Ubuntu archive keys):

```bash
sudo install -d -m0755 /etc/apt/keyrings
sudo curl -fsSL https://apt.example.com/keys/debian-archive-keyring.gpg \
  -o /etc/apt/keyrings/debian-archive-keyring.gpg
sudo chmod 0644 /etc/apt/keyrings/debian-archive-keyring.gpg
```

Zabbix key (from mirror; file should already be dearmored):

```bash
sudo curl -fsSL https://apt.example.com/keys/zabbix.gpg -o /etc/apt/keyrings/zabbix.gpg
sudo chmod 0644 /etc/apt/keyrings/zabbix.gpg
```

HashiCorp key (from mirror; file should already be dearmored):

```bash
sudo curl -fsSL https://apt.example.com/keys/hashicorp.gpg -o /etc/apt/keyrings/hashicorp.gpg
sudo chmod 0644 /etc/apt/keyrings/hashicorp.gpg
```

OpenProject key (from mirror; file should already be dearmored):

```bash
sudo curl -fsSL https://apt.example.com/keys/openproject.gpg -o /etc/apt/keyrings/openproject.gpg
sudo chmod 0644 /etc/apt/keyrings/openproject.gpg
```

PostgreSQL (PGDG) key (from mirror; file should already be dearmored):

```bash
sudo curl -fsSL https://apt.example.com/keys/postgresql.gpg -o /etc/apt/keyrings/postgresql.gpg
sudo chmod 0644 /etc/apt/keyrings/postgresql.gpg
```

See `docs/MIRROR_HOST_KEYS.md` for how these files are published on the mirror host.

---

## Debian (bookworm / trixie)

| Repository | `URIs:` | Example `Suites:` | `Signed-By:` |
|------------|---------|---------------------|--------------|
| Main + updates | `https://apt.example.com/deb.debian.org/debian` | `bookworm bookworm-updates` or `trixie trixie-updates` | `/etc/apt/keyrings/debian-archive-keyring.gpg` |
| Security | `https://apt.example.com/security.debian.org/debian-security` | `bookworm-security` or `trixie-security` | `/etc/apt/keyrings/debian-archive-keyring.gpg` |

**Components:** `main contrib non-free non-free-firmware`


### Example: Debian 13 (trixie) main

```deb822
Types: deb
URIs: https://apt.example.com/deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /etc/apt/keyrings/debian-archive-keyring.gpg
```

### Example: Debian 13 (trixie) security

```deb822
Types: deb
URIs: https://apt.example.com/security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /etc/apt/keyrings/debian-archive-keyring.gpg
```

---

## Ubuntu (noble)

| Repository | `URIs:` | Example `Suites:` | `Signed-By:` |
|------------|---------|---------------------|--------------|
| Archive + updates + security | `https://apt.example.com/archive.ubuntu.com/ubuntu` | `noble noble-updates noble-security` | `/etc/apt/keyrings/ubuntu-archive-keyring.gpg` |

**Components:** `main universe` (no `restricted` — excludes NVIDIA drivers/intel-microcode/restricted firmware to save mirror space; add it back in `config/mirror.list` and here if your fleet needs it)


### Example: Ubuntu 24.04 (noble)

```deb822
Types: deb
URIs: https://apt.example.com/archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /etc/apt/keyrings/ubuntu-archive-keyring.gpg
```

---

## Zabbix (optional)

Only enable if the mirror syncs Zabbix (see `config/mirror.list`) and you installed `zabbix.gpg` (use `setup-apt-client.sh --with-zabbix` or fetch the key above).

Default major in scripts: **7.4**. Path layout differs by version — see **`docs/ZABBIX_REPOS.md`**.

| Version | Ubuntu `URIs:` base | Debian `URIs:` base |
|---------|---------------------|---------------------|
| **7.4** | `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/ubuntu` | `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/debian` |
| **7.0** | `https://apt.example.com/repo.zabbix.com/zabbix/7.0/ubuntu` | `https://apt.example.com/repo.zabbix.com/zabbix/7.0/debian` |

**Suites:** codename (`noble`, `bookworm`, `trixie`, …) · **Signed-By:** `/etc/apt/keyrings/zabbix.gpg`

**Components:** `main`  
**Format:** one-line **`deb [arch=amd64 signed-by=…]`** in a **`.list`** file (mirror is **amd64** only; without **`arch=amd64`**, apt requests **`binary-all`** and gets **404**)


### Example: Zabbix 7.4 on Ubuntu noble

```sources
deb [arch=amd64 signed-by=/etc/apt/keyrings/zabbix.gpg] https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/ubuntu noble main
```

Install as **`/etc/apt/sources.list.d/example-zabbix.list`** (or any `*.list` name under `sources.list.d/`).

---

## HashiCorp (optional)

Only enable if the mirror syncs HashiCorp (see `config/mirror.list`) and you installed `hashicorp.gpg` (use `setup-apt-client.sh --with-hashicorp` or fetch the key above). Provides Terraform, Vault, Consul, Boundary, Nomad, Packer, etc.

| Repository | `URIs:` | `Suites:` | `Signed-By:` |
|------------|---------|-----------|--------------|
| HashiCorp | `https://apt.example.com/apt.releases.hashicorp.com` | codename (`bookworm`, `trixie`, `noble`) | `/etc/apt/keyrings/hashicorp.gpg` |

**Components:** `main`


### Example: HashiCorp on Debian 12 (bookworm)

```deb822
Types: deb
URIs: https://apt.example.com/apt.releases.hashicorp.com
Suites: bookworm
Components: main
Signed-By: /etc/apt/keyrings/hashicorp.gpg
```

Install as **`/etc/apt/sources.list.d/example-hashicorp.sources`**.

---

## OpenProject (optional)

Only enable if the mirror syncs OpenProject (see `config/mirror.list`) and you installed `openproject.gpg` (use `setup-apt-client.sh --with-openproject` or fetch the key above). **Debian 12 (bookworm) only** — OpenProject does not publish trixie/noble. Details: **`docs/OPENPROJECT_REPO.md`**.

| Repository | `URIs:` base | `Suite` | `Signed-By:` |
|------------|--------------|---------|--------------|
| OpenProject 17 | `https://apt.example.com/packages.openproject.com/srv/deb/opf/openproject/stable/17/debian` | `12` | `/etc/apt/keyrings/openproject.gpg` |

**Suite is the numeric `12`** (the upstream packager.io suite name), **not** `bookworm`.

**Components:** `main`  
**Format:** one-line **`deb [arch=amd64 signed-by=…]`** in a **`.list`** file (mirror is **amd64** only, no `binary-all`).


### Example: OpenProject 17 on Debian 12 (bookworm)

```sources
deb [arch=amd64 signed-by=/etc/apt/keyrings/openproject.gpg] https://apt.example.com/packages.openproject.com/srv/deb/opf/openproject/stable/17/debian 12 main
```

Install as **`/etc/apt/sources.list.d/example-openproject.list`**.

---

## PostgreSQL (PGDG, optional)

Only enable if the mirror syncs PostgreSQL (see `config/mirror.list`) and you installed `postgresql.gpg` (use `setup-apt-client.sh --with-postgresql` or fetch the key above). Provides **postgresql-17** and every other PGDG version/extension. Works on bookworm, trixie, and noble. Details: **`docs/POSTGRESQL_REPO.md`**.

| Repository | `URIs:` base | `Suite` | `Signed-By:` |
|------------|--------------|---------|--------------|
| PGDG | `https://apt.example.com/apt.postgresql.org/pub/repos/apt` | `<codename>-pgdg` | `/etc/apt/keyrings/postgresql.gpg` |

**Suite is `<codename>-pgdg`** (`bookworm-pgdg`, `trixie-pgdg`, `noble-pgdg`). **Component:** `main` (postgresql-17, postgresql-common, libpq5, and all extensions live here — *not* the numbered `17` component).

**Format:** one-line **`deb [arch=amd64 signed-by=…]`** in a **`.list`** file (mirror is **amd64** only, no usable `binary-all`).


### Example: PostgreSQL on Debian 12 (bookworm)

```sources
deb [arch=amd64 signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.example.com/apt.postgresql.org/pub/repos/apt bookworm-pgdg main
```

Install as **`/etc/apt/sources.list.d/example-postgresql.list`**, then `sudo apt update && sudo apt install postgresql-17`.

---

## Health-check URLs

Use these to confirm the mirror has synced a suite (same paths `setup-apt-client.sh` probes):

| OS | URL pattern |
|----|-------------|
| Debian | `https://apt.example.com/deb.debian.org/debian/dists/<codename>/InRelease` |
| Ubuntu | `https://apt.example.com/archive.ubuntu.com/ubuntu/dists/<codename>/InRelease` |

Example:

```bash
curl -fsSI https://apt.example.com/deb.debian.org/debian/dists/trixie/InRelease
```

Or run `scripts/check-mirror-health.sh https://apt.example.com` on a host that can reach the mirror.

---

## Automated client setup

Prefer the script over hand-editing sources:

```bash
sudo ./scripts/setup-apt-client.sh
sudo ./scripts/setup-apt-client.sh --with-zabbix
sudo ./scripts/setup-apt-client.sh --with-zabbix --zabbix-major 7.4
sudo ./scripts/setup-apt-client.sh --with-zabbix --zabbix-major 7.0
sudo ./scripts/setup-apt-client.sh --with-hashicorp
sudo ./scripts/setup-apt-client.sh --with-openproject              # Debian bookworm only
sudo ./scripts/setup-apt-client.sh --with-postgresql               # bookworm / trixie / noble
```

Details: `docs/CLIENT_SETUP.md`.

The script writes:

| File | Purpose |
|------|---------|
| `/etc/apt/sources.list.d/example-debian-main.sources` | Debian main + updates |
| `/etc/apt/sources.list.d/example-debian-security.sources` | Debian security |
| `/etc/apt/sources.list.d/example-ubuntu.sources` | Ubuntu (noble) |
| `/etc/apt/sources.list.d/example-zabbix.list` | Zabbix (with `--with-zabbix`) |
| `/etc/apt/sources.list.d/example-hashicorp.sources` | HashiCorp (with `--with-hashicorp`) |
| `/etc/apt/sources.list.d/example-openproject.list` | OpenProject (with `--with-openproject`; Debian bookworm only) |
| `/etc/apt/sources.list.d/example-postgresql.list` | PostgreSQL PGDG (with `--with-postgresql`) |

---

## URL quick reference

Replace `<codename>` with your release (`bookworm`, `trixie`, `noble`, …).

| Purpose | URL |
|---------|-----|
| Base | `https://apt.example.com` |
| Debian main | `https://apt.example.com/deb.debian.org/debian` |
| Debian security | `https://apt.example.com/security.debian.org/debian-security` |
| Ubuntu | `https://apt.example.com/archive.ubuntu.com/ubuntu` |
| Zabbix 7.4 Debian | `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/debian` |
| Zabbix 7.4 Ubuntu | `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/ubuntu` |
| Zabbix 7.0 Debian | `https://apt.example.com/repo.zabbix.com/zabbix/7.0/debian` |
| Zabbix 7.0 Ubuntu | `https://apt.example.com/repo.zabbix.com/zabbix/7.0/ubuntu` |
| HashiCorp | `https://apt.example.com/apt.releases.hashicorp.com` |
| OpenProject 17 (Debian 12) | `https://apt.example.com/packages.openproject.com/srv/deb/opf/openproject/stable/17/debian` |
| PostgreSQL (PGDG) | `https://apt.example.com/apt.postgresql.org/pub/repos/apt` |
| Key: Debian | `https://apt.example.com/keys/debian-archive-keyring.gpg` |
| Key: Ubuntu | `https://apt.example.com/keys/ubuntu-archive-keyring.gpg` |
| Key: Zabbix | `https://apt.example.com/keys/zabbix.gpg` |
| Key: HashiCorp | `https://apt.example.com/keys/hashicorp.gpg` |
| Key: OpenProject | `https://apt.example.com/keys/openproject.gpg` |
| Key: PostgreSQL | `https://apt.example.com/keys/postgresql.gpg` |

---

## Related docs

- `docs/CLIENT_SETUP.md` — `setup-apt-client.sh` usage and flags  
- `docs/CLIENT_SOURCES.md` — deb822 snippets index  
- `docs/GPG_KEYS.md` — why upstream signatures still apply on the mirror  
- `docs/ZABBIX_REPOS.md` — Zabbix path layout on disk  
- `docs/OPENPROJECT_REPO.md` — OpenProject path layout, numeric suite, Debian-12-only note  
- `docs/POSTGRESQL_REPO.md` — PGDG path layout, `<codename>-pgdg main`, postgresql-17 in `main`  
- `docs/RELEASE_GOVERNANCE.md` — supported suites and EOL
