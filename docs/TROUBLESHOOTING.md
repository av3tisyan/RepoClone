# Troubleshooting

## Client: Zabbix `NO_PUBKEY D913219AB5333005` / repository is not signed

Zabbix’s download (`zabbix-official-repo.key`) is **ASCII-armored**. **`Signed-By=`** in deb822 sources must point at a **dearmored** keyring (binary `.gpg`), not the raw `.key` file.

**On the client (quick fix):**

```bash
sudo install -d -m0755 /etc/apt/keyrings
sudo curl -fsSL https://apt.example.com/keys/zabbix.gpg -o /tmp/zabbix.key
sudo gpg --dearmor -o /etc/apt/keyrings/zabbix.gpg /tmp/zabbix.key
sudo chmod 0644 /etc/apt/keyrings/zabbix.gpg
sudo rm -f /tmp/zabbix.key
sudo apt update
```

If the mirror still serves an old armored file, use the upstream key once (connected host only):

```bash
curl -fsSL https://repo.zabbix.com/zabbix-official-repo.key | sudo gpg --dearmor -o /etc/apt/keyrings/zabbix.gpg
```

**On the mirror host:** re-run **`scripts/populate-mirror-keys.sh`** (current script dearmors before publishing), rsync **`/opt/apt/keys/`** to the airgap server, then refresh clients.

Confirm **`/etc/apt/sources.list.d/example-zabbix.list`** uses **`signed-by=/etc/apt/keyrings/zabbix.gpg`** (dearmored key).

## Client: Zabbix `404` on `binary-all/Packages`

apt may request **`.../dists/noble/main/binary-all/Packages`**. The internal mirror only has **`binary-amd64`** (same as upstream Zabbix and **`defaultarch amd64`** in **`config/mirror.list`**).

Use a **one-line** source with **`[arch=amd64 signed-by=...]`** (Zabbix’s usual format). **`setup-apt-client.sh`** writes **`/etc/apt/sources.list.d/example-zabbix.list`** — not a deb822 **`.sources`** file.

**On the client (noble example):**

```bash
sudo rm -f /etc/apt/sources.list.d/example-zabbix.sources
sudo tee /etc/apt/sources.list.d/example-zabbix.list <<'EOF'
# example internal mirror — Zabbix 7.4 (Ubuntu noble)
deb [arch=amd64 signed-by=/etc/apt/keyrings/zabbix.gpg] https://apt.example.com/repo.zabbix.com/zabbix/7.4/stable/ubuntu noble main
EOF
sudo apt update
```

Or re-run **`setup-apt-client.sh --with-zabbix`** (current script uses **`.list`**).

Deb822 **`Architectures: amd64`** alone is **not** honored on some apt versions; prefer **`[arch=amd64]`** in the **`deb`** line.

## Sync host: Zabbix 7.4 `can't open index .../binary-amd64/Packages`

Zabbix **7.4 `/release/`** repos publish **`binary-all`** only (no **`binary-amd64`**). apt-mirror with **`set defaultarch amd64`** always requests **`binary-amd64`**, so you see errors like:

`can't open index repo.zabbix.com/zabbix/7.4/release/ubuntu//dists/noble/main/binary-amd64/Packages`

**Fix:** mirror and use **`/stable/`** instead of **`/release/`** (see **`docs/ZABBIX_REPOS.md`**). Update **`/etc/apt/mirror.list`** from the repo’s **`config/mirror.list`**, run **`apt-mirror`** again, and point clients at:

`https://<mirror>/repo.zabbix.com/zabbix/7.4/stable/ubuntu`

After changing paths, remove stale trees if present:

```bash
sudo rm -rf /opt/apt/mirror/repo.zabbix.com/zabbix/7.4/release
```

## Sync host: `clean.sh` — `Syntax error: Unterminated quoted string`

apt-mirror builds **`/opt/apt/var/clean.sh`** with one **`rm -f '…'`** line per stale file. If any mirrored **`.deb` path contains a single quote** (`'`), the generated script is invalid shell and fails partway through (for example at line 5774).

**Check:**

```bash
sh -n /opt/apt/var/clean.sh
```

**Safe cleanup (recommended):**

```bash
sudo /opt/apt/var/run-mirror-clean.sh
# or from the repo:
sudo ./scripts/run-mirror-clean.sh
```

