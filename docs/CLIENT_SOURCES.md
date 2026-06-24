# Client APT sources (`deb822`)

**Canonical URL list:** see **`docs/CLIENT_MIRROR_URLS.md`** (keyrings, repository `URIs=`, suites, health checks, and copy-paste deb822 blocks).

**Base URL:** `https://apt.example.com` (or `http://` only if you intentionally stay plaintext).

apt-mirror preserves upstream **host/path** segments under `/opt/apt/mirror/`, so **`URIs=`** on clients include that path. After the first sync, confirm paths with:

```bash
find /opt/apt/mirror -name InRelease | head
```

## Generate them — don't hand-write

Client sources are produced for you; there are no static snippet files to copy:

- **Dashboard → Client sources** (mirror-manager): pick the client OS, tick the repos, and
  download a ready `/etc/apt/sources.list.d/example.list` + keyring-install script, or
  copy the `curl … | sudo sh` bootstrap one-liner.
- **`scripts/setup-apt-client.sh`** on the client: writes the `*.sources`/`.list` files and
  fetches the keyrings (`--with-zabbix`, `--with-hashicorp`, `--with-openproject`,
  `--with-postgresql`; see `docs/CLIENT_SETUP.md`).

Copy-paste `deb822` / one-line `deb` blocks for each repo (with the right `Signed-By=` keyring
under `/etc/apt/keyrings/`) live in **`docs/CLIENT_MIRROR_URLS.md`**.

## Internal DNS

- **`apt.example.com`** must resolve to the **airgap** mirror (A/AAAA or CNAME to VIP).

## Governance

See `docs/RELEASE_GOVERNANCE.md` for EOL and suite retirement.
