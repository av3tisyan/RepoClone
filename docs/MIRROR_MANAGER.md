# mirror-manager — web dashboard

A small, stdlib-only Python web app for the **connected sync host** that lets you:

- **paste just a repo URL** and let it **auto-discover** everything — match a known repo
  by host, or probe `dists/` for real suites, read components/architectures, skip empty
  suites, pick `amd64` vs `amd64,all`, and find the GPG key — then prefill the form;
- pick from a **catalog of recommended repos** (Debian, Ubuntu, Zabbix, Grafana, Elastic,
  HashiCorp, Docker, Tailscale, PostgreSQL, NodeSource, VS Code, Chrome, nginx, Sury PHP,
  OpenProject) and **add with one click** — categorized cards with a "configured" badge;
- or add a **custom** URL that it **probes and validates** first;
- **estimate the download size before adding** (sums the upstream `Packages` `Size:`
  fields) and warns if it would exceed free space;
- have it **auto-configure everything** — append the `deb`/`clean` lines to the managed
  `mirror.list` (under the default non-root install this is `/opt/apt/manager/mirror.list`,
  with `/etc/apt/mirror.list` a symlink to it), fetch + dearmor the repo's GPG key into
  `/opt/apt/keys`, and **start the download** (`apt-mirror`) in the background;
- **edit** a managed repo, **enable/disable** it (comment its lines without deleting), and
  **remove** it — optionally **purging the on-disk files** to reclaim space;
- open a **repo detail** view: suites/components, on-disk paths + size, last-updated,
  health, and a ready-to-paste **client configuration** (deb line + `setup-apt-client.sh`
  command, with copy buttons);
- watch **disk usage** (free / used / per-repo size vs TB budget), the **sync schedule**
  (`apt-mirror.timer` — view, enable/disable), and run a **sync** on demand with a live,
  progress-aware log.

It is intentionally small and dependency-free (Python 3 stdlib only) so it runs on an
air-gapped/offline sync host without `pip`.

The dashboard is an enterprise-style single-page app shell: a left sidebar nav switches
between **Overview** (KPI cards + storage), **Repositories**, **Catalog**, **Add repository**,
**Sync**, **Client sources**, and **Server** views (deep-linkable via `#hash`). It ships as
one self-contained `index.html` (no build step, no external assets — airgap-safe) and is
accessible: keyboard/focus-visible, `Escape`-to-close and focus-restoring modals, `aria-live`
toasts/status, a connection-lost banner, and reduced-motion support.

## Files

| Path | Purpose |
|------|---------|
| `scripts/mirror-manager/mirror_manager.py` | The HTTP daemon + JSON API |
| `scripts/mirror-manager/index.html` | Self-contained dashboard (no external assets) |
| `scripts/mirror-manager/presets.json` | Known-repo presets (keep in sync with `config/mirror.list`) |
| `deploy/systemd/mirror-manager.service` | systemd unit (runs as the non-root `apt-manager` user by default, binds 127.0.0.1:8080) |
| `deploy/nginx/mirror-manager.conf` | Optional LAN reverse proxy with basic auth + TLS |
| `scripts/setup-mirror-manager.sh` | Installer |

## Install

From the repo clone on the **sync host**:

```bash
sudo ./scripts/setup-mirror-manager.sh
# options: --port 8090  --budget-tb 1.6  --token s3cret  --no-enable
```

This copies the app to `/opt/apt/mirror-manager`, installs `mirror-manager.service`, and
starts it bound to **127.0.0.1:8080**. Requires `python3` and (for key fetch) `gnupg`.

By default the daemon runs as a dedicated **non-root `apt-manager`** user: the installer
creates the user, gives it `/opt/apt/{keys,www,var}` + a state dir `/opt/apt/manager`
(holding the canonical `mirror.list`, with `/etc/apt/mirror.list` symlinked to it), a
narrow **sudoers** grant to start/stop `apt-mirror.{service,timer}`, and `systemd-journal`
membership for log reads. Pass **`--user root`** to run as root instead (not recommended).

