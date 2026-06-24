# PostgreSQL (PGDG) upstream paths and mirror layout

PostgreSQL packages come from the **PGDG** repository (PostgreSQL Global Development
Group) at [apt.postgresql.org](https://apt.postgresql.org/). This mirror tracks it to
provide **PostgreSQL 17** (and, as a side effect of the repo layout, every other PGDG
version and extension — see below).

## Repository shape

- **Base URL:** `https://apt.postgresql.org/pub/repos/apt`
- **Suites:** `<codename>-pgdg` — `bookworm-pgdg`, `trixie-pgdg`, `noble-pgdg` (all three
  of this mirror's target distros are published, with real packages — unlike OpenProject).
- **Components:** `main` plus numbered per-version components (`8.2`…`19`).

### The component layout is counter-intuitive

The actual server packages — **`postgresql-17`, `postgresql-client-17`,
`postgresql-common`, `postgresql-contrib`, and every extension** — live in the **`main`**
component. The numbered `17` component holds only **version-pinned `libpq`/`libecpg`
libraries**, not the server. So to install PostgreSQL 17 you mirror **`main`**, not `17`.

Because apt-mirror cannot filter packages *within* a component, mirroring `main` pulls
**all** PGDG versions (`8.2`…`19`) and all extensions: roughly **2.2 GB per suite**
(~6.7 GB across bookworm/trixie/noble, amd64). That is the only way to get a working
`postgresql-17`, and it is negligible against the ~1.6 TB disk budget.

### Architecture / keys

- amd64 only. There is a `binary-all/` directory but it is **empty** — arch:all packages
  (e.g. `postgresql-common`) are listed inside `binary-amd64/Packages`. So the
  `mirror.list` line uses `[arch=amd64]` (not `,all`) and `scripts/fetch-binary-all.sh`
  intentionally skips it.
- Repo signing key (key id `ACCC4CF8`): `https://www.postgresql.org/media/keys/ACCC4CF8.asc`
  (armored) — dearmored to `postgresql.gpg` by `scripts/populate-mirror-keys.sh`.

## Dependency notes (why `main` is required, not just convenient)

`postgresql-17` depends on `postgresql-common (>= 252~)` and `libpq5 (>= 17~~)`. Base
Debian/Ubuntu ship versions that are **too old** (e.g. bookworm `postgresql-common` 248,
`libpq5` 15.x), so those dependencies can only be satisfied from PGDG `main`. The
remaining system libraries resolve from the mirrored distro base:

| Dependency | Source |
|------------|--------|
| `postgresql-common` (291), `postgresql-client-17`, `libpq5` (17) | PGDG `main` |
| `libllvm19` (JIT) | base Debian `main` (bookworm/trixie); **`noble-updates` `main`** on Ubuntu |
| `libicu72`, `libc6`, `libssl3`, `ssl-cert`, `tzdata`, … | base Debian/Ubuntu |

> Ubuntu note: `libllvm19` is in `noble-updates`, not `noble` release. The mirror already
> syncs `noble noble-updates noble-security`, so it resolves — but a client that omits
> `noble-updates` would fail to install `postgresql-17`.

## `deb` lines in `config/mirror.list`

```text
deb [arch=amd64] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main
deb [arch=amd64] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main
deb [arch=amd64] https://apt.postgresql.org/pub/repos/apt noble-pgdg main
clean https://apt.postgresql.org/pub/repos/apt
```

On disk after sync:

```text
/opt/apt/mirror/apt.postgresql.org/pub/repos/apt/dists/<codename>-pgdg/
```

## Client `deb` line (internal mirror)

One-line `.list` (amd64 only, no usable `binary-all` — same reasoning as Zabbix):

```text
deb [arch=amd64 signed-by=/etc/apt/keyrings/postgresql.gpg] \
  https://apt.example.com/apt.postgresql.org/pub/repos/apt <codename>-pgdg main
```

`<codename>` = `bookworm`, `trixie`, or `noble`. **GPG:** `/etc/apt/keyrings/postgresql.gpg`
(dearmored from `ACCC4CF8.asc`) — see `docs/GPG_KEYS.md`.

After `apt update`, install with `sudo apt install postgresql-17` (or `postgresql-client-17`).

## Setup

- **Server:** `config/mirror.list` already includes the PGDG `deb`/`clean` lines;
  `scripts/populate-mirror-keys.sh` fetches and dearmors `postgresql.gpg` into `/opt/apt/keys/`.
- **Client:** `sudo ./scripts/setup-apt-client.sh --with-postgresql` (works on bookworm,
  trixie, and noble; the suite is derived from the host codename).
