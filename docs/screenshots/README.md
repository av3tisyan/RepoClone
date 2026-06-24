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
   | `add.png` | Add repository (paste-URL discover, presets, custom) |
   | `sources.png` | Client sources (per-OS picker + one-liner) |

4. Optional: capture both **dark** and **light** (theme toggle, top-right) — e.g. `overview-light.png`.

**Tips:** ~1280 px window, browser zoom 100%, hide the bookmarks bar. The donut/bars animate on
load, so wait a beat before capturing.
