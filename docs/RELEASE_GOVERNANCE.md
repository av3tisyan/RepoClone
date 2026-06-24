# Release lifecycle (governance)

Review **quarterly** (or on upstream announcements):

1. **Add** new Ubuntu LTS / Debian stable when your org adopts them: extend `config/mirror.list`, transfer, add client `.sources`, pilot hosts.
2. **Retire** old suites: remove `deb`/`clean` blocks from `mirror.list`, re-sync, remove client `.sources`, keep a read-only tarball if compliance requires archives.
3. **Zabbix:** plan major upgrades (6.0 → 7.0, …); duplicate mirror lines during migration if needed; update `docs/ZABBIX_REPOS.md` and client snippets.
4. **HashiCorp:** single repo root covers all products (Terraform, Vault, Consul, …); add new suites to `config/mirror.list` as new Debian/Ubuntu codenames are adopted.
5. **Keyrings:** track `debian-archive-keyring` / `ubuntu-keyring` / Zabbix / HashiCorp key updates (`docs/GPG_KEYS.md`).

Document **supported** suites and **last refresh** dates in your internal runbook.