This validates **`clean.sh`** first; if syntax is broken, it deletes paths via a **Perl parser** instead of executing the broken script.

**Deploy the wrapper** (if missing):

```bash
sudo install -m0755 scripts/run-mirror-clean.sh /opt/apt/var/run-mirror-clean.sh
sudo install -m0755 config/postmirror.sh /opt/apt/var/postmirror.sh
```

Future syncs can run cleanup automatically from **`postmirror.sh`** when both files are installed.

**Manual inspect** of a bad line:

```bash
grep -n "^rm -f " /opt/apt/var/clean.sh | tail -5
sed -n '5770,5780p' /opt/apt/var/clean.sh
```

**Missing `postmirror.sh`:** install **`config/postmirror.sh`** to **`/opt/apt/var/postmirror.sh`** (`chmod +x`) — see **`scripts/setup-apt-mirror-server.sh`**.

## Sync host: Zabbix (or HashiCorp) `arch:all` packages re-download every sync

**Symptom:** every `apt-mirror` run re-fetches the same Zabbix/HashiCorp packages (e.g. `zabbix-sql-scripts_*_all.deb`, web/frontend confs) even though nothing changed upstream — the sync is never incremental for those.

**Cause:** these are **`arch:all`** packages. apt-mirror with **`set defaultarch amd64`** never tracks `binary-all/`, so the **`clean.sh`** it generates lists every arch:all `.deb` as an orphan and deletes it each run. `fetch-binary-all.sh` (in `postmirror.sh`) then re-downloads them — a delete→fetch churn every cycle.

**Fix (two parts — deploy BOTH):**

1. **`run-mirror-clean.sh`** builds a keep-list from each `binary-all/Packages` index and excludes those paths (and the index files) from deletion, so the arch:all packages are not deleted.
2. **`fetch-binary-all.sh`** skips files already present with the **expected `Size:`** (and verifies `Size`/`SHA256` on anything it does download), so a steady-state run fetches nothing new and is self-healing for truncated/corrupt files.

```bash
sudo install -m0755 scripts/run-mirror-clean.sh   /opt/apt/var/run-mirror-clean.sh
sudo install -m0755 scripts/fetch-binary-all.sh   /opt/apt/var/fetch-binary-all.sh
# (or just re-run: sudo ./scripts/setup-apt-mirror-server.sh --role sync)
```

After one more full sync to settle, each subsequent run should log:

- clean: `Removing N stale mirror files (protected M arch:all/binary-all paths)`
- fetch: `repo.zabbix.com noble/main: 12 present, 0 fetched`  ← **0 fetched = incremental**

If you still see `fetched` climbing every run, the deployed `/opt/apt/var/run-mirror-clean.sh` is the **old** version (still deleting them) — re-copy it as above. `run-mirror-clean.sh` needs `perl` (already used for safe clean parsing); size/SHA256 verification needs `sha256sum`/`stat` (coreutils, present on Debian).

**Check what apt-mirror itself re-downloads (amd64):** apt-mirror is incremental for `binary-amd64` packages already on disk; if those also re-download every run, confirm `clean.sh` isn't deleting them (it shouldn't — they're referenced in `binary-amd64/Packages`) and that the suite/path didn't change in `mirror.list`.

## Sync host: `apt-mirror.service` inactive (dead) after timer run

Normal for **`Type=oneshot`**: **`status=0/SUCCESS`** means the last sync finished. Enable **`apt-mirror.timer`**, not continuous **`active (running)`** on the service:

```bash
systemctl is-enabled apt-mirror.timer
systemctl list-timers apt-mirror.timer
```

## Client: `404` on `/keys/…` or `…/dists/trixie/Release`

- **Keys:** On the mirror host, run **`scripts/populate-mirror-keys.sh`** so **`/opt/apt/keys/`** exists and nginx serves **`/keys/`** (see **`docs/MIRROR_HOST_KEYS.md`**). Clients can temporarily use **`/usr/share/keyrings/`** if **`setup-apt-client.sh`** falls back (it prints a **WARN**).
- **Wrong path:** Client **`URIs`** must include the upstream host segment, e.g. **`https://<mirror>/deb.debian.org/debian`**, not **`https://<mirror>/debian`** — that matches apt-mirror’s on-disk layout under **`/opt/apt/mirror/`**.
- **Suite not synced yet:** Run **`scripts/check-mirror-health.sh`** from a machine that can reach the mirror; wait for **`apt-mirror`** to finish if **`InRelease`** checks fail.

