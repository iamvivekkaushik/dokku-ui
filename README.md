# Dokku Console

Manage [Dokku](https://dokku.com) servers from your phone or desktop. The app
connects over SSH straight from your device and runs the same `dokku` commands
you would type, showing the exact command behind every action. There is no
server component to host, and nothing is installed on the Dokku server.

Built with Flutter. One codebase for Android, iOS, Linux, macOS and Windows.

## Platforms

Every platform opens the SSH connection itself, straight to the server.

| Platform | Keys are stored in |
| --- | --- |
| Android | Android Keystore |
| iOS | Keychain |
| macOS | Keychain |
| Linux | libsecret (GNOME Keyring, KWallet) |
| Windows | Credential Manager |

## Quick start

```bash
flutter pub get
flutter run
```

Requires Flutter 3.44 or newer. On Linux, building also needs the libsecret
headers:

```bash
sudo apt install libsecret-1-dev libjsoncpp-dev
```

## Connecting a host

| Sign in as | What works |
| --- | --- |
| `dokku` | Everything Dokku allows remotely: apps, deploys, config, domains, certificates, storage, datastores, logs. |
| `root`, or a sudo user with **Run dokku with sudo** | All of the above, plus SSH key management, plugin install and update, Dokku upgrade and install, host CPU, memory and disk metrics, per-container metrics, and the interactive SSH terminal. |

Dokku itself refuses `ssh-keys:add/remove` and `plugin:install/update` for the
`dokku` user, so those buttons are disabled with an explanation in that mode. A
sudo user needs passwordless sudo.

You can sign in with a pasted private key (ed25519, RSA or ECDSA, with or
without a passphrase), a key file on the device (desktop only), or a password.
Saving a host requires a successful connection test.

## Where data is stored

Everything stays on the device.

| What | Where |
| --- | --- |
| Private keys, key passphrases, SSH passwords | The device keystore (see the table above) |
| Host address, port, username, pinned host key | App preferences |
| Activity log, with secrets removed | App preferences |
| Display preferences | App preferences |

Removing a host deletes its key from the keystore. Choosing **Key file** stores
only the path; the key stays in its file.

## Security

- **Host keys are pinned** on first connection and checked on every later one.
  A changed key blocks the connection and says why.
- **No shell injection.** Commands are built as argument lists. The subcommand
  name is validated and every argument is single-quoted before it reaches the
  remote shell.
- **Secrets are kept out of sight.** Config values, registry passwords and
  backup credentials are masked in command previews and in the activity log.
  Registry passwords are sent on stdin rather than as arguments. Config values
  are sent base64-encoded, so multi-line values and special characters arrive
  intact.
- **Destructive actions ask first.** Destroying an app or a datastore requires
  typing its name.

## What it covers

| Area | Where | Dokku commands |
| --- | --- | --- |
| Apps | Apps, app Settings | `apps:create` `destroy` `list` `rename` `clone` `report` `lock` `unlock` |
| Deploys | Deploy app, app Deploys | `git:sync` `git:from-image` `git:set` `git:unlock` `builds:list` `builds:output` `builds:cancel` `ps:rebuild` |
| Builders | app Build | `builder:set` `builder:report` `builder-dockerfile:set` `buildpacks:add` `set` `remove` `clear` |
| Processes | app Processes | `ps:scale` `start` `stop` `restart` `rebuild` `ps:set` `run` `run:detached` `enter` `cron:list` `cron:run` |
| Config | app Environment | `config:export` `config:set` `config:unset` (with `--no-restart`), `.env` import and export |
| Routing | app Routing | `domains:add` `remove` `report` `certs:add` `remove` `report` `letsencrypt:enable` `disable` `auto-renew` `proxy:set` `enable` `disable` `ports:add` `remove` `nginx:set` |
| Storage and network | app Storage & network | `storage:mount` `unmount` `list` `ensure-directory` `docker-options:add` `remove` `report` `network:set` `create` `report` |
| Resources | app Processes | `resource:limit` `reserve` `limit-clear` `reserve-clear` `checks:run` `enable` `skip` `disable` `scheduler:set` |
| Logs | app Logs, Logs & monitoring | `logs -t -n -p` `logs:failed` `events -t` `events:on` |
| Datastores | Datastores | `<service>:create` `link` `unlink` `info` `list` `expose` `unexpose` `start` `stop` `backup` `backup-auth` `backup-schedule` `destroy` for postgres, redis, mysql, mariadb, mongo, elasticsearch, rabbitmq and meilisearch |
| Server | Server & SSH | `ssh-keys:list` `add` `remove` `plugin:list` `install` `update` `enable` `disable` `uninstall` `registry:login` `registry:set` `domains:set-global` |
| Install and upgrade | Install Dokku, Server & SSH | Generates and runs the official `bootstrap.sh`, apt or source install; upgrades with apt |

Anything else can be run from the **Console** in each app's Logs tab, which
accepts any `dokku` command. `enter`, `run` and the SSH terminal open a full
interactive terminal.

### Dokku version notes

Tested against Dokku 0.35 and written to the 0.38 command reference. Where they
differ the app adapts:

- `builds:list` exists from 0.38. On older versions the Deploys tab shows the
  deploys started from the app instead.
- There is no `builds:trigger` command in Dokku; **Trigger rebuild** runs
  `ps:rebuild`.
- `git:unlock` was folded into `apps:unlock` in newer versions; the app tries
  one and falls back to the other. Dokku 0.35 still lists `git:unlock` but
  fails with `command not found`, which is treated the same way.
- `registry:logout` exists from 0.38.
- Dokku ignores an empty value in `resource:limit`. To remove one limit the app
  clears the app's default limits and sets the remaining ones again.
- A port mapping that Dokku only detected cannot be removed, so it has no
  remove button. Mapping a port of your own replaces the detected ones.

## Building

```bash
flutter build apk --release
```

```bash
flutter build linux --release
```

```bash
flutter build macos --release
```

`flutter build macos`, `ios` and `windows` need to run on those systems.

The Android release build is signed with the debug key until you add your own
[signing configuration](https://docs.flutter.dev/deployment/android#signing-the-app),
which is fine for installing it yourself but not for the Play Store.

The macOS build is not signed with a developer identity. The first time, open
it with right-click, **Open**. Keys are kept in the login keychain.

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | Does |
| --- | --- |
| `test` | `flutter analyze` and `flutter test` |
| `android` | Builds the release APK and keeps it as a build artifact |
| `linux` | Builds the Linux bundle and keeps it as a build artifact |
| `macos` | Builds the macOS app and keeps it, zipped, as a build artifact |
| `release` | On a tag like `v1.2.0`, creates a GitHub release with all three attached |

To publish a release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Testing

```bash
flutter test
```

| Suite | Checks |
| --- | --- |
| `test/core` | Quoting, redaction, parsers, tar, host scripts, the install script |
| `test/data` | Host and secret storage |
| `test/state` | Running commands: failures, retries, what is logged |
| `test/widgets` | The shared widget kit |
| `test/screens` | Every screen at phone, tablet and desktop widths, against output captured from a real Dokku server. Layout overflow fails these tests. |
| `test/integration` | Against a live server. Skipped unless configured. |

The live suite has two parts. `ssh_live_test.dart` covers the SSH layer: keys,
host key checks, quoting, streams and terminals. `dokku_commands_live_test.dart`
runs every kind of change the app makes (create, deploy, scale, config,
domains, certificates, storage, networks, datastores, SSH keys) on throwaway
apps named `e2e-*`, and removes them afterwards. Run it against a new Dokku
version to see what changed.

To run the live suite, start a disposable Dokku and point the tests at it:

```bash
docker run -d --name dokku-test -p 127.0.0.1:3022:22 \
  -v /var/run/docker.sock:/var/run/docker.sock dokku/dokku:0.35.20
```

The suite expects these keys in one directory, each added to both the `dokku`
user (`dokku ssh-keys:add`) and root's `authorized_keys`: `test` (ed25519),
`test_rsa`, `test_enc` (passphrase `correct horse`), and `unknown` (not added
anywhere). It also expects an app named `demo-app`, and the server must be able
to pull `traefik/whoami:v1.10` (set `DOKKU_TEST_IMAGE` to use another image).
Do not point it at a server you care about.

```bash
DOKKU_TEST_KEYS=/path/to/keys DOKKU_TEST_PORT=3022 flutter test test/integration
```

## Project layout

```
lib/core/     Pure Dart: command quoting, parsers, install script, host scripts
lib/data/     SSH service, host and secret storage
lib/state/    Riverpod providers: hosts, cached lookups, jobs, routing
lib/ui/       Theme, widget kit, app shell, screens
tool/         Draws the launcher icons
test/         See above
```
