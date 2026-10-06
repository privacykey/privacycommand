# Project commands

Run `just` or `just help` for this checkout's supported commands. The commands
and targets are declared in [.project/commands.json](../.project/commands.json).
The reviewed runtime is vendored locally; builds never fetch it from another repository.

Use `target` for a component, `platform` for its operating system, `environment`
for the destination, and `channel` for local/CI/TestFlight/release identity.
Variable overrides precede the recipe: `just target=app platform=ios build`.
Archive/export/beta also accept a positional platform for compatibility.

* `info` identifies the actual checkout, dirty files, tags and channel. Its UTC
  build preview does not reserve a build number.
* `doctor` checks local prerequisites; `setup` uses locked dependencies or source
  generation. `clean` removes declared outputs and preserves archives and release evidence.
* `check` runs the documented fast contract, syntax, secret and documentation checks.
  `test` reports its actual target; `suite=contract` runs the command regressions.
  Package/headless tests do not imply native app or UI coverage.
* `build` compiles the native app by default, including embedded targets. Multiple
  platforms share one captured `YYYY.MMDD.HHMM` UTC identity. Select `target=core`
  explicitly for package-only builds. `typecheck` uses the applicable compiler.
* `archive` delegates to the normal signed Xcode archive and verifies identity.
  `just unsigned=true archive` validates without signing; `just plan=true archive`
  previews the commands. Product → Archive retains its existing scheme capture.
* `export ARCHIVE` exports that archive without compilation or a new build number.
  `artifact-verify ARTIFACT` checks metadata and a saved content digest when available.
  Old archives can be inspected/exported, but cannot acquire invented source records.
* `release-plan` previews without credentials; `release-check` validates local
  settings by default. Select `channel=testflight` or `channel=release` to check
  publication eligibility. Local readiness is not proof of Apple server permissions.
* `upload ARCHIVE` requires an explicit publication channel and the original build
  record. `beta` composes a clean TestFlight archive and upload. Upload never rebuilds.
* `version VERSION NOTES_FILE` changes the hand-chosen marketing version and approved
  release notes. It never changes the UTC build number. `release VERSION`, where
  supported, checks source/CI and pushes an annotated tag to trigger the release workflow.
  Triggered is distinct from published.
* `screenshot DEVICE_OR_WINDOW` requires `state=sample` (or another prepared fixture
  state), `width` and `height` in pixels. On macOS pass the app window ID; on iOS/tvOS pass a simulator UUID. The capture
  records the declared state; sample preparation and visual review remain explicit.
* `dev` launches the selected local component. Native simulator launches require a
  device UUID. Existing isolated launchers retain their sample/store options.
* Remote changes require an explicit supported environment. Production publication
  requires clean source, an annotated matching tag and required successful CI.
  Read-only planning, local archives and checks remain available on development branches.

Full source records stay in ignored build sidecars, separate from customer metadata.
Public release artifacts redact repository details. Signing/export/upload preserve
the captured identity. Credentials remain in the configured local/CI stores.

## Supported tasks and scope

- `help` — Find available commands
- `info` — Inspect this checkout and its capabilities
- `doctor` — Check whether this machine is ready
- `setup` — Prepare a fresh checkout
- `clean` — Remove reproducible build outputs
- `check` — Run the normal validation bundle
- `lint` — Check static code and conventions
- `security-check` — Run the declared security checks
- `docs-check` — Validate docs and their visibility
- `test` — Run the default automated tests
- `version` — Change the marketing version deliberately
- `changelog` — Refresh release notes and feeds
- `ci-status` — Read CI for the selected revision
- `ci` — Dispatch a named workflow deliberately
- `build` — Compile the intended product
- `typecheck` — Check types without publishing
- `archive` — Create and verify a native archive
- `artifact-verify` — Inspect a built artifact before shipping
- `export` — Export an existing verified archive
- `archive-export` — Keep a combined local convenience task
- `release-plan` — Preview the release actions
- `release-check` — Validate release eligibility
- `screenshot` — Capture reproducible screenshots
- `dev` — Start an interactive development loop
- `surfaces` — Copy the shared Settings, menu and About code into this app
- `release` — Create and trigger a versioned release
- `release-local` — Keep the combined local release builder

## Defaults and capabilities

Default build target: `app`. Default unit-test target: `core`.

Declared targets: `app`, `tooling`, `core`.

Optional commands are exposed only when an adapter exists. `localize`, where present, is an explicit catalog refresh; `localization-check` leaves catalogs unchanged.


Update `.project/commands.json`, then run `python3 .project/install.py .` to regenerate
the recipes. Refresh the reviewed runtime lock when changing vendored code. CI runs
the same local contract; unsupported targets/tasks fail instead of succeeding silently.
