# Changelog

## Unreleased

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
