# Changelog

## 0.8.9 — 2026-11-22

- Use software volume for fixed-volume outputs and leave native macOS volume
  in control on supported outputs. Routing works automatically in the background.
- Show the current route or error in the speaker menu and through a status dot.
- Check for stable GitHub releases with compatible installer DMGs manually or
  automatically. Show a yellow dot when an update is available and give routing
  errors priority. Open the release page to install the update manually.
- Exercise update check timing, persistence, release parsing, and status priority
  in automated tests.

## 0.8.8 — 2026-11-18

- Keep volume control enabled when macOS switches to a new physical output,
  including switches during startup. Follow the new default instead of a
  previously pinned destination, with readiness and helper cleanup checks.
- Preserve an explicit Disable when switching outputs in macOS or the app.
  Volume control enables again only with Enable or the next app launch.
- Cover output changes across device notifications, helper messages, and helper
  exit ordering with isolated lifecycle regressions.

## 0.8.7 — 2026-11-14

- Fix recurring boot-time error 60 when macOS service launch/authentication
  outlasts the buffer deadline. Keep each attempt bounded and automatically
  retry temporary pre-readiness failures with fresh helpers and capped backoff,
  retaining the physical output until ready.
- Cancel pending recovery on Disable, Quit, and output changes. Keep explicit
  authentication/busy/format errors and established-session loss terminal.
- Add a deterministic delayed-broker XPC reproduction, app recovery/cancellation
  coverage, and persisted startup diagnostics.

## 0.8.6 — 2026-11-11

- Recover when the HAL driver starts before launchd registers the broker's
  Mach service. Invalid XPC connections are replaced with fresh connections
  using the same broker signature pin; audio memory is retired on failure.
- Add a cold-start integration regression that waits for actual writer
  invalidation before registering the broker, then verifies PCM from the
  same driver process.

## 0.8.5 — 2026-09-24

- Retry startup connection resets (error 54) up to twice with fresh authenticated
  connections under the existing buffer deadline. Explicit access denial and
  competing-reader errors still fail immediately; established session revocation
  remains unchanged.
- Exercise repeated startup disconnects in the isolated XPC integration tests
  and log console-session revocation for diagnosis.

## 0.8.4 — 2026-09-13

- Accept output-scoped nominal sample-rate queries from legacy Core Audio
  clients such as Warcraft III's FMOD 4 engine. Previously these queries
  returned unknown-property despite a valid global 48 kHz rate.
- Add driver regression coverage and an installed legacy API check to
  `audio-route-verify`.
- Installed 0.8.4 passes the legacy query check; the user confirmed Warcraft III
  starts without the reported audio-device error. Audible playback and broader
  game compatibility remain unverified.

## 0.8.3 — 2026-09-12

- Replace the one-way buffer request with an authenticated request/reply handshake.
  XPC authentication failures and disconnects no longer silently expire as error 60.
- Allow 20 seconds for cold buffer setup and 25 seconds for app startup, keeping
  the physical route until the helper is ready.
- Report competing readers explicitly and release pending grants on cancellation.
- Cover delayed writer startup, cancelled requests, competing readers, and broker
  restart in isolated integration tests.
- Bound the diagnostic helper duration while waiting for route selection too.

## 0.8.2 — 2026-09-09

- Enable volume control automatically on every launch, including Start at Login.
  Disable and helper failures now apply only to the current session.

- Added a macOS app icon, bundled with the application.
- Organized the source tree and consolidated documentation for public development.
- Removed obsolete component installers, unused launch-agent configuration,
  and generated analyzer reports.
- Isolated historical POSIX transport regression fixtures under `tests/legacy`.
- Renamed the audio routing diagnostic from `phase2-verify` to `audio-route-verify`.

## 0.8.1 — 2026-09-08

- Fixed error 60 (audio-buffer timeout) when macOS hosts the driver in
  `com.apple.audio.Core-Audio-Driver-Service.helper`. The broker now accepts
  this exact identifier while still requiring Apple's signature.
- Added verification against the installed Apple helper and rejection tests
  for unrelated Apple executables and ad-hoc identity impersonation.

## 0.8.0 — 2026-09-07

- Replaced production named shared memory with anonymous Mach memory and an
  authenticated XPC broker, exact helper/broker signature pins, and active-user
  checks.
- Added read-only memory capabilities, fresh buffers per connection, and
  session/disconnect revocation.
- Packaged the app, output-only driver, broker, and reader policy as a matching set.

## Earlier prototypes

Development established native volume properties, square-law attenuation,
smoothed gain, readiness checks, safe restoration, and audio-ring regression
coverage. Process-tap and virtual-input approaches were retired. Production
uses neither microphone nor system-recording APIs. Earlier performance and
playback observations do not validate the current implementation.
