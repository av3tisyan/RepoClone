# Client APT sources (`deb822`)

**Canonical URL list:** see **`docs/CLIENT_MIRROR_URLS.md`** (keyrings, repository `URIs=`, suites, health checks, and copy-paste deb822 blocks).

**Base URL:** `https://apt.example.com` (or `http://` only if you intentionally stay plaintext).

apt-mirror preserves upstream **host/path** segments under `/opt/apt/mirror/`, so **`URIs=`** on clients include that path. After the first sync, confirm paths with:

```bash
find /opt/apt/mirror -name InRelease | head
```

## Example files (`docs/examples/`)

| Distro | Files |
|--------|--------|
| Debian 12 (bookworm) | `debian-bookworm.sources`, `debian-security-bookworm.sources` |
| Debian 13 (trixie) | `debian-trixie.sources`, `debian-security-trixie.sources` |
| Ubuntu 24.04 (noble) | `ubuntu-noble.sources` |
| Zabbix 7.0 | `zabbix-7.0-*.list` — `.../zabbix/7.0/{ubuntu,debian}` |
| Zabbix 7.4 | `zabbix-7.4-*.list` — `.../zabbix/7.4/stable/{ubuntu,debian}` (see `docs/ZABBIX_REPOS.md`) |
| HashiCorp | `hashicorp-{bookworm,trixie,noble}.sources` |
| OpenProject | `openproject-bookworm.list` — Debian 12 only, numeric suite `12` (see `docs/OPENPROJECT_REPO.md`) |
| PostgreSQL (PGDG) | `postgresql-bookworm.list` — suite `<codename>-pgdg`, component `main` (see `docs/POSTGRESQL_REPO.md`) |

Copy to `/etc/apt/sources.list.d/` and set **`Signed-By:`** to `/etc/apt/keyrings/...` (see `docs/CLIENT_MIRROR_URLS.md`). The examples under `docs/examples/` may still show `/usr/share/keyrings/`; prefer `/etc/apt/keyrings/` for consistency with `setup-apt-client.sh`.

Adjust **`URIs=`** and filenames if you mirror **Zabbix 6.0** or multiple majors.

## Internal DNS

- **`apt.example.com`** must resolve to the **airgap** mirror (A/AAAA or CNAME to VIP).

## Governance

See `docs/RELEASE_GOVERNANCE.md` for EOL and suite retirement.
