# Bruno

## `collections/` vs `flows/`

- **`collections/<service>/`** — the reference. One folder per resource area (matching the
  backend's controllers, e.g. `drivers/`, `bank-accounts/`), one request per endpoint. Use this
  to explore or test any single call in isolation.
- **`flows/<service>/<journey-name>/`** — curated. A numbered sequence of requests (`01-...`,
  `02-...`) that walks through one real end-to-end user journey, chaining variables between
  steps via `script:post-response` (e.g. capture `accessToken` from login, reuse it in every
  later request). Open this when you need to see the whole call sequence for a journey, not
  just one endpoint.

Both are Bruno collections in their own right (each has its own `bruno.json` and
`environments/`) — open either one directly in the Bruno app.

## Adding a new flow

1. Create `flows/<service>/<journey-name>/`.
2. Add a `folder.bru` with a short `docs` block describing the journey and any conditional
   steps (see `flows/plutus-api/driver-onboarding/folder.bru` for the pattern).
3. Number requests by call order (`01-`, `02-`, ...) and set the same number in `meta.seq`.
4. Capture anything the next step needs via `script:post-response { bru.setEnvVar(...) }`
   rather than asking someone to copy values by hand.
5. Give input variables (phone numbers, amounts, etc.) names specific enough not to collide
   with another flow sharing the same environment file — e.g. `driverPhone`, not `phone`.

## Adding to the reference collection

Add a folder per resource area under `collections/<service>/` if one doesn't already exist,
then one `.bru` request per endpoint. Mirror the backend's own route grouping so it's easy to
find a given endpoint by its controller name.

## Environments

Each collection (`collections/<service>/` and each `flows/<service>/`) has its own
`environments/staging.bru`. Add `local.bru` alongside it if you need to point at a local
backend — see `.gitignore` for how local-only overrides are kept out of git.

**Watch out:** `bru.setEnvVar(...)` in a `script:post-response` block writes the captured value
directly into the environment `.bru` file on disk — including via the `bru run` CLI, not just
the desktop app. A flow's environment file therefore declares its captured variables
(`accessToken`, `driverId`, ...) as empty placeholders on purpose. **Before committing, check
`git diff` on any `environments/*.bru` you touched** and make sure no real token/ID slipped in
from a local run — don't just trust that it looked empty when you started.
