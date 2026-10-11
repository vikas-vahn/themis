# End-to-end checks

One command builds the backend from a branch, starts it with a throwaway database and no route
to the internet, and drives the fleet owner's first-day journey through it three ways:

| Suite | Tool | Under test | Covers |
|---|---|---|---|
| `api` | Bruno | plutus-java | sign-up, KYC (PAN + Aadhaar), add truck, create trip |
| `web` | Maestro (web) | perseus + plutus-java | login, add truck, create trip; a new number is sent to the mobile app |
| `mobile` | Maestro (Android) | atlas-rn + plutus-java | sign-up, KYC incl. the DigiLocker WebView, add truck, create trip |

perseus has no sign-up or KYC screens (a new user is told to finish onboarding in the mobile
app), so the web suite starts from an owner onboarded through the API.

```bash
e2e/run.sh doctor            # what can this machine run, and what is missing
e2e/run.sh all               # everything: stack up, api + web + mobile, stack down
e2e/run.sh all api web       # only some suites
```

The same script runs in GitHub Actions (`.github/workflows/e2e.yml`); there is no separate CI
logic to keep in step.

## How it fits together

```
 themis (this repo)                         repos under test
 ───────────────────                        ─────────────────
 e2e/run.sh            orchestrator         plutus-java/e2e/   config overrides, schema + seed SQL,
 e2e/lib/              stack, suites, seed                     verification fixtures
 e2e/stack/            docker-compose       perseus            VITE_API_BASE_URL build override
 e2e/mocks/            stub third parties   atlas-rn/e2e/      env + APK build script
 bruno/flows/plutus-api/fleet-onboarding/
 maestro/tests/fleet-web/  fleet-app/
```

Each repo owns "how to run me for a test"; themis owns the tests and the orchestration.

### The stack

`e2e/stack/docker-compose.yml`, started by `run.sh up`:

- **postgres 16, redis 7, elasticmq (SQS)**: empty at every start, nothing persisted.
- **plutus**: the JAR built from `PLUTUS_DIR`, with a config rendered by deep-merging
  `plutus-java/e2e/config-overrides.yml` over its `config.yml`.
- **mocks**: stand-ins for the few third parties the flows cannot avoid (`e2e/mocks/`).
- **gateway**: publishes the API (`:18080`), admin (`:18081`) and mocks (`:14010`) ports on
  the host's loopback.

Everything except the gateway sits on a Docker network marked `internal`, which has no route
out. This is the safety net: `config.yml` holds real endpoints and credentials for many
vendors, and an integration nobody remembered to switch off cannot reach them. It fails in
milliseconds and is visible in `plutus.log`.

Startup order: schema-pre.sql → start plutus (Hibernate creates the tables) → schema-post.sql →
seed.sql. Why not Flyway, and what each file is for: `plutus-java/e2e/README.md`.

### Third-party stand-ins

| Vendor | What the stand-in does |
|---|---|
| Surepass PAN / RC / bank / licence | Not a mock: plutus-api's own `TestVerificationService`, fed by `plutus-java/e2e/verification-testing.yml`. |
| Surepass DigiLocker (Aadhaar) | `mocks/routes/surepass-digilocker.js`. Serves the consent page the app opens in a WebView; it approves itself and redirects the way DigiLocker does. |
| ULIP (VAHAN vehicle lookup) | `mocks/routes/ulip.js`. Refuses login, so lookups fall through to the fixture path. |
| Everything else (SMS, WhatsApp, push, CRM, fuel cards, payments, S3, email) | Switched off in the overrides. |

A request that reaches the mocks with no matching route is answered `501`, listed at
`GET /_unmatched`, and **fails the run**. That is how a backend change that starts calling
something new gets noticed. The mocks record paths and field names only, never values, because
the backend sends whatever credentials it is configured with.

## Running locally

Requirements, all checked by `run.sh doctor`:

