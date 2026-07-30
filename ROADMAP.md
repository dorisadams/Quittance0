# Quittance — Ship Roadmap

Canonical plan: **[PLAN.md](./PLAN.md)** (ürün, mimari, DoD, fazlar, commitler).

This file is the short execution checklist. Do not diverge from PLAN.md decisions.

## Locked (see PLAN.md §4)

- Freighter = identity (create + pay)
- Email = optional send (mailto now); never a login gate
- Google not required for create/pay
- MVP in-memory + Horizon verify for demo
- Postgres / SMTP / Gmail API = after online demo

## Commit order

```
A1 favicon/footer
A2 invoice/proof copy
A3 wallet-only create/pay
A4 optional email + mailto send
A5 customer fields = client data
B1 dashboard scoped to wallet
B2 Horizon verify on MVP
B3 remove simulate + broken sync UI
B4 seller/payer metadata in memory
B5 invoice detail + AssetLogo fixes
C1 Download Proof primary CTA
C2 README align
D1–D3 deploy configs + evidence docs
D4–D5 deploy + testnet pack
```

Ask before each git commit. One commit = one PLAN.md row.

## Phase E — v0.2 (in progress)

| # | Task | Status |
|---|------|:------:|
| 1 | Postgres + dynamic `sellerPublicKey` (align full server) | ✅ |
| 2 | Per-seller payment monitor | 🔲 |
| 3 | SMTP / Gmail API — Resend transactional email | 🔄 backend done, frontend wiring pending |
| 4 | Server-side PDF | 🔲 |
| 5 | CI (lint + typecheck + test on every PR) | ✅ |
| 6 | Remove unused Redis/Bull | ✅ |
| 7 | Tech-debt docs + deferred followups | 🔄 |
