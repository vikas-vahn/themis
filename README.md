# Themis

QA/testing repo for the VAHN platform: Maestro end-to-end mobile tests, and Bruno API collections/flows.

## Structure

```
themis/
├── maestro/          # mobile E2E tests (see maestro/README.md)
│   ├── flows/        # reusable subflows (login, navigation, ...) — called via runFlow, never run directly
│   └── tests/        # runnable test flows, one folder per app
└── bruno/            # API testing (see bruno/README.md)
    ├── collections/  # full API reference — one Bruno collection per backend service
    └── flows/        # curated, ordered request sequences for a real user journey
```

## Why two things live under `bruno/`

- **`collections/`** is the reference: every endpoint a service exposes, organized by resource, for exploring/testing any single call.
- **`flows/`** is curated: a numbered sequence of requests that walks through one real end-to-end journey (e.g. driver onboarding), chaining variables between steps (OTP → token → register → ...). This is what the frontend team should open when they need to see "what does the whole onboarding call sequence look like."

## Adding to this repo

- New backend service? Add a folder under `bruno/collections/<service-name>/` and, if it has a notable end-to-end journey, a matching one under `bruno/flows/<service-name>/<journey-name>/`.
- New mobile app? Add a folder under `maestro/tests/<app-name>/`. Pull anything reused across flows (login, common setup) into `maestro/flows/shared/` first.
