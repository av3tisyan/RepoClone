# Airgap transfer

## Layout

- **Sync host (connected):** runs `apt-mirror`; data lives under **`/opt/apt`** (`mirror/`, `skel/`, `var/`).
- **Airgap server:** **Debian 13**, same **`/opt/apt`** paths, **nginx** serving **`apt.example.com`** with `root /opt/apt/mirror` (see `deploy/nginx/apt.example.com.conf`).

## Methods

1. **Network (one-way link):** `rsync` from sync host to airgap (see `scripts/rsync-to-airgap.sh`).
2. **Sneaker-net:** `rsync` to removable media on the sync host, then `rsync` from media to airgap `/opt/apt/`.

## Verification

- After transfer, on the airgap server: `du -sh /opt/apt` (stay within your **~1.6–1.7 TB** mirror budget on a **2 TB** disk).
- HTTP(S): on the airgap host, after DNS (or with `curl --resolve`), run `sudo ./scripts/check-mirror-health.sh https://apt.example.com` (see script for `CURL_INSECURE=1` during TLS bring-up).
- Ensure **DNS** for **`apt.example.com`** resolves to the airgap VIP.

## Nginx

- Reload after first full copy: `sudo nginx -t && sudo systemctl reload nginx`
- TLS: terminate HTTPS on nginx with an internal or public certificate; keep `root` identical.
