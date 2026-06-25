# Security model & hardening

This kit was security-reviewed (web dashboard, scripts, systemd/sudoers, nginx, GPG/airgap
supply chain). This document records the trust model, what's enforced, and the residual
operator-facing recommendations.

## Trust model (the important guarantees)

- **Package authenticity is end-to-end.** `apt-mirror` copies upstream `InRelease`/`Release`
  **unchanged**; the mirror never re-signs. Clients pin per-vendor keyrings with `Signed-By=`
  and verify signatures + hashes themselves. A compromised mirror **cannot forge a package** —
  apt rejects the hash mismatch against the signed `Release`. There is no `[trusted=yes]` /
  `allow-insecure` anywhere.
- **Dashboard runs non-root.** `mirror-manager` runs as the dedicated `apt-manager` user with a
  **narrow sudoers grant** (only `systemctl start/enable/disable apt-mirror.{service,timer}`).
  It owns only `/opt/apt/{manager,keys,www}`; `/opt/apt/var` (root-run scripts) and
  `/opt/apt/mirror` stay root-owned. `--user root` exists but is **not recommended** for any
  networked deployment.
- **Built-in authentication.** App-level login: users in SQLite (`/opt/apt/manager/users.db`),
  **PBKDF2-SHA256** password hashes, **signed-cookie sessions** (HMAC) bound to the password
  hash (delete/password-change revokes sessions immediately), rate-limited, login Origin-checked,
  `Secure` cookie behind TLS. Secrets/DB are `0600`, the state dir `0700`.

## Enforced controls

- **SSRF guard** on every server-side fetch (probe/discover/estimate/key): http/https only,
  hosts resolving to private/loopback/link-local/reserved/multicast addresses are refused,
  **redirects are not followed**, responses are byte-capped and gzip decompression is bounded
  (gzip-bomb guard).
- **Path-traversal guards**: snapshot ids and key names are validated/`slug`-ed before use; repo
  on-disk paths are confined to `/opt/apt/mirror` via `realpath` containment.
- **mirror.list injection guard**: custom-repo URL/suite/components/arch are validated (no
  newlines/brackets/spaces) so they can't inject extra apt-mirror directives.
- **Security headers** on all dashboard responses: `Content-Security-Policy` (self + inline only,
  no external origins — airgap-friendly), `X-Content-Type-Options`, `X-Frame-Options: DENY`,
  `Referrer-Policy`. nginx adds **HSTS**; the apt vhost sets `disable_symlinks on`.
- **systemd sandboxing**: the manager unit's `ReadWritePaths` is scoped to the three dirs it owns
  (`ReadOnlyPaths=/opt/apt/var`); `apt-mirror.service` runs with `ProtectSystem=strict`,
  `PrivateTmp`, `NoNewPrivileges`, restricted address families, etc. The `MM_TOKEN` drop-in is
  `0640` (not world-readable).
- **CSRF**: mutating API calls require a custom `X-MM: 1` header (not settable cross-site); the
  login POST is Origin-checked.
- **Mutual-TLS-free egress for keys**: all GPG keys are fetched over `https://` from first-party
  vendor hosts; no `--insecure`.

## Network exposure

The daemon binds `127.0.0.1` by default. Reach it via SSH tunnel, or front it with the nginx
TLS proxy (`deploy/nginx/mirror-manager.conf`). If you bind it to a LAN address, set `MM_ALLOW`
(CIDR allowlist, enforced in-daemon) and keep the port firewalled to the proxy. The dashboard
now authenticates itself, so the proxy needs no auth layer — but keeping the proxy's
`allow/deny` admin-network block on is good defence-in-depth.

## Recommended follow-ups (operator workflow changes — not yet automated)

1. **Signed/checksummed client bootstrap — implemented.** Publishing writes `setup.sh.sha256`
   (served at `/setup.sh.sha256`); the landing page shows a verify-before-run one-liner
   (`curl … setup.sh.sha256 | sha256sum -c && sudo sh setup.sh`). A detached GPG signature
   remains optional for higher assurance.
2. **Full-hash airgap manifests.** `rsync-to-airgap.sh` defaults to `--quick` (size-only). For
   removable-media transfers use full **SHA-256** manifests and **GPG-sign the manifest** so
   tampering is detected before serving (apt's GPG still catches tampered `.deb`s as a backstop).
3. **Third-party key fingerprint verification — implemented.** `populate-mirror-keys.sh`
   prints each key's fingerprint for out-of-band verification and enforces optional
   `EXPECT_<VENDOR>_FPR` pins (mismatch aborts). Set the pins for your vendors.
4. **Enable the proxy admin-network ACL** (`allow/deny` in `mirror-manager.conf`) for your
   admin subnet, and prefer the SSH-tunnel access pattern for the dashboard.
5. **Keep `--user root` out of production.** The whole least-privilege design depends on the
   non-root default.

## Reporting

This is an internal implementation kit; report issues to the maintaining team.
