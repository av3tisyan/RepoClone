# Zabbix upstream paths and mirror layout

Official APT roots:

| Zabbix version | Channel | Upstream path | `binary-amd64` (needed for apt-mirror `defaultarch amd64`) |
|----------------|---------|---------------|-------------------------------------------------------------|
| **7.0**, **6.0** | (default) | `https://repo.zabbix.com/zabbix/<ver>/{debian\|ubuntu}` | Yes |
| **7.4+** | **stable** | `https://repo.zabbix.com/zabbix/<ver>/stable/{debian\|ubuntu}` | Yes |
| **7.4+** | **release** | `https://repo.zabbix.com/zabbix/<ver>/release/{debian\|ubuntu}` | **No** — only `binary-all` |

Browse: [Zabbix 7.4 stable](https://repo.zabbix.com/zabbix/7.4/stable/) · [7.4 release](https://repo.zabbix.com/zabbix/7.4/release/) (metadata-only style tree; do not mirror with apt-mirror amd64 policy).

**Why not `/release/` on the mirror?** apt-mirror with `set defaultarch amd64` looks for `dists/<suite>/main/binary-amd64/Packages`. Zabbix **7.4 release** `InRelease` lists only `main/binary-all/` — logs show:

`can't open index .../zabbix/7.4/release/ubuntu//dists/noble/main/binary-amd64/Packages`

Use **`/stable/`** in `config/mirror.list` and on clients (Zabbix documents stable for package installs on Ubuntu/Debian).

## Mirrored paths under `/opt/apt/mirror/`

| Target | `deb` line in `config/mirror.list` | On disk after sync |
|--------|-----------------------------------|---------------------|
| Ubuntu (7.0) | `.../zabbix/7.0/ubuntu` + `noble` | `repo.zabbix.com/zabbix/7.0/ubuntu/` |
| Debian (7.0) | `.../zabbix/7.0/debian` + `bookworm` / `trixie` | `repo.zabbix.com/zabbix/7.0/debian/` |
| Ubuntu (7.4) | `.../zabbix/7.4/stable/ubuntu` + suite | `repo.zabbix.com/zabbix/7.4/stable/ubuntu/` |
| Debian (7.4) | `.../zabbix/7.4/stable/debian` + suite | `repo.zabbix.com/zabbix/7.4/stable/debian/` |

## Client `URIs=` (internal mirror)

**Zabbix 7.0**

- `https://apt.example.com/repo.zabbix.com/zabbix/7.0/ubuntu`
- `https://apt.example.com/repo.zabbix.com/zabbix/7.0/debian`

**Zabbix 7.4 (stable)**

- `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/ubuntu`
- `https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/debian`

**GPG:** `/etc/apt/keyrings/zabbix.gpg` — see `docs/GPG_KEYS.md`.

**Client format:** `deb [arch=amd64 signed-by=…]` in `example-zabbix.list` — see `docs/examples/zabbix-7.4-noble.list`.

**Automation:** `setup-apt-client.sh --with-zabbix` (default `--zabbix-major 7.4` → **stable** path). For 7.0: `--zabbix-major 7.0`.

**Multiple majors:** both 7.0 and 7.4 blocks in `config/mirror.list`; clients usually enable one major.
