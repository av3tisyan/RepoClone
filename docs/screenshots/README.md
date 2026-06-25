# Screenshots

These images power the project `README.md`. Capture them from the dashboard's **demo mode**,
which renders **public-safe mock data** (generic `example.com` hosts, sample repos, fake users)
with no backend and no real hostnames — so the same shots are safe for the public repo.

## How to capture

1. Open the dashboard in **demo mode** (`?demo=1` — no daemon/data needed):
   - Locally: `python3 scripts/mirror-manager/mirror_manager.py` → `http://127.0.0.1:8080/?demo=1`
   - Or on a deployed host via SSH tunnel: `http://localhost:8080/?demo=1`
2. Use the sidebar to visit each view and screenshot it.
3. Save PNGs here with the exact names the README references:

   | File | View |
   |------|------|
   | `overview.png` | Overview (KPIs, storage donut, "where the space goes", budget estimation, activity) |
   | `repositories.png` | Repositories (sortable table + size mini-bars, integrity check) |
   | `catalog.png` | Catalog (one-click recommended repos by category) |
   | `add.png` | Add repository (paste-URL discover, presets, custom) |
   | `sync.png` | Sync (run status, daily timer, live apt-mirror log) |
   | `sources.png` | Client sources (pick repos → generated `sources.list` + install script) |
   | `server.png` | Server (mirror.list & setup, DR backup, landing/bootstrap publish) |
   | `access.png` | Access (local users + LDAP/LDAPS config + required-group members) |

   In demo mode the **Client sources** and **Server** views auto-populate on load (they
   call *Generate* / *Load* for you), so a plain screenshot of `…/?demo=1#sources` and
   `…/?demo=1#server` shows fully-rendered content.

Captured at **1600×900 (16:9)** @2× via headless Chrome:
`"…/Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1600,900 --screenshot=overview.png "http://127.0.0.1:8080/?demo=1#overview"`

4. Optional: capture both **dark** and **light** (theme toggle, top-right) — e.g. `overview-light.png`.

**Tips:** ~1280 px window, browser zoom 100%, hide the bookmarks bar. The donut/bars animate on
load, so wait a beat before capturing.