## Access

The daemon listens on **localhost only**. Ways to reach it:

1. **SSH tunnel** — nothing else to configure:
   ```bash
   ssh -L 8080:127.0.0.1:8080 <sync-host>
   # then open http://localhost:8080
   # via a jump host:  ssh -J <jump-host>[:port] -L 8080:127.0.0.1:8080 <sync-host>
   ```
2. **`https://apt-manager.example.com`** — a separate nginx reverse proxy (not the
   `apt.example.com` vhost) fronts the daemon with TLS + HTTP Basic auth validated
   against **LDAPS** (see *LDAPS authentication* below; a static htpasswd is also an option).
   The vhost is `deploy/nginx/mirror-manager.conf`; point DNS for
   `apt-manager.example.com` at the proxy host. Because the daemon binds
   `127.0.0.1:8080` on the **sync host**, the proxy reaches it either by running on the
   same host or via an SSH tunnel (see the header of that config); don't expose `:8080`
   raw on the LAN — it's a root-privileged API. The dashboard uses a **relative API base**,
   so it works at the proxy's root (or any subpath) without changes.

3. **Direct LAN access (bind to the subnet)** — bind the daemon to a routable address and
   restrict who may reach it with the built-in CIDR allowlist:
   ```bash
   sudo ./scripts/setup-mirror-manager.sh --listen-host 0.0.0.0 --allow 10.0.0.0/26 --token <secret>
   # dashboard: http://<sync-host-ip>:8080  (only 10.0.0.0/26 is answered)
   ```
   `MM_ALLOW` is enforced **in the daemon** (returns 403 to other source IPs), so even
   though it binds `0.0.0.0` it only serves your admin subnet. Use `--allow 0.0.0.0/0` to
   open it to everyone (not recommended — it's a root API; pair with `--token` at least).
   > If you put nginx in front, the daemon's peer is the proxy, not the user — so do the
   > IP filtering in nginx (`allow 10.0.0.0/26; deny all;`) instead of `MM_ALLOW`.

If you set `--token`, append `?token=<token>` to the URL.

## Using it

**Paste a URL (smartest):** put the repo root URL in *Paste a repository URL* → **Discover**.
If it's a known repo it's recognised as the matching preset; otherwise it probes `dists/`,
fills in the suites/components/arch it found and the key URL it located, and you just review
and click *Add / update*.

**Catalog (one click):** the *Recommended repositories* panel lists curated repos as cards
grouped by category; click **Add** to fetch the key, write the lines, and start a sync.
Already-configured ones show a *configured ✓* badge.

**Add a preset:** pick it from the dropdown → *Add repository*. The key is fetched and the
`deb`/`clean` lines are written; a background sync starts (uncheck the box to skip).

**Add a custom repo:** choose *— custom repository —*, enter the **base URL** (the repo root,
the directory **above** `dists/`), suite(s), components, and an optional **key URL**. Click
**Probe & validate** first — it reads `dists/<suite>/Release`, lists the real components and
architectures, reports which components actually contain `amd64`/`arch:all` packages, and
**suggests the arch flag** (`amd64` vs `amd64,all`). It warns if the suite is an empty stub
(HTTP 200 but zero packages — the trap we hit with OpenProject's trixie/noble).

**Estimate before adding:** click *Estimate size* — it downloads the upstream `Packages`
indexes for the chosen suites/components and sums the `Size:` fields, then shows
`≈ X to download · Y free` (red if it would exceed free space). Works for presets and custom.

**Repo details / edit / disable / remove:** click any repo row. The detail dialog shows
on-disk paths and size, last-updated, health, and the **client config** (a `deb` line
mapped to your public mirror URL + the matching `setup-apt-client.sh` command, both with
copy buttons). For managed repos you can **Enable/Disable** (comments the lines so
`apt-mirror` skips them without losing the config), **Edit in form**, or **Remove** — the
remove prompt offers to **purge the downloaded tree** to reclaim disk (it deletes only the
paths under that repo's URLs, never a shared host root beyond them).

**Integrity check** (Repositories view): *Verify now* validates each mirrored suite's
`InRelease` signature (via `gpgv` against the served keyring) and the **SHA256 of the index
files on disk** against what `Release` declares — catching corrupt or partial syncs. Results
are per-suite `ok` / `warn` (no key/sig) / `fail` (bad sig or hash mismatch) / `missing`. It
only hashes index files actually present, so files apt-mirror intentionally skipped aren't
false negatives. `GET /api/verify?repos=<name,name>` can also be polled from cron for alerting.

**Client landing page + bootstrap** (Server view): *Publish* generates, into `MM_WWW_DIR`
(default `/opt/apt/www`), both a human-readable `index.html` (repos + per-OS setup) and a
`setup.sh` bootstrap. nginx serves them at the mirror root and `/setup.sh`
(`deploy/nginx/apt.example.com.conf`), and they rsync to the airgap host with `/opt/apt`.
Clients then configure everything with one line:

```bash
curl -fsSL https://apt.example.com/setup.sh | sudo sh
```

`setup.sh` validates the OS first, **backs up and disables the distro defaults**
(`/etc/apt/sources.list` and Ubuntu's `sources.list.d/ubuntu.sources` → `*.example-bak-<ts>`)
so the client uses only the mirror, installs the keyrings, writes
`/etc/apt/sources.list.d/example.list`, and runs `apt-get update`. It's idempotent
(re-running won't pile up backups). *Preview setup.sh* / *Preview page* open them; the panel
shows the copy-paste one-liner.

**Disk-full guard:** syncs refuse to start when free space is below a floor
(`MM_MIN_FREE_GB`, default 50) — both from the dashboard (*Sync now* returns a clear refusal)
and from the timer (`scripts/apt-mirror-guard.sh`, wired as the `apt-mirror.service` ExecStart,
reads `MIN_FREE_GB` from `/etc/default/apt-mirror`). The *Free space* KPI turns red below the
floor. Stops a run from filling the volume to 100%.

**Snapshots & retention:** the *Snapshots* panel creates dated **hardlink** point-in-time
copies of the mirror (`scripts/mirror-snapshot.sh`, near-zero extra space) for rollback and
**client date-pinning** — nginx serves them at `…/snapshots/<id>/…` so a client can pin a
known-good date in its `URIs=`. *Prune* keeps the newest N (retention). `restore <id>` (CLI)
rsyncs a snapshot back over the live tree. Schedule periodic snapshots with a cron/timer
calling `mirror-snapshot.sh create` then `prune`.

**Budget estimation:** the Overview *Budget estimation* panel (`GET /api/estimate-all`)
estimates the **full upstream download size of every configured repo** (sums the `Packages`
`Size:` fields) and compares it to free space and the budget — a fits / exceeds-free /
exceeds-budget verdict plus a per-repo breakdown, so you can right-size before syncing.

**Visuals:** the Overview shows a disk-usage **donut** and a **"where the space goes"** bar
chart (top repos by size); the Repositories table has sortable columns and per-row size
mini-bars. A header health strip summarizes repo count / budget % / repos needing sync, and a
light/dark theme toggle (persisted) sits in the top bar.

**Disk usage:** the *Storage* panel shows live free/used (instant `df`), total mirror data,
and budget. Per-repo sizes come from `du` (slow on a TB mirror) and are cached; click
**Recompute sizes** to refresh.

> Repos not yet mirrored on disk (no `Release` for that suite) are **automatically excluded**
> from generated client sources and `setup.sh`, and shown greyed/"not synced" in the picker —
> so a client never gets a 404 for a repo apt-mirror hasn't downloaded yet. They appear once synced.

**Generate client sources:** the *Generate client sources* panel takes a client OS
(bookworm / trixie / noble) and produces a complete `/etc/apt/sources.list.d/example.list`
plus a keyring-install script covering every mirrored repo whose suite applies to that OS
(base + all third-party). Copy it or download the `.list` / `install-<codename>.sh`. Keyring
filenames are resolved to the names actually served under `/keys/` (so it matches a host set
up with `populate-mirror-keys.sh`).

**Server — mirror.list & setup:** the *Server* panel loads the live `mirror.list` this manager
maintains (copy/download) plus the commands to bootstrap another mirror server
(`setup-apt-mirror-server.sh` + `populate-mirror-keys.sh` + first `apt-mirror`).

**Config backup (DR):** *Download config backup (.tgz)* (`GET /api/backup`) bundles the
recovery essentials — `mirror.list`, `/opt/apt/keys`, `/etc/default/apt-mirror`, and the
manager unit drop-in — so you can rebuild the server after a loss (the multi-TB data is
re-syncable / snapshot-covered, so it's not in the bundle). Keep it **off-box** (it contains
signing keyrings). Restore with `scripts/mirror-backup.sh restore <file>` (it also does
`backup`/`list` from the CLI). Rebuild drill: `setup-apt-mirror-server.sh` → restore bundle →
`apt-mirror` (or restore a snapshot).

**Airgap transfer integrity:** for split sync→airgap deployments, `scripts/airgap-manifest.sh
create` (run on the sync host; `rsync-to-airgap.sh` does it automatically) writes a checksum
manifest carried with the data; `airgap-manifest.sh verify` on the airgap host confirms the
copy is complete and untampered before serving (`--quick` = sizes, default = full SHA-256).

**Sync & schedule:** *Sync now* starts `apt-mirror.service` (`--no-block`); the log panel
tails its journal with a best-effort progress bar. The *timer* button enables/disables
`apt-mirror.timer` and the header shows the next run. `postmirror.sh` still runs clean +
`fetch-binary-all.sh` afterwards.

## How it edits `mirror.list` (safe by design)

Everything the manager adds lives inside delimited blocks:

```text
# >>> mirror-manager: <name> >>>
deb [arch=amd64] <url> <suite> <components>
clean <url>
# <<< mirror-manager: <name> <<<
```

It **only** writes/removes inside these markers and backs up to `mirror.list.bak.mm` first.
Hand-maintained lines outside the markers are shown read-only as **manual** repos and are
never touched — so the manager and your existing `config/mirror.list` coexist. (Adding a
preset that you already maintain by hand would create a managed duplicate; remove the manual
lines first if you want the manager to own it.)

## LDAPS authentication (nginx)

nginx has no native LDAP auth, so the proxy validates HTTP Basic credentials against your
directory over **LDAPS** using nginx `auth_request` + a small backend
(`scripts/mirror-manager/ldap_auth.py`). The user still gets the normal browser Basic-auth
prompt; the password is checked against AD/LDAP instead of an htpasswd file.

On the **reverse-proxy host**:

```bash
sudo apt-get install -y python3-ldap
sudo install -d -m0755 /opt/apt/mirror-manager
sudo install -m0644 scripts/mirror-manager/ldap_auth.py /opt/apt/mirror-manager/ldap_auth.py
sudo cp deploy/systemd/mirror-manager-ldap-auth.service /etc/systemd/system/
sudoedit /etc/systemd/system/mirror-manager-ldap-auth.service   # set LDAP_* (see below)
sudo systemctl daemon-reload && sudo systemctl enable --now mirror-manager-ldap-auth
sudo cp deploy/nginx/mirror-manager.conf /etc/nginx/sites-available/ && \
  sudo ln -sf /etc/nginx/sites-available/mirror-manager.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Bind models (env in the service unit):

- **direct** (default, simplest for AD): `LDAP_BIND_MODE=direct` +
  `LDAP_USER_DN_TEMPLATE={user}@example.com` — binds straight as the user, no service
  account needed.
- **search**: `LDAP_BIND_MODE=search` with `LDAP_BIND_DN`/`LDAP_BIND_PW`/`LDAP_BASE_DN`/
  `LDAP_USER_FILTER=(sAMAccountName={user})` — a service account finds the user, then the
  daemon rebinds as them to verify the password.

Always use an `ldaps://…:636` `LDAP_URI`; set `LDAP_CA` to verify the server cert
(`LDAP_TLS_REQCERT=demand`). Restrict who may log in with
`LDAP_REQUIRED_GROUP=CN=apt-admins,OU=Groups,DC=example,DC=com` (AD nested groups
supported). Successful auths are cached `LA_CACHE_TTL` seconds; denials log the username
and reason only — never the password. A static htpasswd still works if you prefer: drop the
`auth_request`/`@ldap_challenge` lines and use `auth_basic` + `auth_basic_user_file`.

## Security model

- The daemon **runs as the non-root `apt-manager`** user by default. It owns only
  `/opt/apt/{keys,www,var,manager}` and the managed `mirror.list`, and is granted — via a
  narrow **sudoers** rule — exactly the ability to start/stop `apt-mirror.{service,timer}`
  (nothing else). It still triggers privileged work, so **treat access as
  sync-host-privileged**, but it is no longer root-equivalent. (`--user root` opts back into
  the old root behavior, which writes `/etc/apt/mirror.list` directly — not recommended.)
- It has **no built-in login.** Defence comes from: binding to localhost by default; an
  `MM_ALLOW` CIDR allowlist for direct LAN binds; an optional `MM_TOKEN` shared secret; and
  an `X-MM: 1` header required on mutating calls (blunts CSRF from a stray browser form).
- **Do not bind `0.0.0.0` without `MM_ALLOW` and/or `MM_TOKEN`** — that opens the root API
  to the whole network (the installer and daemon both warn about this).
- Best exposure: front it with TLS + basic auth (`apt-manager.example.com`,
  `deploy/nginx/mirror-manager.conf`) or reach it over SSH; when proxied, filter source IPs
  in nginx, not `MM_ALLOW`.

## Limitations

- It writes config and downloads on the **sync host**; clients are still configured with
  `scripts/setup-apt-client.sh`.
- Removing a repo deletes only its `mirror.list` block — **downloaded files stay on disk**
  until the next `apt-mirror`/clean cycle (or a manual purge of the tree under `/opt/apt/mirror`).
- Presets encode the suite/component quirks we documented (e.g. PostgreSQL's `main`,
  OpenProject's numeric bookworm-only suite). For anything exotic, use custom + probe.
- Key rotation for archive keyrings (Debian/Ubuntu) is still handled by
  `scripts/populate-mirror-keys.sh`.

## Environment overrides

`MM_LISTEN_HOST`, `MM_LISTEN_PORT`, `MM_MIRROR_LIST`, `MM_MIRROR_PATH`, `MM_KEYS_DIR`,
`MM_VAR_DIR`, `MM_BUDGET_BYTES`, `MM_APT_UNIT`, `MM_APT_TIMER`, `MM_PUBLIC_URL` (base URL in
generated client config, default `https://apt.example.com`), `MM_WWW_DIR` (landing-page
output dir, default `/opt/apt/www`), `MM_MIN_FREE_GB` (sync free-space floor, default 50),
`MM_SNAP_DIR` (`/opt/apt/snapshots`), `MM_SNAPSHOT_SH` (`/opt/apt/var/mirror-snapshot.sh`),
`MM_TOKEN`, `MM_ALLOW`
(CIDR allowlist for direct access) — see the header of
`scripts/mirror-manager/mirror_manager.py`. The installer sets the common ones via a systemd
drop-in (`--listen-host`, `--allow`, `--port`, `--token`, `--budget-tb`).