## `apt update` / `sqv` / SHA1 (third-party repos, Trixie 2026+)

If verification fails with **SHA1 is not considered secure since 2026-02-01**, re-run **`setup-apt-client.sh --use-gpg-not-sqv`** or ask the vendor to re-sign keys. Removing the offending **`.sources`** line is also valid if you do not need that repository.

## `apt-mirror is already running, exiting`

### First check: is `apt-mirror.service` already running?

If **`systemctl status apt-mirror.service`** shows **active (running)** or **activating** and **`TriggeredBy: apt-mirror.timer`**, the **timer** already started a sync. A second **`sudo apt-mirror`** will always exit with “already running” — **that is expected**. Wait for the job to finish (first full sync can take **many hours**), or watch progress:

```bash
sudo journalctl -u apt-mirror.service -f
```

Use **`sudo journalctl`** (or add your user to group **`adm`**) so you see service logs; without that, **`journalctl`** may show no lines.

Only follow the **stale lock** steps below if **no** `apt-mirror` process is running and you still get the error.

### Long gap in log after `cnf` / `Processing DEP-11`

After **`Downloading ... cnf files`** finishes, apt-mirror may print nothing for **several minutes** while it runs **`Processing indexes:`** (CPU-heavy). That is normal. The next lines are usually **`GiB will be downloaded`** and many **`wget`** processes. Watch:

```bash
pgrep -af apt-mirror
sudo du -sh /opt/apt/mirror 2>/dev/null
```

If **`apt-mirror`** is gone and the journal shows an error, open the full log: **`sudo journalctl -u apt-mirror.service -e --no-pager`**.

---

## Stale lock (no process, but apt-mirror still refuses)

apt-mirror creates a lock file under **`var_path`** from `/etc/apt/mirror.list` (this repo uses **`/opt/apt/var`**), typically:

**`/opt/apt/var/apt-mirror.lock`**

### 1. See if a run is actually active

```bash
systemctl status apt-mirror.service
pgrep -af apt-mirror
ps aux | grep -E '[a]pt-mirror|[w]get.*archive'
```

If the **timer** started a sync, wait for it to finish, or inspect logs:

```bash
sudo journalctl -u apt-mirror.service -e
```

### 2. If nothing is running — stale lock

Only remove the lock after you are sure **no** `apt-mirror` / mirror `wget` processes remain:

```bash
sudo rm -f /opt/apt/var/apt-mirror.lock
sudo apt-mirror
```

A stale lock often appears after **Ctrl+C**, **kill**, **reboot during sync**, or **OOM**.

### 3. Avoid overlapping runs

Do not start **`sudo apt-mirror`** manually while **`apt-mirror.timer`** might fire. Options:

- Temporarily: `sudo systemctl stop apt-mirror.timer` before a manual run, then `sudo systemctl start apt-mirror.timer` after.
- Or rely on the timer only and skip manual runs.

---

## “GiB will be downloaded into archive” looks huge

After index processing, apt-mirror prints an estimate, e.g. **`1464.4 GiB will be downloaded`**. That is a **planning figure** for the current `mirror.list` (all suites/components). It can approach **~1.5 TB** for Debian + Ubuntu + security + Zabbix with **amd64** only — still within a **2 TB** disk **if** you reserved **~300–400 GB** for OS, logs, and `keys/`.

If the estimate is **too large** for your disk:

- Remove a **Debian** or **Ubuntu** **release** you do not need from **`/etc/apt/mirror.list`** (and matching **`clean`** lines).
- Drop **`multiverse`** on Ubuntu lines if you add it later.
- Ensure you are **not** mirroring **`i386`** / **sources** (this repo’s `mirror.list` uses **`defaultarch amd64`** only).

Then remove the stale lock **only if no process is running**, edit **`mirror.list`**, and run **`apt-mirror`** again (or wait for the next timer tick after **`systemctl restart apt-mirror.timer`** — prefer editing before the first huge download completes).
