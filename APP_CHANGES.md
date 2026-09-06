# Minimal app changes

This document is the "minimal changes" ledger the task brief asks for. Everything else in this
repo (Dockerfile, Kubernetes manifests, backup tooling, CI) is new infrastructure; this page
covers the small set of changes made *inside* the vendored app itself, and why each was necessary.

Upstream: https://github.com/MGasiorowskii/CryptoCurrencyExchange, forked at commit
`46fc0e06c613e648dd6b34b103b9e30f5f817d01` (2022-10-02, the last upstream commit).

## Why each change was made

| File | Change | Why |
|---|---|---|
| `Exchange/Exchange/settings.py` | `SECRET_KEY` moved from a hardcoded literal to `os.environ["DJANGO_SECRET_KEY"]` (fails fast if unset) | The hardcoded key (`0U18qVJY2NRwClsEszGV_SBoPKB4-oHP0t3EP418tN4`) is **publicly committed** in upstream's git history. It must be treated as compromised and rotated; it cannot be reused as a default. |
| same | `DEBUG` now parsed as a proper boolean (`"true"/"1"/"yes"/"on"`, case-insensitive) instead of `os.getenv("DEBUG")` | The original code made `DEBUG` truthy for **any non-empty string**, including the literal string `"False"`. Setting `DEBUG=False` in the environment left debug mode **on**. |
| same | `ALLOWED_HOSTS` / `CSRF_TRUSTED_ORIGINS` now read from a comma-separated env var instead of `[]` | With `DEBUG=False` and an empty `ALLOWED_HOSTS`, Django rejects every request with `DisallowedHost`. Required for the app to serve any traffic outside debug mode. |
| same | Added `STATIC_ROOT` + `STATICFILES_STORAGE = "whitenoise.storage.CompressedManifestStaticFilesStorage"`, added `WhiteNoiseMiddleware` | No `STATIC_ROOT` existed, so `collectstatic` had nowhere to write and Gunicorn has no static-file story on its own. WhiteNoise serves the collected assets directly from the app process — see the README for the sidecar/CDN alternative and its trade-offs. **Uses `STATICFILES_STORAGE`, not the `STORAGES` dict** — `STORAGES` was only added in Django 4.2, and this app is pinned to 4.1. |
| `Exchange/Exchange/health.py` (new) + `Exchange/Exchange/urls.py` | Added `/healthz/` (process-only) and `/readyz/` (`SELECT 1`) | No health endpoint existed at all, and the Kubernetes readiness probe needs one. Liveness deliberately does **not** touch the database — if it did, a transient DB blip would restart every pod at once. |
| `Exchange/wallet/migrations/0007_seed_tokens.py` (new) | Data migration seeding `Token` rows for `bitcoin`, `ethereum`, `tether`, `binancecoin`, `solana`, `cardano` (`actual_price=0.0`) | **This is a boot-blocking bug fix, not an optional improvement.** `wallet/signals.py`'s `create_wallet` signal fires on every `User` `post_save(created=True)` and does `Token.objects.get(name="bitcoin"/"ethereum"/"tether")`. With an empty `Token` table this raises `Token.DoesNotExist` — **`manage.py createsuperuser` on a fresh database crashes**, and so does the registration form. Verified: before this migration, `createsuperuser` fails; after it, it succeeds and the signal auto-creates real bitcoin/ethereum/tether wallet addresses for the new user. |
| `requirements.txt` (new) | Authored and pinned from scratch | Upstream shipped **no** `requirements.txt`/Pipfile/pyproject.toml anywhere in the repo. Built by grepping every import across `Exchange/` and pinning to the newest version compatible with the Django 4.1 ceiling (see below). |

## Why Django is pinned at 4.1.13 (not upgraded)

Full reasoning, CVE list, and risk acceptance are in the deployment repo's `docs/CVE-TRIAGE.md`
([aaronmhmr/crypto-exchange-deploy](https://github.com/aaronmhmr/crypto-exchange-deploy)). Short
version: the brief asks for *minimal changes* to containerize an already-abandoned app; a framework
version bump is app-level work, not infrastructure work, so it's treated as the top item on that
repo's production-readiness roadmap rather than done here. Consequence: several dependencies are held
below their current release because newer releases require Django ≥4.2 or ≥5.2:

| Package | Pinned | Why not newer |
|---|---|---|
| `djangorestframework` | `3.15.1` | `3.15.2`+ requires `Django>=4.2` |
| `django-extensions` | `3.2.3` | `4.x` requires `Django>=4.2` |
| `django-q` | `1.3.9` (abandoned upstream, last release 2021-06-27) | `django-q2>=1.11` requires `Django>=5.2` — the maintained fork isn't installable on 4.1 |
| `psycopg2` (compiled, not `-binary`) | `2.9.10` | Django only gained `psycopg3` support in 4.2 |

## Known upstream limitations — deliberately not fixed (out of scope)

These were found while verifying the app boots, and are **app-level bugs in the original code**,
not infrastructure problems. Fixing app logic is outside "minimal changes to containerize"; each is
recorded here so it's a documented, deliberate limitation rather than a silent gap.

- **`trading/operations/get_core_information.py` hardcodes `EXCHANGE_PK = 13` and `USDT_PK = 3`.**
  Trading operations assume a specific object-creation order (an `Exchange` user must be exactly the
  13th `User` row, the `tether` token exactly the 3rd `Token` row). This is fragile by construction;
  a fresh deployment is unlikely to reproduce it, so trading operations (`buy_now`/`sell_now`) and the
  profile page (which calls `get_core_information()`) should be expected to fail with
  `User.DoesNotExist`/wrong-object errors until this is fixed upstream.
- **The periodic price-fetch tasks are never scheduled.** `wallet/tasks/periodic/tasks.py` defines
  `download_historical_data()`/`daily_data_download()` (calling the public, unauthenticated CoinGecko
  API — no API key involved), but no `django_q.models.Schedule` is ever created anywhere in the
  codebase. The `manage.py qcluster` worker deployed by this repo will run correctly but sit idle
  until a Schedule is created (e.g. via the django-q admin panel).
- **`API_KEY` is documented in upstream's README but read by no code path.** Verified by grepping every
  `.py` file under `Exchange/` for `API_KEY`/`getenv` — it never appears. Kept in `.env.example` for
  parity with upstream's documented interface; it is currently inert.
- **`Token.image` default (`'bitcoin_icon.jpg'`) doesn't match the actual shipped asset**
  (`media/token_logo/bitcoin_icon.png` — different filename, extension, and directory). Cosmetic only
  (a broken `<img>` src on a fresh Token row); not fixed.
