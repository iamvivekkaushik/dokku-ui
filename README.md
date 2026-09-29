# Dokku Console

A web console for managing [Dokku](https://dokku.com) hosts over SSH. Nothing is
installed on the Dokku server: the console opens an SSH connection, runs the
same `dokku` commands you would type, and shows you the exact command behind
every action.

## Quick start

```bash
npm install
npm run dev
```

Open http://localhost:5173 and choose **Connect a host**.

For a production build:

```bash
npm run build
npm start          # serves the UI and API on http://127.0.0.1:4280
```

Requires Node.js 20 or newer.

## Connecting a host

| Connect as | What works |
| --- | --- |
| `dokku` | Everything Dokku allows remotely: apps, deploys, config, domains, certificates, storage, datastores, logs. |
| `root`, or a sudo user with **Run dokku with sudo** | All of the above, plus SSH key management, plugin install/update, Dokku upgrade and install, host CPU/memory/disk metrics, per-container metrics, and the interactive SSH terminal. |

Dokku itself refuses `ssh-keys:add/remove` and `plugin:install/update` for the
`dokku` user, so those buttons are disabled with an explanation in that mode.
A sudo user needs passwordless sudo (`sudo -n`).

Authentication can be a pasted private key, a key path on the console server
(for example `~/.ssh/id_ed25519`), a password, or the SSH agent.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DOKKU_UI_PORT` | `4280` | API/UI port. In production `PORT` is also honoured. |
| `HOST` | `127.0.0.1` | Bind address. |
| `DOKKU_UI_PASSWORD` | _(none)_ | Password for the console. Required when binding to anything other than loopback. |
| `DOKKU_UI_ALLOWED_HOSTS` | _(none)_ | Comma-separated hostnames the console may be reached at (for example `console.example.com`). |
| `DOKKU_UI_DATA_DIR` | `./data` | Where saved hosts and the activity log are stored. |
| `DOKKU_UI_INSECURE` | _(unset)_ | Set to `1` to allow a non-loopback bind without a password. Not recommended. |

## Security model

This console holds SSH credentials that can control your servers. Treat it like
an SSH client, not like a public website.

- **Runs locally by default.** It binds to `127.0.0.1` and refuses to listen on
  other interfaces unless a password is set. To reach it remotely, prefer an
  SSH tunnel or a VPN; if you expose it, put it behind HTTPS.
- **Credentials stay on the console server** in `data/hosts.json` (mode `600`).
  They are never sent back to the browser. They are stored unencrypted, the
  same as a private key in `~/.ssh`, so protect that directory accordingly.
- **Host keys are pinned** on first connection and verified afterwards. A
  changed key blocks the connection with an explanation.
- **No shell injection.** The browser sends an argument list, never a command
  string. The server checks the subcommand name and single-quotes every
  argument before it reaches the remote shell.
- **Secrets are redacted** from the activity log and the on-screen command
  previews (config values, registry passwords, backup credentials). Registry
  passwords are piped over stdin rather than passed as arguments.
- **Browser protections:** API writes need a custom header (blocks cross-site
  form posts), the `Host` header is checked (blocks DNS rebinding), WebSockets
  check `Origin`, and session cookies are `HttpOnly` and `SameSite=Strict`.

## What it covers

| Area | Where | Dokku commands |
| --- | --- | --- |
| Apps | Apps, app Settings | `apps:create` `destroy` `list` `rename` `clone` `report` `lock` `unlock` |
| Deploys | Deploy app, app Deploys | `git:sync` `git:from-image` `git:set` `git:unlock` `builds:list` `builds:output` `builds:cancel` `ps:rebuild` |
| Builders | app Build | `builder:set` `builder:report` `builder-dockerfile:set` `buildpacks:add` `set` `remove` `clear` |
| Processes | app Processes | `ps:scale` `start` `stop` `restart` `rebuild` `ps:set` `run` `enter` `cron:list` `cron:run` |
| Config | app Environment | `config:export` `config:set` `config:unset` (with `--no-restart`), `.env` import and export |
| Routing | app Routing | `domains:add` `remove` `report` `certs:add` `remove` `report` `letsencrypt:enable` `disable` `auto-renew` `proxy:set` `enable` `disable` `ports:add` `remove` `nginx:set` |
| Storage and network | app Storage & network | `storage:mount` `unmount` `list` `ensure-directory` `docker-options:add` `remove` `report` `network:set` `create` `report` |
| Resources | app Processes | `resource:limit` `reserve` `limit-clear` `reserve-clear` `checks:run` `enable` `skip` `disable` `scheduler:set` |
| Logs | app Logs, Logs & monitoring | `logs -t -n -p` `logs:failed` `events -t` `events:on` |
| Datastores | Datastores | `<service>:create` `link` `unlink` `info` `list` `expose` `unexpose` `start` `stop` `backup` `backup-auth` `backup-schedule` `destroy` for postgres, redis, mysql, mariadb, mongo, elasticsearch, rabbitmq and meilisearch |
| Server | Server & SSH | `ssh-keys:list` `add` `remove` `plugin:list` `install` `update` `enable` `disable` `uninstall` `registry:login` `registry:set` `domains:set-global` |
| Install and upgrade | Install Dokku, Server & SSH | Generates and runs the official `bootstrap.sh`, apt or source install; upgrades with apt |

Anything else can be run from the **Console** (each app's Logs tab, or the top
bar), which accepts any `dokku` command. `enter`, `run` and the SSH terminal
open a full interactive terminal.

### Dokku version notes

The console is tested against Dokku 0.35 and written to the 0.38 command
reference. Where they differ it adapts:

- `builds:list` exists from 0.38. On older versions the Deploys tab shows the
  deploys started from the console instead.
- There is no `builds:trigger` command in Dokku; **Trigger rebuild** runs
  `ps:rebuild`.
- `git:unlock` was folded into `apps:unlock` in newer versions; the console
  tries one and falls back to the other.
- `registry:logout` and listing logged-in registries as the `dokku` user need
  0.38.

## Development

```bash
npm test            # unit tests (quoting, parsers, tar, install script)
npm run typecheck
```

```
server/   Express API, SSH connection pool, WebSocket streams
shared/   Types and code used by both sides (quoting, redaction, install script)
src/      React UI (Vite, Tailwind, Radix, xterm.js)
test/     Vitest suites
```

A disposable Dokku for local testing:

```bash
docker run -d --name dokku-test -p 127.0.0.1:3022:22 \
  -v /var/run/docker.sock:/var/run/docker.sock dokku/dokku:0.35.20
docker exec -i dokku-test dokku ssh-keys:add me < ~/.ssh/id_ed25519.pub
```

Then connect to `127.0.0.1`, port `3022`, user `dokku`. Datastore containers do
not start in this Docker-in-Docker setup because their config directories are
mounted from inside the Dokku container; use a real VM to test those fully.
