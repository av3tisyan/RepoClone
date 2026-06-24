# Removing old / unneeded packages (Debian/Ubuntu)

This is about **hosts** (mirror server, clients), not about deleting arbitrary packages from the **upstream mirror** (that is controlled by `mirror.list` and upstream archives).

## Packages “no longer required” (orphaned dependencies)

After upgrades, APT may report packages that were pulled in automatically and are unused:

```bash
sudo apt autoremove
```

Review the list, then confirm. To also remove **configuration files** for removed packages:

```bash
sudo apt autoremove --purge
```

## Old kernel packages (common on servers)

After a kernel upgrade, **one or two previous `linux-image-*` packages** are often safe to remove once the new kernel has been rebooted and tested. APT shows them under `autoremove` in many cases.

**Before removing kernels:** reboot into the new kernel and verify the system works.

```bash
uname -r
dpkg -l 'linux-image-*'
sudo apt autoremove --purge
```

Do **not** remove the kernel you are **currently running** unless you know what you are doing.

## Download cache only (free `/var/cache/apt/archives`)

Does not remove installed software:

```bash
sudo apt clean
# or keep some recent debs:
sudo apt autoclean
```

## Optional: find obsolete / orphaned packages (advanced)

Tools (install if needed):

```bash
sudo apt install deborphan
deborphan
```

Review output before purging; false positives are possible.

## Mirror server: shrinking what you **mirror**

If the goal is to stop carrying **old** Debian/Ubuntu **releases** in **`/opt/apt`**, edit **`/etc/apt/mirror.list`**, remove the corresponding **`deb`** and **`clean`** blocks, then run a normal **apt-mirror** cycle (and rely on **`clean`** to drop stale pool files over time — see `man apt-mirror`). That is separate from “deprecated” packages on a single machine.

## Removing the entire mirror tree (`/opt/apt`)

This **deletes all mirrored packages**, keys under **`/opt/apt/keys`**, and apt-mirror state. **Irreversible** unless you have a backup.

**Preferred:** use **`scripts/remove-apt-mirror-config.sh --yes --purge-opt-apt`** (see **`docs/RESET.md`**) to stop services, remove configs, and delete **`/opt/apt`** in one step.

**Manual:**

1. **Stop** apt-mirror and the timer (so nothing holds files open):

   ```bash
   sudo systemctl stop apt-mirror.service
   sudo systemctl stop apt-mirror.timer
   ```

2. **Confirm** nothing is still running: `pgrep -af apt-mirror` (should be empty).

3. **Remove** the directory:

   ```bash
   sudo rm -rf /opt/apt
   ```

4. **Optional — full reset of configuration** on this host:

   - `sudo rm -f /etc/apt/mirror.list`
   - `sudo rm -f /etc/systemd/system/apt-mirror.service /etc/systemd/system/apt-mirror.timer && sudo systemctl daemon-reload`
   - `sudo rm -f /etc/logrotate.d/apt-mirror`

5. **Recreate** empty dirs when you set up again: `sudo mkdir -p /opt/apt/mirror /opt/apt/skel /opt/apt/var /opt/apt/keys` (or run **`scripts/setup-apt-mirror-server.sh`** again).

On the **airgap** nginx host, **`rm -rf /opt/apt`** removes served content; re-**rsync** from the sync host before clients can **`apt update`** again.
