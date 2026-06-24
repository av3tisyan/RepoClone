# OpenProject upstream paths and mirror layout

OpenProject ships its packages through a **packager.io** repository. The public landing
page is [packages.openproject.com/u/opf/openproject](https://packages.openproject.com/u/opf/openproject);
the actual APT content lives under `…/srv/deb/opf/openproject/`.

Two things differ from a normal Debian/Ubuntu repo:

1. **The suite is the OS version *number*, not a codename** — `12` for Debian 12, not `bookworm`.
2. **packager.io generates `dists/<suite>/Release` on the fly.** A request for a suite
   that has no packages still returns **HTTP 200** with a valid (empty) `Release`. Existence
   of `Release` does **not** mean packages exist.

## What is actually published (verified)

Only suites with real `.deb` files are worth mirroring. As checked against
`dists/<suite>/main/binary-amd64/Packages.gz`:

| Distro | Suite | Packages? | Mirrored here? |
|--------|-------|-----------|----------------|
| Debian 11 (bullseye) | `11` | yes | no — mirror dropped bullseye |
| **Debian 12 (bookworm)** | **`12`** | **yes (major 17 → ~38 pkgs)** | **yes** |
| Debian 13 (trixie) | `13` | **no (empty, 0 pkgs)** | no — not published upstream |
| Ubuntu 20.04 (focal) | `20.04` | yes | no — mirror dropped focal |
| Ubuntu 22.04 (jammy) | `22.04` | yes | no — mirror dropped jammy |
| Ubuntu 24.04 (noble) | `24.04` | **no (empty, 0 pkgs)** | no — not published upstream |

So within this mirror's targets (Debian 12/13, Ubuntu 24.04 amd64), **only Debian 12
overlaps** with what OpenProject publishes. Revisit `trixie`/`noble` once OpenProject
adds those suites upstream.

Majors `18`+ also return HTTP 200 but are currently empty stubs; major `16` carries
the older `16.6.0`. This mirror tracks **stable major 17**.

## Architecture

amd64 only, component `main`, and there is **no `binary-all`** — so the `mirror.list`
line uses `[arch=amd64]` (not `,all`), and `scripts/fetch-binary-all.sh` deliberately
skips it (it only matches `[arch=…,all]` lines).

## `deb` line in `config/mirror.list`

```text
deb [arch=amd64] https://packages.openproject.com/srv/deb/opf/openproject/stable/17/debian 12 main
clean https://packages.openproject.com/srv/deb/opf/openproject/stable/17/debian
```

On disk after sync:

```text
/opt/apt/mirror/packages.openproject.com/srv/deb/opf/openproject/stable/17/debian/
```

## Client `URIs=` / `deb` (internal mirror)

Debian 12 (bookworm) only:

```text
deb [arch=amd64 signed-by=/etc/apt/keyrings/openproject.gpg] \
  https://apt.example.com/packages.openproject.com/srv/deb/opf/openproject/stable/17/debian 12 main
```

Note the suite stays `12` even though the host is *bookworm* — that is the upstream
suite name. A one-line `deb` entry is used (rather than `deb822`) because the mirror
has no `binary-all` and `deb822 Architectures` is ignored on some apt builds — same
reasoning as Zabbix.

**GPG:** `/etc/apt/keyrings/openproject.gpg` (dearmored from `gpg-key.asc`) — see `docs/GPG_KEYS.md`.

## Setup

- **Server:** `config/mirror.list` already includes the OpenProject `deb`/`clean` lines;
  `scripts/populate-mirror-keys.sh` fetches and dearmors `openproject.gpg` into `/opt/apt/keys/`.
- **Client:** `sudo ./scripts/setup-apt-client.sh --with-openproject` (Debian bookworm only;
  errors out on other suites/distros). Override the major with `--openproject-major V`.
