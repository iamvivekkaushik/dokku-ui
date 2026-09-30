# Changelog

What changed in each release of Dokku Console, newest first. The release job
puts the section of the tagged version on the GitHub release, and the app
shows it when it offers the update. A version without a section here does
not get released.

## Unreleased

### Added

- The app checks GitHub for a newer release when it starts and shows what
  changed. On Linux it replaces its own bundle and restarts; on Android,
  macOS and Windows it fetches the build. Found behind the bell and in the
  sidebar footer.
- A Windows build on every release: a zip of the app folder with the Visual
  C++ runtime it needs. Unsigned, like the macOS one.
- This changelog, and a release job that copies the right section onto the
  GitHub release.

### Fixed

- The Server page offered "Review upgrade" on a host already on the latest
  Dokku, and called a host "up to date" when GitHub could not be reached to
  compare. The row now says the host is current and shows no button, and
  says so when the check did not happen.

## 1.2.0 - 2026-09-30

### Added

- A Store of app templates: n8n, Inngest, Outpost, Uptime Kuma, Umami,
  Vaultwarden, Ghost and RustDesk install from their official images with
  ordinary Dokku commands. Storage is mounted with the right owner, config
  set with generated secrets, the port mapped, datastores provisioned and
  linked with the variables each app expects, then the image deployed and
  Let's Encrypt enabled. Every command is shown before it runs.
- RustDesk publishes its TCP and UDP ports on the host with the proxy off,
  and turns off Dokku's `--init` for its s6-overlay image.

## 1.1.1 - 2026-09-30

### Fixed

- Entering a container from the Processes tab closed at once: Dokku takes
  the container as one word, `web.1`, and treats anything after it as the
  command to run. When the image has no bash, the terminal now opens sh.
- App card actions no longer truncate their labels in narrow grid columns.

### Added

- The Linux bundle carries a launcher entry, icons and an install script
  that registers the app for the current user or, as root, for everyone.
- A README front page with screenshots rendered from the app itself.

## 1.1.0 - 2026-09-29

### Added

- An app switcher in the top bar, and a narrower top bar layout.
- A destroy button on app cards and rows, and a destroy dialog that lists
  what will be removed.
- A separate empty state for a host that has no apps yet.

## 1.0.0 - 2026-09-29

First release as a Flutter app: manages Dokku over SSH straight from the
device, with keys in the device keystore and no server component. Apps,
deploys, processes, config, domains and certificates, storage and networks,
datastores, logs, SSH keys, plugins, install and upgrade. Builds for Android,
Linux and macOS from CI.
