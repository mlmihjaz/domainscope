# 🔍 DomainScope — Bulk Domain Availability Checker

Check thousands of domains at once, with results you can trust. Every domain is
**dual-verified** against live DNS delegation **and** the registry's RDAP record —
so a registered domain is **never** reported as available.

![status](https://img.shields.io/badge/runs-100%25%20in%20browser-10b981) ![deps](https://img.shields.io/badge/dependencies-none-34d399)

## ✨ Features

- **Bulk input** — paste thousands of domains; newlines, commas, spaces, `https://`, and `www.` are all handled, duplicates removed.
- **Dual verification** — DNS-over-HTTPS (NS delegation) + per-TLD RDAP from the IANA bootstrap.
- **Honest verdicts** — `AVAILABLE`, `TAKEN`, `LIKELY FREE`, `UNKNOWN`. A registered domain is never shown as available.
- **No server, no tracking** — single HTML file, runs entirely in the browser.
- **Export** — filter by status, copy the available list, or download a CSV.

## 🚦 Verdicts

| Status | Meaning | How it's proven |
|--------|---------|-----------------|
| 🟢 **AVAILABLE** | Free | RDAP 404 **and** no DNS delegation |
| 🔴 **TAKEN** | Registered | NS-delegated **or** RDAP says registered |
| 🟡 **LIKELY FREE** | Probably free | TLD has no RDAP server, but domain isn't in DNS (strong, unproven) |
| ⚪ **UNKNOWN** | Inconclusive | Couldn't confirm |

## 🚀 Use it

Just open `index.html` in any modern browser (Chrome, Edge, Firefox) — or host it
anywhere static (GitHub Pages, Netlify, your own site).

## 🖥️ CLI version (PowerShell)

`domain-check.ps1` runs the same dual-check logic from a terminal:

```powershell
.\domain-check.ps1 -InputFile .\list.txt      # from a file
.\domain-check.ps1 -Domains foo.com,bar.net   # inline
.\domain-check.ps1 -Clipboard                 # from clipboard
```

Results print as a table and export to `results.csv`.

## ⚙️ How it works

1. **DNS NS lookup** via `dns.google` (DNS-over-HTTPS). Delegation = registered; `NXDOMAIN` = not delegated.
2. **RDAP lookup** against the TLD's registry, resolved from the IANA RDAP bootstrap. `200` = registered, `404` = free.
3. The two signals are combined so an "available" result requires agreement from both — eliminating false positives on TLDs that lack an RDAP server (e.g. `.io`).

---

Powered by [Google DNS-over-HTTPS](https://developers.google.com/speed/public-dns/docs/doh) & the [IANA RDAP bootstrap](https://data.iana.org/rdap/dns.json).