- Docker with Compose (macOS: `brew install colima docker docker-compose && colima start`)
- Node 22+, JDK 21 and Maven (to build plutus-java)
- `web` and `mobile`: [Maestro](https://docs.maestro.dev) and Java 17+
- `mobile`: Android SDK (`ANDROID_HOME`), JDK 17, and an emulator image:
  ```bash
  sdkmanager "platform-tools" "emulator" "platforms;android-36" "build-tools;36.0.0" \
             "system-images;android-34;google_apis;arm64-v8a"      # x86_64 on Intel/Linux
  avdmanager create avd -n themis_e2e -k "system-images;android-34;google_apis;arm64-v8a" -d pixel_6
  ```

Copy `e2e/local.env.example` to `e2e/local.env` if your checkouts are not siblings of themis,
a port is taken, or you want to reuse builds. Each repo must be on a branch that has its E2E
support (`plutus-java/e2e/`, perseus' `VITE_API_BASE_URL`, `atlas-rn/e2e/`).

```bash
e2e/run.sh up                       # ~40 s once the JAR exists
e2e/run.sh api                      # seconds
e2e/run.sh web                      # ~3 min
e2e/run.sh mobile                   # first build 30-50 min, later runs ~4 min
e2e/run.sh down
```

Useful while writing tests:

- `E2E_KEEP_STACK=1 e2e/run.sh all api` leaves the stack up afterwards.
- The database is new on every `up`. Within one stack, a fixture identity can onboard once
  (a PAN links to one Torg), so re-running a UI suite needs another identity:
  `E2E_WEB_IDENTITY=2 e2e/run.sh web`, `E2E_MOBILE_IDENTITY=2 e2e/run.sh mobile` (1-5).
- `E2E_EMULATOR_ARGS="-gpu host" e2e/run.sh mobile` shows the emulator window.
- `node e2e/lib/seed.mjs onboard --suite X --index 1` gives you an onboarded owner to poke at;
  log in to either app with the printed phone number and OTP `667766`.

### Results

Everything from a run is under `e2e/.run/` (gitignored):

```
results.tsv                    suite, pass|fail|skip
api/<flow>.html, .junit.xml    Bruno reports
web/junit.xml, web/debug/      Maestro report; screenshot + UI hierarchy of each failed step
mobile/<flow>/…, logcat.txt    same per flow, plus the device log
logs/plutus.log, mocks.log …   container logs, collected at `down`
logs/mocks-unmatched.json      third-party calls with no stand-in
```

The rendered backend config is deleted at `down`: it contains values from plutus-java's
`config.yml`. Do not copy it out of the run directory.

## Adding tests

**API flow.** A new folder under `bruno/flows/plutus-api/`, then add its name to the loop in
`suite_api` (`e2e/lib/suites.sh`). Follow `fleet-onboarding/`: chain state with `bru.setVar`
(in memory) rather than `bru.setEnvVar` (which writes tokens into the environment file), and
assert on `success`/`statusCode` in the response body, because plutus answers HTTP 200 for
400 and 422.

**Web flow.** A new `.yaml` in `maestro/tests/fleet-web/`; every file there runs. Start with
`runFlow: ../../flows/shared/fleet-web/login.yaml`. What bit us while writing the first ones:

- Elements below the fold are not tappable. Use `scrollUntilVisible` first.
- The custom dropdowns open when their placeholder text is tapped, not their `id`.
- A check like "the registration number is visible" also matches the form field you just
  typed it into. Assert something that only exists on the screen you expect to be on.
- Lists do not refresh while verification runs in the background; reload until the row shows.
- Flows share one browser. `login.yaml` clears state so each starts logged out.

**Mobile flow.** The flows in `maestro/tests/fleet-app/` are one journey for one user and run
in the order listed in `suite_mobile`. Add a step to an existing file, or a new file to that
list. Selectors are visible text, since the app has no `testID`s yet.

**Starting state.** If a flow needs an owner who already has something (KYC done, a customer
with addresses), add a command to `e2e/lib/seed.mjs` instead of clicking through it. It uses
the same public API the apps do.

**More fixtures.** `plutus-java/e2e/gen-fixtures.py`.

## GitHub Actions

`.github/workflows/e2e.yml` is a reusable workflow with four jobs: build the backend JAR once,
then `api`, `web` and `mobile` in parallel, each on its own stack.

| Trigger | Refs | Suites |
|---|---|---|
| Pull request in plutus-java (to `develop`) | that PR + perseus `main` | api, web |
| Pull request in perseus (to `main`, `dev`) | that PR + plutus `develop` | web |
| Pull request in atlas-rn (to `main`) | that PR + plutus `develop` | mobile |
| Pull request in themis touching tests or runner | integration branches | all |
| Nightly, 02:30 IST | integration branches | all |
| Manual (Actions → E2E → Run workflow) | any refs you type | any |

The manual trigger is how to test a change that spans repos: give it the matching branch of
each.

### One-time setup

1. **Move themis into the organisation as a private repository** (`Vahn-Engineering/themis`,
   the name the workflows use) before attaching any self-hosted runner. On a public repo, a
   pull request from a fork can run code on your machines.
2. themis → Settings → Actions → General → Access: allow workflows in other repositories of the
   organisation to use this one. Without it the callers in the app repos cannot reach it.
3. **`E2E_REPO_TOKEN`** as an organisation secret available to the four repos: a fine-grained
   token (or GitHub App) with read-only *Contents* on plutus-java, perseus, atlas-rn and themis.
4. Merge the `e2e` branches: plutus-java (`e2e/`, workflow), perseus (config override, workflow),
   atlas-rn (`e2e/`, OTA switch, workflow), themis.
5. Choose where jobs run, as repository or organisation **variables** (JSON values):

   | Variable | Unset means | For the Oracle arm64 VMs |
   |---|---|---|
   | `E2E_RUNNER_BACKEND` | `"ubuntu-latest"` | `["self-hosted","linux","arm64","e2e"]` |
   | `E2E_RUNNER_WEB` | `"ubuntu-latest"` | `["self-hosted","linux","arm64","e2e"]` |
   | `E2E_RUNNER_MOBILE` | `"ubuntu-latest"` | leave unset, or a Mac: `["self-hosted","macOS","e2e-mobile"]` |

The checks are not marked required. Let them run for a couple of weeks, fix what flakes, then
make `E2E / API (Bruno)` required first.

### Where each suite can run

| | Oracle Ampere A1 (arm64, no KVM) | GitHub-hosted `ubuntu-latest` | Mac (Apple Silicon) |
|---|---|---|---|
| Build backend, `api` | yes | yes | yes |
| `web` | yes, through a container (below) | yes | yes |
| `mobile` | **no** | yes, on paper (below) | yes |

**Web on arm64 Linux.** Maestro fetches its own Chromium through Selenium Manager, which has
no arm64 Linux build ("Linux ARM is not supported by Selenium Manager"). `run.sh web` detects
this and runs Maestro from `e2e/ci/maestro-web.Dockerfile` instead: Debian's Chromium and
chromedriver, selected with `SE_CHROMEDRIVER` / `SE_BROWSER_PATH`, on the host network. The
runner needs nothing beyond Docker. Verified in an arm64 Linux VM (3/3 flows); not yet run on
an actual Oracle instance. Force it anywhere with `E2E_MAESTRO_WEB_DOCKER=1`, or off with `=0`.
So for the VMs: `E2E_RUNNER_WEB = ["self-hosted","linux","arm64","e2e"]`.

**Mobile.** An Android emulator needs hardware virtualisation, and the A1 shapes do not expose
KVM; the Android build tools are also not published for arm64 Linux. Until the Mac mini
arrives there are two options, switched by `E2E_RUNNER_MOBILE` alone:

- *GitHub-hosted x86 runner (the default).* The job enables KVM and boots an emulator with
  `reactivecircus/android-emulator-runner`; `run.sh` uses the device it finds. This path has
  **not been exercised yet** (it cannot be run outside GitHub): expect to tune it on the first
  runs. Known cost: the first build compiles every native module (30-50 minutes on a laptop),
  after which the cache step restores `node_modules` and Gradle's caches. Private-repo minutes
  are billed, which is why pull requests in plutus-java do not run this suite.
- *A Mac as a self-hosted runner* (labels `self-hosted, macOS, e2e-mobile`). This is the setup
  the suite was developed and verified on. The Mac needs the tools under "Running locally" and
  the `themis_e2e` emulator image; `run.sh` boots and stops the emulator itself.

The same variable later points at the Mac mini, which can also take an iOS job.

### Preparing an Oracle arm64 VM as a runner

`e2e/ci/setup-runner-linux.sh` installs what the backend and API jobs need (Docker, JDK 21,
Maven, Node 22) on Ubuntu 22.04/24.04 or Oracle Linux 9. Then register the GitHub runner with the labels
`e2e` (the script prints the steps). Sizing: the stack peaks around 3 GB of memory; 2 OCPU /
8 GB per runner is comfortable. Run **one runner per VM**, or give each runner its own ports
(`E2E_API_PORT`, `E2E_ADMIN_PORT`, `E2E_MOCKS_PORT`, `E2E_WEB_PORT` in the runner's
environment); the Compose project name is already unique per run.

## What is deliberately not covered yet

- **iOS.** Needs a Mac with full Xcode. The flows are written against text that is the same on
  both platforms, so they should carry over when the Mac mini arrives.
- **Trip distance and cost estimates.** The route lookup (Google Routes) is not stubbed, so
  trips are created without a distance. The flows assert the trip, not its estimate.
- **Adding an address through the map**, in either app: it depends on Google Maps tiles and
  on the backend's place search. Customers get their addresses through the API instead.
- **Money movement** (wallet, payouts, fuel cards, FASTag): every provider is off.
- **Staging.** These checks say the code works against a clean backend. They do not say staging
  is healthy; the existing Bruno flows with `--env staging` are still the tool for that.
