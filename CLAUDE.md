# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

QA repo for the VAHN platform: Maestro mobile E2E test flows and Bruno API collections/flows. There is no application code here — everything is test/collection definitions (YAML for Maestro, `.bru` for Bruno).

## Commands

**Bruno** (run against a specific service+environment; requires `@usebruno/cli`):
```bash
npx @usebruno/cli run bruno/flows/plutus-api/driver-onboarding --env staging
npx @usebruno/cli run bruno/flows/plutus-api/driver-onboarding/01-send-otp.bru --env staging   # single request
npx @usebruno/cli run bruno/collections/plutus-api --env staging                               # whole reference collection
```

**Maestro** (once flows exist under `maestro/tests/`):
```bash
maestro test maestro/tests/driver-app/<flow>.yaml
```

## Architecture

### Two different things live under `bruno/`, and they're not interchangeable

- **`bruno/collections/<service>/`** — the reference. One folder per resource area, mirroring the backend's own controller/route grouping (e.g. `drivers/`, `bank-accounts/`, `auth/`), one request per endpoint. For testing/exploring a single call.
- **`bruno/flows/<service>/<journey-name>/`** — curated. A numbered sequence of requests (`01-`, `02-`, ...) that walks one real end-to-end user journey end to end, e.g. `flows/plutus-api/driver-onboarding/`. Steps chain state via `script:post-response { bru.setEnvVar(...) }` — later requests reference the earlier ones' captured values (`{{accessToken}}`, `{{driverId}}`, ...) rather than needing values pasted in by hand. This is the layer meant for the frontend team to follow a call sequence, not the single-endpoint reference.

Each of these — every `collections/<service>/` and every `flows/<service>/` — is its own independent Bruno collection with its own `bruno.json` and `environments/`.

### Maestro: `tests/` vs `flows/`

- `maestro/tests/<app-name>/` — runnable test flows, one folder per mobile app. Run these directly.
- `maestro/flows/shared/` — reusable subflows (login, common navigation) invoked from test flows via `runFlow`. Never run these directly; they're building blocks, not tests. Pull a setup sequence out here the moment a second test flow needs it too.

### Bruno environment files are not static — treat them as code that gets mutated at runtime

`bru.setEnvVar(...)` in a `script:post-response` block writes the captured value **directly into the environment `.bru` file on disk**, and this happens via the `bru run` CLI too, not just the desktop app. Every flow's `environments/staging.bru` therefore declares its captured variables (`accessToken`, `driverId`, `driverCode`, ...) as empty placeholders on purpose — filling them in ahead of time would be pointless (they get overwritten) and leaving them filled in after a local run is a real credential-leak risk, since `accessToken` is a live bearer token.

**Before committing any change that touches `environments/*.bru`, diff it and confirm no live token/ID got baked in from a local run.** This has already happened once while building this repo.

### Adding a new flow

1. `bruno/flows/<service>/<journey-name>/`, with a `folder.bru` (`meta { name: ... }` + a `docs` block explaining the journey and any conditional steps — see `driver-onboarding/folder.bru` for the pattern).
2. Number request files and `meta.seq` by call order.
3. Name input variables specifically enough not to collide with another flow sharing the same environment file (`driverPhone`, not `phone`) — all flows for a service share one `environments/staging.bru`.
