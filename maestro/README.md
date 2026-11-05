# Maestro E2E tests

## Layout

- `tests/<app-name>/` — runnable test flows, one subfolder per mobile app (e.g. `driver-app`, `fleet-app`). Run these directly with `maestro test`.
- `flows/shared/` — reusable subflows (login, common navigation, permission dialogs) called from test flows via `runFlow: ../../flows/shared/<name>.yaml`. Never run these directly — they're building blocks, not tests.

## Conventions

- One `.yaml` file per scenario, named for what it verifies (e.g. `self-register-new-driver.yaml`), not for the screen.
- Keep app IDs, base URLs, and other environment-specific values in Maestro's `config.yaml` / `--env` flags, not hardcoded in flows.
- If a setup sequence (e.g. "log in as a driver") is used by more than one test flow, move it into `flows/shared/` instead of duplicating it.

## Status

- `tests/fleet-web/`: perseus in a browser (Maestro web mode): login, add truck + create trip, and the new-user blocker page.
- `tests/fleet-app/`: atlas-rn on Android: sign-up + KYC, add truck, create trip. One journey for one user, run in order.
- `tests/driver-app/`: empty.

These run against the hermetic stack through `e2e/run.sh web` / `e2e/run.sh mobile`, which builds the apps and passes the flows their environment variables. See `e2e/README.md`.
