/// The Store: recipes that turn an official Docker image into a running Dokku
/// app the way one would set it up by hand. Storage is mounted, config set,
/// datastores provisioned and linked, or set from the URL of one running
/// elsewhere, the port mapped, and then the image is deployed. Every step is
/// an ordinary Dokku command, shown before it runs.
library;

import 'dart:convert';
import 'dart:math';

import 'command.dart';

/// Where Dokku keeps app storage on the host.
const storageRoot = '/var/lib/dokku/data/storage';

/// A directory the app has to keep between deploys.
class TemplateMount {
  const TemplateMount(this.path, {required this.name, required this.what, this.owner = 'heroku', this.uid});

  /// Path inside the container.
  final String path;

  /// The host directory is `<app>-<name>` under [storageRoot].
  final String name;

  /// What lives there, for the switch that keeps it.
  final String what;

  /// Dokku's `--chown` name: `herokuish`, `heroku` (uid 1000, the `node` user
  /// of most official images) or `paketo`, or `false` to leave the directory to
  /// the dokku user, which an image that runs as root writes to as well.
  final String owner;

  /// The uid the image runs as when it is none of those: the directory is
  /// handed to it with chown on the host, which takes a root or sudo login,
  /// and [owner] does not apply.
  final int? uid;
}

/// A datastore the app uses: provisioned with its Dokku plugin, then linked.
class TemplateService {
  const TemplateService(
    this.type, {
    this.suffix = 'db',
    this.required = false,
    this.from = 'DATABASE_URL',
    this.env = const {},
    this.why = '',
  });

  /// The plugin: postgres, redis, mysql, rabbitmq.
  final String type;

  /// The service is named `<app>-<suffix>`.
  final String suffix;
  final bool required;

  /// The variable linking sets, which [env] is derived from.
  final String from;

  /// Variables the app expects instead of, or besides, [from]. Values may use
  /// {url} {host} {port} {user} {password} {database} of the linked service.
  final Map<String, String> env;

  /// Why one would turn it on, when it is optional.
  final String why;
}

/// A value the user may change before installing, set as one or more
/// variables.
class TemplateSetting {
  const TemplateSetting(this.keys, this.label, {this.value = '', this.hint = '', this.choices = const []});
  final List<String> keys;
  final String label;
  final String value;
  final String hint;

  /// When not empty, the value is one of these.
  final List<String> choices;

  String get id => keys.first;
}

class AppTemplate {
  const AppTemplate({
    required this.id,
    required this.name,
    required this.category,
    required this.tagline,
    required this.description,
    required this.homepage,
    required this.image,
    this.tags = const ['latest'],
    this.port,
    this.publish = const [],
    this.proxy = true,
    this.initProcess = true,
    required this.glyph,
    required this.hue,
    this.mounts = const [],
    this.services = const [],
    this.env = const {},
    this.settings = const [],
    this.secrets = const [],
    this.startCommand,
    this.notes = '',
  });

  /// Also the default app name.
  final String id;
  final String name;
  final String category;
  final String tagline;
  final String description;
  final String homepage;

  /// The image without a tag; [tags] lists the choices, the first by default.
  final String image;
  final List<String> tags;

  /// The port the container listens on, mapped to http:80. Null for an app
  /// that is not reached over HTTP.
  final int? port;

  /// Ports published on the host directly, as docker `-p` values such as
  /// `21116:21116/udp`, for protocols the proxy cannot carry. Two containers
  /// cannot hold the same port, so such an app is stopped before it is
  /// deployed again.
  final List<String> publish;

  /// Whether the app sits behind Dokku's proxy. Off for an app that speaks
  /// no HTTP, so no vhost is configured for it.
  final bool proxy;

  /// Whether Docker's `--init` wraps the container's command, as Dokku does
  /// by default. Off for an image that brings its own init, such as
  /// s6-overlay, which insists on being PID 1.
  final bool initProcess;

  /// Two letters for the tile, and its colour.
  final String glyph;
  final int hue;
  final List<TemplateMount> mounts;
  final List<TemplateService> services;

  /// Variables set before the deploy. Values may use {app} {domain} {url}
  /// {scheme} and {https}, which is `true` or `false`.
  final Map<String, String> env;
  final List<TemplateSetting> settings;

  /// Variables given a random value, generated on the device.
  final List<String> secrets;

  /// Overrides the image's command, through DOKKU_DOCKERFILE_START_CMD.
  final String? startCommand;

  /// What to do once it runs. May use {url} {domain} {app} and {data}, the
  /// host directory of the first mount.
  final String notes;

  String get defaultTag => tags.first;
}

const templates = [
  AppTemplate(
    id: 'n8n',
    name: 'n8n',
    category: 'Automation',
    tagline: 'Workflow automation with hundreds of integrations.',
    description: 'The n8n editor with its workflows, webhooks and credentials. '
        'Keeps everything in SQLite on the mounted directory; add PostgreSQL for production.',
    homepage: 'https://docs.n8n.io/hosting/',
    image: 'docker.n8n.io/n8nio/n8n',
    tags: ['latest', 'next'],
    port: 5678,
    glyph: 'n8',
    hue: 0xFFEA4B71,
    mounts: [TemplateMount('/home/node/.n8n', name: 'data', what: 'workflows, credentials and the SQLite database')],
    services: [
      TemplateService('postgres', why: 'Recommended for production; SQLite otherwise.', env: {
        'DB_TYPE': 'postgresdb',
        'DB_POSTGRESDB_HOST': '{host}',
        'DB_POSTGRESDB_PORT': '{port}',
        'DB_POSTGRESDB_DATABASE': '{database}',
        'DB_POSTGRESDB_USER': '{user}',
        'DB_POSTGRESDB_PASSWORD': '{password}',
      }),
    ],
    env: {
      'N8N_HOST': '{domain}',
      'N8N_PORT': '5678',
      'N8N_PROTOCOL': '{scheme}',
      'WEBHOOK_URL': '{url}/',
      'N8N_SECURE_COOKIE': '{https}',
      'N8N_PROXY_HOPS': '1',
    },
    settings: [TemplateSetting(['GENERIC_TIMEZONE', 'TZ'], 'Timezone', value: 'UTC', hint: 'For schedules, such as Europe/Berlin.')],
    secrets: ['N8N_ENCRYPTION_KEY'],
    notes: 'Open {url} to create the owner account. Credentials are encrypted with N8N_ENCRYPTION_KEY, '
        'which is in the Environment tab: keep a copy of it with your backups.',
  ),
  AppTemplate(
    id: 'inngest',
    name: 'Inngest',
    category: 'Developer tools',
    tagline: 'Durable functions, queues and workflows for your own apps.',
    description: 'The self-hosted Inngest server: event API, executor and dashboard in one container. '
        'Keeps state in SQLite on the mounted directory; add PostgreSQL and Redis for production.',
    homepage: 'https://www.inngest.com/docs/self-hosting',
    image: 'inngest/inngest',
    port: 8288,
    glyph: 'in',
    hue: 0xFF6366F1,
    startCommand: 'inngest start',
    mounts: [TemplateMount('/data', name: 'data', what: 'the SQLite state store')],
    services: [
      TemplateService('postgres', why: 'Durable state for production; SQLite otherwise.', env: {'INNGEST_POSTGRES_URI': '{url}'}),
      TemplateService('redis', suffix: 'redis', from: 'REDIS_URL', why: 'Queue and state for production; in memory otherwise.', env: {
        'INNGEST_REDIS_URI': '{url}',
      }),
    ],
    env: {'INNGEST_HOST': '0.0.0.0', 'INNGEST_PORT': '8288', 'INNGEST_SQLITE_DIR': '/data'},
    secrets: ['INNGEST_EVENT_KEY', 'INNGEST_SIGNING_KEY'],
    notes: 'Point your SDK at {url} with the INNGEST_EVENT_KEY and INNGEST_SIGNING_KEY from the Environment tab, '
        'then sync your app from the dashboard.',
  ),
  AppTemplate(
    id: 'outpost',
    name: 'Outpost',
    category: 'Developer tools',
    tagline: 'Outbound webhooks and event destinations, by Hookdeck.',
    description: 'The Outpost API, delivery and log services in one container. '
        'Needs PostgreSQL, Redis and RabbitMQ, which are provisioned and linked here.',
    homepage: 'https://hookdeck.com/docs/outpost',
    image: 'hookdeck/outpost',
    port: 3333,
    glyph: 'op',
    hue: 0xFF8B5CF6,
    services: [
      TemplateService('postgres', required: true, env: {'POSTGRES_URL': '{url}?sslmode=disable'}),
      TemplateService('redis', suffix: 'redis', required: true, from: 'REDIS_URL', env: {
        'REDIS_HOST': '{host}',
        'REDIS_PORT': '{port}',
        'REDIS_PASSWORD': '{password}',
        'REDIS_DATABASE': '0',
      }),
      TemplateService('rabbitmq', suffix: 'mq', required: true, from: 'RABBITMQ_URL', env: {
        'RABBITMQ_SERVER_URL': '{url}',
        'RABBITMQ_EXCHANGE': 'outpost',
        'RABBITMQ_DELIVERY_QUEUE': 'outpost-delivery',
        'RABBITMQ_LOG_QUEUE': 'outpost-log',
      }),
    ],
    env: {'API_PORT': '3333', 'PORT': '3333'},
    settings: [
      TemplateSetting(['TOPICS'], 'Event topics', value: '*', hint: 'Comma-separated topics tenants can subscribe to, or * for any.'),
      TemplateSetting(['PORTAL_ORGANIZATION_NAME'], 'Organization name', hint: 'Shown in the tenant portal.'),
    ],
    secrets: ['API_KEY', 'API_JWT_SECRET', 'AES_ENCRYPTION_SECRET'],
    notes: 'The API is at {url}/api/v1; authenticate with the API_KEY from the Environment tab.',
  ),
  AppTemplate(
    id: 'uptime-kuma',
    name: 'Uptime Kuma',
    category: 'Monitoring & alerts',
    tagline: 'Uptime monitoring with status pages and notifications.',
    description: 'Checks HTTP, TCP, DNS and more on a schedule, with status pages and alerts to chat and mail. '
        'Everything it knows lives on the mounted directory.',
    homepage: 'https://github.com/louislam/uptime-kuma',
    image: 'louislam/uptime-kuma',
    tags: ['2', '1'],
    port: 3001,
    glyph: 'uk',
    hue: 0xFF5CDD8B,
    mounts: [TemplateMount('/app/data', name: 'data', what: 'monitors, notifications and history')],
    notes: 'Open {url} to create the admin account.',
  ),
  AppTemplate(
    id: 'umami',
    name: 'Umami',
    category: 'Analytics',
    tagline: 'Privacy-friendly web analytics.',
    description: 'A simple alternative to Google Analytics with no cookies and no personal data. '
        'Needs PostgreSQL, which is provisioned and linked here.',
    homepage: 'https://umami.is/docs',
    image: 'docker.umami.is/umami-software/umami',
    tags: ['postgresql-latest'],
    port: 3000,
    glyph: 'um',
    hue: 0xFF0EA5E9,
    services: [TemplateService('postgres', required: true)],
    secrets: ['APP_SECRET'],
    notes: 'Sign in at {url} as admin with the password umami, and change it right away.',
  ),
  AppTemplate(
    id: 'vaultwarden',
    name: 'Vaultwarden',
    category: 'Identity & passwords',
    tagline: 'A Bitwarden-compatible password server.',
    description: 'Works with the official Bitwarden apps and browser extensions. '
        'Vaults and attachments live on the mounted directory. The web vault needs HTTPS.',
    homepage: 'https://github.com/dani-garcia/vaultwarden/wiki',
    image: 'vaultwarden/server',
    port: 80,
    glyph: 'vw',
    hue: 0xFF175DDC,
    mounts: [TemplateMount('/data', name: 'data', what: 'vaults, attachments and the database')],
    env: {'DOMAIN': '{url}'},
    settings: [
      TemplateSetting(['SIGNUPS_ALLOWED'], 'Allow sign-ups', value: 'true', choices: ['true', 'false'], hint: 'Turn off after creating your account.'),
    ],
    secrets: ['ADMIN_TOKEN'],
    notes: 'Clients connect to {url}. The admin page at {url}/admin asks for the ADMIN_TOKEN from the Environment tab.',
  ),
  AppTemplate(
    id: 'ghost',
    name: 'Ghost',
    category: 'Publishing',
    tagline: 'Publishing platform for newsletters and sites.',
    description: 'Posts, members and newsletters, with themes and uploads on the mounted directory. '
        'Needs MySQL, which is provisioned and linked here.',
    homepage: 'https://ghost.org/docs/install/docker/',
    image: 'ghost',
    tags: ['6-alpine', '5-alpine'],
    port: 2368,
    glyph: 'gh',
    hue: 0xFFA3A3A3,
    mounts: [TemplateMount('/var/lib/ghost/content', name: 'content', what: 'themes, images and uploads')],
    services: [
      TemplateService('mysql', required: true, env: {
        'database__client': 'mysql',
        'database__connection__host': '{host}',
        'database__connection__port': '{port}',
        'database__connection__user': '{user}',
        'database__connection__password': '{password}',
        'database__connection__database': '{database}',
      }),
    ],
    env: {'url': '{url}', 'NODE_ENV': 'production'},
    notes: 'Open {url}/ghost to create the owner account.',
  ),
  AppTemplate(
    id: 'rustdesk',
    name: 'RustDesk',
    category: 'Remote desktop',
    tagline: 'Your own ID and relay server for the RustDesk clients.',
    description: 'The ID server (hbbs) and the relay (hbbr) in one container. It speaks no HTTP: ports 21115 to 21119 '
        'are published on the host directly and the proxy is left out. Keys and the database live on the mounted directory.',
    homepage: 'https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/',
    image: 'rustdesk/rustdesk-server-s6',
    proxy: false,
    initProcess: false,
    publish: ['21115:21115', '21116:21116', '21116:21116/udp', '21117:21117', '21118:21118', '21119:21119'],
    glyph: 'rd',
    hue: 0xFF024EFF,
    mounts: [TemplateMount('/data', name: 'data', what: 'the server keys and database', owner: 'false')],
    env: {'RELAY': '{domain}'},
    settings: [
      TemplateSetting(['ENCRYPTED_ONLY'], 'Encrypted connections only', value: '1', choices: ['1', '0'], hint: 'Clients then need the server key.'),
      TemplateSetting(['ALWAYS_USE_RELAY'], 'Always use the relay', value: 'N', choices: ['N', 'Y'], hint: 'Y sends every session through the relay instead of trying a direct connection.'),
    ],
    notes: 'In the RustDesk clients, set the ID server to {domain} and the key to the contents of {data}/id_ed25519.pub on '
        'the host, which the SSH terminal can print. Firewalls must let 21115 to 21119 through. To update it later, stop the '
        'app first: two containers cannot share the published ports.',
  ),
  AppTemplate(
    id: 'node-red',
    name: 'Node-RED',
    category: 'Automation',
    tagline: 'Flow-based programming for wiring devices, APIs and services.',
    description: 'The editor and the runtime in one container. Flows, credentials, settings and installed nodes live on the '
        'mounted directory. The editor is open to everyone until adminAuth is set in settings.js there.',
    homepage: 'https://nodered.org/docs/getting-started/docker',
    image: 'nodered/node-red',
    port: 1880,
    glyph: 'nr',
    hue: 0xFFB91C1C,
    mounts: [TemplateMount('/data', name: 'data', what: 'flows, credentials, settings and installed nodes')],
    settings: [TemplateSetting(['TZ'], 'Timezone', value: 'UTC', hint: 'For the inject node and the logs, such as Europe/Berlin.')],
    notes: 'Open {url} to build flows. Set adminAuth in {data}/settings.js on the host to require a login.',
  ),
  AppTemplate(
    id: 'windmill',
    name: 'Windmill',
    category: 'Automation',
    tagline: 'Scripts, flows and apps as internal tools, with the workers built in.',
    description: 'The server and its workers in one container, in standalone mode. Needs PostgreSQL, which is provisioned and '
        'linked here; nothing is mounted. Scripts run in Python, TypeScript, Go, Bash and more.',
    homepage: 'https://www.windmill.dev/docs/advanced/self_host',
    image: 'ghcr.io/windmill-labs/windmill',
    tags: ['main'],
    port: 8000,
    glyph: 'wm',
    hue: 0xFF0284C7,
    services: [TemplateService('postgres', required: true, env: {'DATABASE_URL': '{url}?sslmode=disable'})],
    env: {'MODE': 'standalone', 'BASE_URL': '{url}'},
    notes: 'Sign in at {url} as admin@windmill.dev with the password changeme, and change it right away.',
  ),
  AppTemplate(
    id: 'gitea',
    name: 'Gitea',
    category: 'Developer tools',
    tagline: 'A painless self-hosted Git service.',
    description: 'The rootless image: repositories, the SQLite database and app.ini live on the mounted directories, owned by '
        'its uid 1000. Git over SSH is published on host port 2222. Add PostgreSQL for larger installs.',
    homepage: 'https://docs.gitea.com/installation/install-with-docker-rootless',
    image: 'gitea/gitea',
    tags: ['latest-rootless'],
    port: 3000,
    publish: ['2222:2222'],
    glyph: 'gi',
    hue: 0xFF609926,
    mounts: [
      TemplateMount('/var/lib/gitea', name: 'data', what: 'repositories, the SQLite database and uploads'),
      TemplateMount('/etc/gitea', name: 'config', what: 'app.ini'),
    ],
    services: [
      TemplateService('postgres', why: 'For larger installs; SQLite otherwise.', env: {
        'GITEA__database__DB_TYPE': 'postgres',
        'GITEA__database__HOST': '{host}:{port}',
        'GITEA__database__NAME': '{database}',
        'GITEA__database__USER': '{user}',
        'GITEA__database__PASSWD': '{password}',
      }),
    ],
    env: {
      'GITEA__server__ROOT_URL': '{url}/',
      'GITEA__server__DOMAIN': '{domain}',
      'GITEA__server__SSH_DOMAIN': '{domain}',
      'GITEA__server__SSH_PORT': '2222',
      'GITEA__server__SSH_LISTEN_PORT': '2222',
      'GITEA__server__START_SSH_SERVER': 'true',
    },
    notes: 'Open {url} to finish the setup and create the administrator. Clone over SSH with ssh://git@{domain}:2222/<owner>/<repo>.git; '
        'the firewall must let 2222 through. To update it later, stop the app first: two containers cannot share the published port.',
  ),
  AppTemplate(
    id: 'keycloak',
    name: 'Keycloak',
    category: 'Identity & passwords',
    tagline: 'Single sign-on with OpenID Connect and SAML.',
    description: 'Realms, users and clients live in PostgreSQL, which is provisioned and linked here; nothing is mounted. '
        'Runs in production mode, which needs HTTPS: turn on the certificate. The first start builds the server, so give it a minute.',
    homepage: 'https://www.keycloak.org/server/containers',
    image: 'quay.io/keycloak/keycloak',
    port: 8080,
    glyph: 'kc',
    hue: 0xFF008AAA,
    startCommand: 'start',
    services: [
      TemplateService('postgres', required: true, env: {
        'KC_DB': 'postgres',
        'KC_DB_URL': 'jdbc:postgresql://{host}:{port}/{database}',
        'KC_DB_USERNAME': '{user}',
        'KC_DB_PASSWORD': '{password}',
      }),
    ],
    env: {'KC_HOSTNAME': '{url}', 'KC_HTTP_ENABLED': 'true', 'KC_PROXY_HEADERS': 'xforwarded'},
    settings: [TemplateSetting(['KC_BOOTSTRAP_ADMIN_USERNAME'], 'Admin user name', value: 'admin')],
    secrets: ['KC_BOOTSTRAP_ADMIN_PASSWORD'],
    notes: 'Open {url}/admin and sign in as the admin user with the KC_BOOTSTRAP_ADMIN_PASSWORD from the Environment tab, '
        'then create a permanent administrator: the bootstrap one is temporary.',
  ),
  AppTemplate(
    id: 'gotify',
    name: 'Gotify',
    category: 'Monitoring & alerts',
    tagline: 'A simple server for sending and receiving push messages.',
    description: 'Applications post messages over a REST API; the web UI and the Android app receive them. '
        'Users, applications and messages live on the mounted directory.',
    homepage: 'https://gotify.net/docs/install',
    image: 'gotify/server',
    port: 80,
    glyph: 'gt',
    hue: 0xFF3B82F6,
    mounts: [TemplateMount('/app/data', name: 'data', what: 'users, applications and messages', owner: 'false')],
    settings: [TemplateSetting(['GOTIFY_DEFAULTUSER_NAME'], 'Admin user name', value: 'admin')],
    secrets: ['GOTIFY_DEFAULTUSER_PASS'],
    notes: 'Sign in at {url} as the admin user with the GOTIFY_DEFAULTUSER_PASS from the Environment tab, '
        'then create an application to get a token for sending.',
  ),
  AppTemplate(
    id: 'ntfy',
    name: 'ntfy',
    category: 'Monitoring & alerts',
    tagline: 'Push notifications to your phone or desktop over plain HTTP.',
    description: 'Publish to a topic with curl and subscribe from the web, Android or iOS apps. The message cache, attachments '
        'and the user database live on the mounted directories. Everyone may publish and subscribe until access is restricted.',
    homepage: 'https://docs.ntfy.sh/install/',
    image: 'binwiederhier/ntfy',
    port: 80,
    glyph: 'nt',
    hue: 0xFF338574,
    startCommand: 'serve',
    mounts: [
      TemplateMount('/var/cache/ntfy', name: 'cache', what: 'the message cache and attachments', owner: 'false'),
      TemplateMount('/var/lib/ntfy', name: 'auth', what: 'users and access control', owner: 'false'),
    ],
    env: {
      'NTFY_BASE_URL': '{url}',
      'NTFY_LISTEN_HTTP': ':80',
      'NTFY_BEHIND_PROXY': 'true',
      'NTFY_CACHE_FILE': '/var/cache/ntfy/cache.db',
      'NTFY_ATTACHMENT_CACHE_DIR': '/var/cache/ntfy/attachments',
      'NTFY_AUTH_FILE': '/var/lib/ntfy/user.db',
      'NTFY_ENABLE_LOGIN': 'true',
    },
    settings: [
      TemplateSetting(['NTFY_AUTH_DEFAULT_ACCESS'], 'Access without login',
          value: 'read-write',
          choices: ['read-write', 'read-only', 'write-only', 'deny-all'],
          hint: 'deny-all makes every topic private; users are added with ntfy user add.'),
    ],
    notes: 'Publish with curl -d hello {url}/mytopic and subscribe at {url}/mytopic. To add users, run '
        'ntfy user add --role=admin <name> in the container from the Processes tab.',
  ),
  AppTemplate(
    id: 'wikijs',
    name: 'Wiki.js',
    category: 'Notes & wikis',
    tagline: 'A modern wiki with Markdown, a visual editor and search.',
    description: 'Pages, users and assets all live in PostgreSQL, which is provisioned and linked here; nothing is mounted. '
        'Authentication, storage and search modules are set up in the administration area.',
    homepage: 'https://docs.requarks.io/install/docker',
    image: 'ghcr.io/requarks/wiki',
    tags: ['2'],
    port: 3000,
    glyph: 'wj',
    hue: 0xFF1976D2,
    services: [
      TemplateService('postgres', required: true, env: {
        'DB_TYPE': 'postgres',
        'DB_HOST': '{host}',
        'DB_PORT': '{port}',
        'DB_USER': '{user}',
        'DB_PASS': '{password}',
        'DB_NAME': '{database}',
        'DB_SSL': 'false',
      }),
    ],
    notes: 'Open {url} to create the administrator account and confirm the site URL.',
  ),
  AppTemplate(
    id: 'docmost',
    name: 'Docmost',
    category: 'Notes & wikis',
    tagline: 'Collaborative wiki and documentation, in the spirit of Notion.',
    description: 'Real-time editing, spaces and comments. Needs PostgreSQL and Redis, which are provisioned and linked here; '
        'uploads live on the mounted directory.',
    homepage: 'https://docmost.com/docs/self-hosting/',
    image: 'docmost/docmost',
    port: 3000,
    glyph: 'dm',
    hue: 0xFF14B8A6,
    mounts: [TemplateMount('/app/data/storage', name: 'storage', what: 'uploads and attachments')],
    services: [
      TemplateService('postgres', required: true),
      TemplateService('redis', suffix: 'redis', required: true, from: 'REDIS_URL'),
    ],
    env: {'APP_URL': '{url}'},
    secrets: ['APP_SECRET'],
    notes: 'Open {url} to create the workspace and its first account.',
  ),
  AppTemplate(
    id: 'memos',
    name: 'Memos',
    category: 'Notes & wikis',
    tagline: 'A lightweight, self-contained note-taking service.',
    description: 'Quick Markdown notes with tags, sharing and a REST API. Everything lives in SQLite on the mounted directory.',
    homepage: 'https://usememos.com/docs/install',
    image: 'neosmemo/memos',
    tags: ['stable', 'latest'],
    port: 5230,
    glyph: 'me',
    hue: 0xFFE9A23B,
    mounts: [TemplateMount('/var/opt/memos', name: 'data', what: 'the SQLite database and uploads', owner: 'false')],
    notes: 'Open {url} to create the first account, which becomes the host user.',
  ),
  AppTemplate(
    id: 'miniflux',
    name: 'Miniflux',
    category: 'Reading',
    tagline: 'A minimalist feed reader.',
    description: 'Feeds, entries and users live in PostgreSQL, which is provisioned and linked here; nothing is mounted. '
        'Migrations run and the admin account is created on the first start.',
    homepage: 'https://miniflux.app/docs/docker.html',
    image: 'miniflux/miniflux',
    port: 8080,
    glyph: 'mf',
    hue: 0xFF2E7D32,
    services: [TemplateService('postgres', required: true, env: {'DATABASE_URL': '{url}?sslmode=disable'})],
    env: {'BASE_URL': '{url}/', 'RUN_MIGRATIONS': '1', 'CREATE_ADMIN': '1'},
    settings: [TemplateSetting(['ADMIN_USERNAME'], 'Admin user name', value: 'admin')],
    secrets: ['ADMIN_PASSWORD'],
    notes: 'Sign in at {url} as the admin user with the ADMIN_PASSWORD from the Environment tab, and change it under Settings.',
  ),
  AppTemplate(
    id: 'vikunja',
    name: 'Vikunja',
    category: 'Teamwork',
    tagline: 'To-do lists, kanban boards and Gantt charts for teams.',
    description: 'The API and the frontend in one container. Keeps tasks in SQLite on the mounted directory; add PostgreSQL '
        'for production. Attachments and avatars live on a second mount.',
    homepage: 'https://vikunja.io/docs/installing/',
    image: 'vikunja/vikunja',
    port: 3456,
    glyph: 'vk',
    hue: 0xFF1973FF,
    mounts: [
      TemplateMount('/db', name: 'db', what: 'the SQLite database'),
      TemplateMount('/app/vikunja/files', name: 'files', what: 'attachments and avatars'),
    ],
    services: [
      TemplateService('postgres', why: 'Recommended for production; SQLite otherwise.', env: {
        'VIKUNJA_DATABASE_TYPE': 'postgres',
        'VIKUNJA_DATABASE_HOST': '{host}:{port}',
        'VIKUNJA_DATABASE_DATABASE': '{database}',
        'VIKUNJA_DATABASE_USER': '{user}',
        'VIKUNJA_DATABASE_PASSWORD': '{password}',
        'VIKUNJA_DATABASE_SSLMODE': 'disable',
      }),
    ],
    env: {'VIKUNJA_SERVICE_PUBLICURL': '{url}/', 'VIKUNJA_DATABASE_PATH': '/db/vikunja.db'},
    secrets: ['VIKUNJA_SERVICE_JWTSECRET'],
    notes: 'Open {url} to register the first account.',
  ),
  AppTemplate(
    id: 'planka',
    name: 'Planka',
    category: 'Teamwork',
    tagline: 'Kanban boards in the Trello style, updated in real time.',
    description: 'Projects, boards, cards and attachments. Needs PostgreSQL, which is provisioned and linked here; uploads live '
        'on the mounted directory. The admin account is created on the first start.',
    homepage: 'https://docs.planka.cloud/',
    image: 'ghcr.io/plankanban/planka',
    port: 1337,
    glyph: 'pk',
    hue: 0xFF17A2B8,
    mounts: [TemplateMount('/app/data', name: 'data', what: 'attachments, avatars and background images')],
    services: [TemplateService('postgres', required: true)],
    env: {'BASE_URL': '{url}', 'TRUST_PROXY': 'true'},
    settings: [
      TemplateSetting(['DEFAULT_ADMIN_EMAIL'], 'Admin email', value: 'admin@example.com', hint: 'The login; change it after the first sign-in.'),
      TemplateSetting(['DEFAULT_ADMIN_USERNAME'], 'Admin user name', value: 'admin'),
      TemplateSetting(['DEFAULT_ADMIN_NAME'], 'Admin display name', value: 'Admin'),
    ],
    secrets: ['SECRET_KEY', 'DEFAULT_ADMIN_PASSWORD'],
    notes: 'Sign in at {url} with the admin email and the DEFAULT_ADMIN_PASSWORD from the Environment tab.',
  ),
  AppTemplate(
    id: 'mattermost',
    name: 'Mattermost',
    category: 'Teamwork',
    tagline: 'Team chat with channels, calls and integrations.',
    description: 'The Team Edition server. Needs PostgreSQL, which is provisioned and linked here. Config, uploads and plugins '
        'live on the mounted directories, owned by its uid 2000.',
    homepage: 'https://docs.mattermost.com/deployment-guide/server/deploy-containers.html',
    image: 'mattermost/mattermost-team-edition',
    port: 8065,
    glyph: 'mm',
    hue: 0xFF5B8DEF,
    mounts: [
      TemplateMount('/mattermost/config', name: 'config', what: 'the server configuration', owner: 'paketo'),
      TemplateMount('/mattermost/data', name: 'data', what: 'uploads and files', owner: 'paketo'),
      TemplateMount('/mattermost/plugins', name: 'plugins', what: 'server plugins', owner: 'paketo'),
      TemplateMount('/mattermost/client/plugins', name: 'client-plugins', what: 'web app plugins', owner: 'paketo'),
    ],
    services: [
      TemplateService('postgres', required: true, env: {
        'MM_SQLSETTINGS_DRIVERNAME': 'postgres',
        'MM_SQLSETTINGS_DATASOURCE': '{url}?sslmode=disable&connect_timeout=10',
      }),
    ],
    env: {'MM_SERVICESETTINGS_SITEURL': '{url}'},
    notes: 'Open {url} to create the first account, which becomes the system administrator.',
  ),
  AppTemplate(
    id: 'open-webui',
    name: 'Open WebUI',
    category: 'AI',
    tagline: 'A chat interface for Ollama and OpenAI-compatible APIs.',
    description: 'Chats, users, documents and settings live on the mounted directory. Point it at an Ollama server or add an API '
        'key afterwards; the image is large and bundles embedding models for retrieval.',
    homepage: 'https://docs.openwebui.com/getting-started/quick-start/',
    image: 'ghcr.io/open-webui/open-webui',
    tags: ['main'],
    port: 8080,
    glyph: 'ow',
    hue: 0xFF22C55E,
    mounts: [TemplateMount('/app/backend/data', name: 'data', what: 'chats, users, documents and settings', owner: 'false')],
    env: {'WEBUI_URL': '{url}'},
    settings: [TemplateSetting(['OLLAMA_BASE_URL'], 'Ollama URL', hint: 'Such as http://10.0.0.5:11434; empty means none for now.')],
    secrets: ['WEBUI_SECRET_KEY'],
    notes: 'Open {url} to create the first account, which becomes the administrator. Connections to Ollama and OpenAI-compatible '
        'APIs are under Admin settings.',
  ),
  AppTemplate(
    id: 'excalidraw',
    name: 'Excalidraw',
    category: 'Whiteboard',
    tagline: 'A virtual whiteboard for hand-drawn diagrams.',
    description: 'The editor alone, served as static files: drawings stay in the browser and export to files. '
        'No storage and no datastore; live collaboration would need the separate room server.',
    homepage: 'https://github.com/excalidraw/excalidraw',
    image: 'excalidraw/excalidraw',
    port: 80,
    glyph: 'ex',
    hue: 0xFF6965DB,
    notes: 'Open {url} and draw.',
  ),
  AppTemplate(
    id: 'grafana',
    name: 'Grafana',
    category: 'Monitoring & alerts',
    tagline: 'Dashboards and alerts over any data source.',
    description: 'Dashboards, users and settings live in SQLite on the mounted directory, which is handed to uid 472, the user '
        'the image runs as. Data sources such as Prometheus or PostgreSQL are added in the UI.',
    homepage: 'https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/',
    image: 'grafana/grafana',
    port: 3000,
    glyph: 'gf',
    hue: 0xFFF46800,
    mounts: [TemplateMount('/var/lib/grafana', name: 'data', what: 'dashboards, users and the SQLite database', uid: 472)],
    env: {'GF_SERVER_ROOT_URL': '{url}'},
    settings: [TemplateSetting(['GF_SECURITY_ADMIN_USER'], 'Admin user name', value: 'admin')],
    secrets: ['GF_SECURITY_ADMIN_PASSWORD'],
    notes: 'Sign in at {url} as the admin user with the GF_SECURITY_ADMIN_PASSWORD from the Environment tab.',
  ),
  AppTemplate(
    id: 'pgadmin',
    name: 'pgAdmin',
    category: 'Developer tools',
    tagline: 'The PostgreSQL administration tool, in the browser.',
    description: 'Saved servers, preferences and query history live on the mounted directory, handed to uid 5050. Servers are '
        'added in the UI; a Dokku PostgreSQL service is reachable once it is exposed on the Datastores page.',
    homepage: 'https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html',
    image: 'dpage/pgadmin4',
    port: 80,
    glyph: 'pa',
    hue: 0xFF336791,
    mounts: [TemplateMount('/var/lib/pgadmin', name: 'data', what: 'saved servers, preferences and query history', uid: 5050)],
    settings: [TemplateSetting(['PGADMIN_DEFAULT_EMAIL'], 'Admin email', value: 'admin@example.com', hint: 'The login.')],
    secrets: ['PGADMIN_DEFAULT_PASSWORD'],
    notes: 'Sign in at {url} with the admin email and the PGADMIN_DEFAULT_PASSWORD from the Environment tab.',
  ),
  AppTemplate(
    id: 'verdaccio',
    name: 'Verdaccio',
    category: 'Developer tools',
    tagline: 'A private npm registry and proxy.',
    description: 'Publishes your own packages and caches the public registry. Packages and users live on the mounted directory, '
        'handed to uid 10001. The configuration in the image lets anyone register and publish.',
    homepage: 'https://verdaccio.org/docs/docker',
    image: 'verdaccio/verdaccio',
    tags: ['6'],
    port: 4873,
    glyph: 'vd',
    hue: 0xFF4B5E40,
    mounts: [TemplateMount('/verdaccio/storage', name: 'storage', what: 'packages and users', uid: 10001)],
    env: {'VERDACCIO_PUBLIC_URL': '{url}'},
    notes: 'Point npm at it with npm set registry {url}, then npm adduser to create the first user.',
  ),
  AppTemplate(
    id: 'hedgedoc',
    name: 'HedgeDoc',
    category: 'Notes & wikis',
    tagline: 'Collaborative Markdown notes, in real time.',
    description: 'Notes and users live in PostgreSQL, which is provisioned and linked here; uploaded images live on the mounted '
        'directory, handed to uid 10000. Anyone may register until sign-ups are turned off.',
    homepage: 'https://docs.hedgedoc.org/setup/docker/',
    image: 'quay.io/hedgedoc/hedgedoc',
    tags: ['latest', 'alpine'],
    port: 3000,
    glyph: 'hd',
    hue: 0xFFB51F08,
    mounts: [TemplateMount('/hedgedoc/public/uploads', name: 'uploads', what: 'uploaded images', uid: 10000)],
    services: [TemplateService('postgres', required: true, env: {'CMD_DB_URL': '{url}'})],
    env: {'CMD_DOMAIN': '{domain}', 'CMD_PROTOCOL_USESSL': '{https}', 'CMD_URL_ADDPORT': 'false'},
    settings: [
      TemplateSetting(['CMD_ALLOW_EMAIL_REGISTER'], 'Allow sign-ups', value: 'true', choices: ['true', 'false'], hint: 'Turn off after creating your account.'),
    ],
    secrets: ['CMD_SESSION_SECRET'],
    notes: 'Open {url} and register the first account.',
  ),
  AppTemplate(
    id: 'outline',
    name: 'Outline',
    category: 'Notes & wikis',
    tagline: 'A team knowledge base, fast and well designed.',
    description: 'Documents live in PostgreSQL and sessions in Redis, both provisioned and linked here; uploads live on the mounted '
        'directory, handed to uid 1001. Outline has no passwords of its own: sign-in goes through an OpenID Connect provider such as '
        'Keycloak or Pocket ID, set below or later in the Environment tab.',
    homepage: 'https://docs.getoutline.com/s/hosting/',
    image: 'outlinewiki/outline',
    port: 3000,
    glyph: 'ol',
    hue: 0xFF0366D6,
    mounts: [TemplateMount('/var/lib/outline/data', name: 'data', what: 'uploaded files and images', uid: 1001)],
    services: [
      TemplateService('postgres', required: true),
      TemplateService('redis', suffix: 'redis', required: true, from: 'REDIS_URL'),
    ],
    env: {
      'URL': '{url}',
      'FORCE_HTTPS': '{https}',
      'PGSSLMODE': 'disable',
      'FILE_STORAGE': 'local',
      'FILE_STORAGE_LOCAL_ROOT_DIR': '/var/lib/outline/data',
      'FILE_STORAGE_UPLOAD_MAX_SIZE': '262144000',
    },
    settings: [
      TemplateSetting(['OIDC_CLIENT_ID'], 'OIDC client ID'),
      TemplateSetting(['OIDC_CLIENT_SECRET'], 'OIDC client secret'),
      TemplateSetting(['OIDC_AUTH_URI'], 'OIDC authorization URL', hint: 'Such as https://id.example.com/realms/main/protocol/openid-connect/auth'),
      TemplateSetting(['OIDC_TOKEN_URI'], 'OIDC token URL'),
      TemplateSetting(['OIDC_USERINFO_URI'], 'OIDC user info URL'),
      TemplateSetting(['OIDC_DISPLAY_NAME'], 'Sign-in button label', value: 'OpenID Connect'),
    ],
    secrets: ['SECRET_KEY', 'UTILS_SECRET'],
    notes: 'Open {url} and sign in through the OpenID Connect provider; the first account becomes the admin. '
        'Its redirect URL is {url}/auth/oidc.callback.',
  ),
  AppTemplate(
    id: 'formbricks',
    name: 'Formbricks',
    category: 'Analytics',
    tagline: 'Surveys and forms, in your app and by link.',
    description: 'Needs PostgreSQL and Redis, which are provisioned and linked here; uploads live on the mounted directory, '
        'handed to uid 1001.',
    homepage: 'https://formbricks.com/docs/self-hosting/setup/docker',
    image: 'ghcr.io/formbricks/formbricks',
    port: 3000,
    glyph: 'fb',
    hue: 0xFF00C4B8,
    mounts: [TemplateMount('/home/nextjs/apps/web/uploads', name: 'uploads', what: 'uploaded files', uid: 1001)],
    services: [
      TemplateService('postgres', required: true),
      TemplateService('redis', suffix: 'redis', required: true, from: 'REDIS_URL'),
    ],
    env: {'WEBAPP_URL': '{url}', 'NEXTAUTH_URL': '{url}'},
    secrets: ['NEXTAUTH_SECRET', 'ENCRYPTION_KEY', 'CRON_SECRET'],
    notes: 'Open {url} to create the first account, which owns the organization.',
  ),
  AppTemplate(
    id: 'actual',
    name: 'Actual Budget',
    category: 'Finance',
    tagline: 'Local-first envelope budgeting, synced through your own server.',
    description: 'The sync server: budgets and user files live on the mounted directory, handed to uid 1001. The apps and the '
        'web client sync through it and keep working offline.',
    homepage: 'https://actualbudget.org/docs/install/docker',
    image: 'actualbudget/actual-server',
    tags: ['latest', 'latest-alpine'],
    port: 5006,
    glyph: 'ab',
    hue: 0xFF7C3AED,
    mounts: [TemplateMount('/data', name: 'data', what: 'budgets and user files', uid: 1001)],
    notes: 'Open {url} to set the server password, then point the Actual apps at it.',
  ),
  AppTemplate(
    id: 'searxng',
    name: 'SearXNG',
    category: 'Search',
    tagline: 'A private metasearch engine over many sources.',
    description: 'Queries go to the engines you enable and come back without tracking. settings.yml is written on the first '
        'start to the mounted config directory, the favicon cache to the second; both are handed to uid 977, the user the '
        'image runs as.',
    homepage: 'https://docs.searxng.org/admin/installation-docker.html',
    image: 'searxng/searxng',
    port: 8080,
    glyph: 'sx',
    hue: 0xFF3050FF,
    mounts: [
      TemplateMount('/etc/searxng', name: 'config', what: 'settings.yml', uid: 977),
      TemplateMount('/var/cache/searxng', name: 'cache', what: 'the favicon cache', uid: 977),
    ],
    env: {'SEARXNG_BASE_URL': '{url}/'},
    secrets: ['SEARXNG_SECRET'],
    notes: 'Open {url} and search. Engines and the look are set in {data}/settings.yml on the host.',
  ),
  AppTemplate(
    id: 'linkding',
    name: 'linkding',
    category: 'Reading',
    tagline: 'A bookmark manager that stays out of the way.',
    description: 'Bookmarks, tags and the SQLite database live on the mounted directory. The first user is created on the first '
        'start; add PostgreSQL for large collections.',
    homepage: 'https://linkding.link/installation/',
    image: 'sissbruecker/linkding',
    tags: ['latest', 'latest-plus'],
    port: 9090,
    glyph: 'ld',
    hue: 0xFF5856D6,
    mounts: [TemplateMount('/etc/linkding/data', name: 'data', what: 'bookmarks and the SQLite database', owner: 'false')],
    services: [
      TemplateService('postgres', why: 'For large collections; SQLite otherwise.', env: {
        'LD_DB_ENGINE': 'postgres',
        'LD_DB_HOST': '{host}',
        'LD_DB_PORT': '{port}',
        'LD_DB_DATABASE': '{database}',
        'LD_DB_USER': '{user}',
        'LD_DB_PASSWORD': '{password}',
      }),
    ],
    env: {'LD_CSRF_TRUSTED_ORIGINS': '{url}'},
    settings: [TemplateSetting(['LD_SUPERUSER_NAME'], 'Admin user name', value: 'admin')],
    secrets: ['LD_SUPERUSER_PASSWORD'],
    notes: 'Sign in at {url} as the admin user with the LD_SUPERUSER_PASSWORD from the Environment tab.',
  ),
];

AppTemplate? templateOf(String id) => templates.where((t) => t.id == id).firstOrNull;

/// Every category in the catalog, in alphabetical order, with how many
/// templates each holds.
Map<String, int> templateCategories() {
  final counts = <String, int>{};
  for (final t in templates) {
    counts[t.category] = (counts[t.category] ?? 0) + 1;
  }
  return {for (final k in counts.keys.toList()..sort()) k: counts[k]!};
}

/// The port a datastore of each type listens on, for a URL that leaves it out.
const _defaultPorts = {
  'postgres': '5432',
  'redis': '6379',
  'mysql': '3306',
  'mariadb': '3306',
  'mongo': '27017',
  'rabbitmq': '5672',
  'elasticsearch': '9200',
  'meilisearch': '7700',
};

/// What the URL of a datastore of [type] looks like, for the install dialog.
String serviceUrlExample(String type) => switch (type) {
      'postgres' => 'postgres://user:password@host:5432/db',
      'redis' => 'redis://:password@host:6379',
      'mysql' || 'mariadb' => 'mysql://user:password@host:3306/db',
      'mongo' => 'mongodb://user:password@host:27017/db',
      'rabbitmq' => 'amqp://user:password@host:5672/vhost',
      'elasticsearch' => 'http://host:9200',
      'meilisearch' => 'http://host:7700',
      _ => 'scheme://user:password@host:port/db',
    };

/// Whether [url] can stand in for what a link sets: a scheme and a host, and
/// no whitespace.
bool looksLikeServiceUrl(String url) {
  final u = url.trim();
  if (u.contains(RegExp(r'\s'))) return false;
  final parsed = Uri.tryParse(u);
  return parsed != null && parsed.hasScheme && parsed.host.isNotEmpty;
}

/// What the user decided in the install dialog.
class InstallChoices {
  const InstallChoices({
    required this.app,
    required this.tag,
    this.domain = '',
    this.letsencrypt = false,
    this.email = '',
    required this.mounts,
    required this.services,
    this.settings = const {},
    this.memory = '',
    this.urls = const {},
    required this.secrets,
  });

  final String app;
  final String tag;

  /// Empty means the host's default, `<app>.<global domain>`.
  final String domain;
  final bool letsencrypt;
  final String email;

  /// Names of the mounts to keep.
  final Set<String> mounts;

  /// Types of the services to provision.
  final Set<String> services;

  /// By setting id.
  final Map<String, String> settings;

  /// A `resource:limit --memory` value, or empty for none.
  final String memory;

  /// By service type: the URL of a datastore running elsewhere, used instead
  /// of provisioning one with the plugin. Empty means provision.
  final Map<String, String> urls;

  /// Generated values, by variable.
  final Map<String, String> secrets;

  String urlOf(String type) => (urls[type] ?? '').trim();

  InstallChoices copyWith({
    String? app,
    String? tag,
    String? domain,
    bool? letsencrypt,
    String? email,
    Set<String>? mounts,
    Set<String>? services,
    Map<String, String>? settings,
    String? memory,
    Map<String, String>? urls,
  }) =>
      InstallChoices(
        app: app ?? this.app,
        tag: tag ?? this.tag,
        domain: domain ?? this.domain,
        letsencrypt: letsencrypt ?? this.letsencrypt,
        email: email ?? this.email,
        mounts: mounts ?? this.mounts,
        services: services ?? this.services,
        settings: settings ?? this.settings,
        memory: memory ?? this.memory,
        urls: urls ?? this.urls,
        secrets: secrets,
      );
}

/// The template as it comes: every mount kept, required services on, optional
/// ones off, and fresh secrets.
InstallChoices defaultChoices(AppTemplate t) => InstallChoices(
      app: t.id,
      tag: t.defaultTag,
      mounts: {for (final m in t.mounts) m.name},
      services: {for (final s in t.services) if (s.required) s.type},
      settings: {for (final s in t.settings) s.id: s.value},
      secrets: {for (final k in t.secrets) k: generateSecret()},
    );

/// 32 random bytes as hex, which every app accepts as a key or token.
String generateSecret() {
  final r = Random.secure();
  return [for (var i = 0; i < 32; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

final _placeholder = RegExp(r'\{(\w+)\}');

/// Replaces `{name}` with [values], leaving unknown names as they are.
String fill(String text, Map<String, String> values) => text.replaceAllMapped(_placeholder, (m) => values[m[1]] ?? m[0]!);

/// The variables an app expects, from the URL a link set, or one the user
/// gave: `postgres://user:password@host:5432/database`. A query the template
/// adds to `{url}`, such as sslmode=disable for the plugin's service, gives
/// way to the one the URL brings.
Map<String, String> deriveEnv(TemplateService s, String url) {
  final trimmed = url.trim();
  final hasQuery = trimmed.contains('?');
  final u = Uri.tryParse(trimmed);
  final info = (u?.userInfo ?? '').split(':');
  final values = {
    'url': trimmed,
    'host': u?.host ?? '',
    'port': u == null || !u.hasPort ? _defaultPorts[s.type] ?? '' : '${u.port}',
    'user': Uri.decodeComponent(info.first),
    'password': info.length > 1 ? Uri.decodeComponent(info.sublist(1).join(':')) : '',
    'database': Uri.decodeComponent((u?.path ?? '').replaceFirst('/', '')),
  };
  return {for (final e in s.env.entries) e.key: fill(hasQuery ? e.value.replaceAll(_urlQuery, '{url}') : e.value, values)};
}

final _urlQuery = RegExp(r'\{url\}\?\S*');

/// `config:set` with every value base64-encoded, so that quotes, spaces and
/// line breaks arrive intact, and without a restart: the app is not deployed yet.
List<String> configSetArgs(String app, Map<String, String> env) => [
      'config:set',
      '--encoded',
      '--no-restart',
      app,
      for (final e in env.entries) '${e.key}=${base64.encode(utf8.encode(e.value))}',
    ];

/// One command of an install.
sealed class PlanStep {
  const PlanStep(this.args, {this.timeout = const Duration(minutes: 30), this.quiet = false});
  final List<String> args;
  final Duration timeout;

  /// A failure is left in the dock without stopping the install.
  final bool quiet;
}

class RunStep extends PlanStep {
  const RunStep(super.args, {super.timeout, super.quiet});
}

/// A command on the host itself rather than a Dokku one: chown for a mount
/// with a uid. Only a root or sudo login can run it.
class HostStep extends PlanStep {
  const HostStep(super.args) : super(timeout: const Duration(minutes: 2));
}

/// Links a service; afterwards the variables the app expects are set from
/// the URL the link put on the app.
class LinkStep extends PlanStep {
  LinkStep(this.service, this.name, this.app) : super(['${service.type}:link', name, app, '--no-restart']);
  final TemplateService service;
  final String name;
  final String app;

  Map<String, String> derive(String url) => deriveEnv(service, url);
}

class InstallPlan {
  const InstallPlan(this.template, this.choices,
      {required this.domain, required this.url, required this.env, required this.steps, this.hidden = const {}});
  final AppTemplate template;
  final InstallChoices choices;

  /// The domain the app will answer on, custom or default.
  final String domain;
  final String url;

  /// What `config:set` sets before the deploy, decoded.
  final Map<String, String> env;

  /// The keys of [env] the preview masks: secrets, and what a datastore URL
  /// carries.
  final Set<String> hidden;
  final List<PlanStep> steps;

  String get app => choices.app;
  String get notes => fill(template.notes, {
        'url': url,
        'domain': domain,
        'app': app,
        'data': template.mounts.isEmpty ? '' : '$storageRoot/$app-${template.mounts.first.name}',
      });
}

/// Every command an install runs, in order. [defaultDomain] is what the host
/// gives the app when no domain is chosen. A service the user gave a URL for
/// is neither created nor linked: its variables go into the config:set.
InstallPlan planInstall(AppTemplate t, InstallChoices c, {required String defaultDomain}) {
  final app = c.app;
  final custom = c.domain.trim();
  final domain = custom.isEmpty ? defaultDomain : custom;
  final scheme = c.letsencrypt && t.proxy ? 'https' : 'http';
  final url = '$scheme://$domain';
  final values = {'app': app, 'domain': domain, 'url': url, 'scheme': scheme, 'https': scheme == 'https' ? 'true' : 'false'};
  final env = <String, String>{
    for (final e in t.env.entries) e.key: fill(e.value, values),
    for (final s in t.settings)
      for (final k in s.keys)
        if ((c.settings[s.id] ?? s.value).trim().isNotEmpty) k: (c.settings[s.id] ?? s.value).trim(),
    for (final k in t.secrets) k: c.secrets[k] ?? '',
    for (final s in t.services)
      if (c.services.contains(s.type) && c.urlOf(s.type).isNotEmpty) ...{s.from: c.urlOf(s.type), ...deriveEnv(s, c.urlOf(s.type))},
    if (t.startCommand != null) 'DOKKU_DOCKERFILE_START_CMD': t.startCommand!,
  };
  final hidden = <String>{
    ...t.secrets,
    for (final s in t.services)
      if (c.services.contains(s.type) && c.urlOf(s.type).isNotEmpty) ...[
        s.from,
        for (final e in s.env.entries)
          if (e.value.contains('{url}') || e.value.contains('{password}')) e.key,
      ],
  };
  final memory = c.memory.trim();
  return InstallPlan(t, c, domain: domain, url: url, env: env, hidden: hidden, steps: [
    RunStep(['apps:create', app]),
    for (final m in t.mounts)
      if (c.mounts.contains(m.name)) ...[
        RunStep([
          'storage:ensure-directory',
          if (m.uid != null) ...['--chown', 'false'] else if (m.owner != 'herokuish') ...['--chown', m.owner],
          '$app-${m.name}',
        ]),
        if (m.uid != null) HostStep(['chown', '${m.uid}:${m.uid}', '$storageRoot/$app-${m.name}']),
        RunStep(['storage:mount', app, '$storageRoot/$app-${m.name}:${m.path}']),
      ],
    if (env.isNotEmpty) RunStep(configSetArgs(app, env)),
    if (t.port != null) RunStep(['ports:set', app, 'http:80:${t.port}']),
    for (final p in t.publish) RunStep(['docker-options:add', app, 'deploy', '-p $p']),
    if (!t.proxy) RunStep(['proxy:disable', app]),
    if (!t.initProcess) RunStep(['scheduler-docker-local:set', app, 'init-process', 'false']),
    if (custom.isNotEmpty) RunStep(['domains:set', app, domain]),
    if (memory.isNotEmpty) RunStep(['resource:limit', '--memory', memory, app]),
    for (final s in t.services)
      if (c.services.contains(s.type) && c.urlOf(s.type).isEmpty) ...[
        RunStep(['${s.type}:create', '$app-${s.suffix}'], timeout: const Duration(minutes: 20)),
        LinkStep(s, '$app-${s.suffix}', app),
      ],
    RunStep(['git:from-image', app, '${t.image}:${c.tag}']),
    if (c.letsencrypt && t.proxy) ...[
      RunStep(['letsencrypt:set', app, 'email', c.email.trim()]),
      RunStep(['letsencrypt:enable', app], timeout: const Duration(minutes: 10)),
      RunStep(['letsencrypt:cron-job', '--add'], quiet: true),
    ],
  ]);
}

const _mask = '•••';

/// The commands as they will run, for reading: config values decoded, secrets,
/// datastore URLs and passwords hidden, and the variables a link provides
/// marked as such.
String describePlan(InstallPlan p) {
  final secret = p.hidden;
  final lines = <String>[];
  for (final s in p.steps) {
    if (s.args.first == 'config:set') {
      final pairs = [for (final e in p.env.entries) '${e.key}=${secret.contains(e.key) ? _mask : shq(e.value)}'];
      lines.add('\$ dokku config:set --no-restart ${p.app} ${pairs.join(' ')}');
      continue;
    }
    lines.add(s is HostStep ? '\$ ${s.args.map(shq).join(' ')}' : '\$ ${displayCommand(s.args)}');
    if (s is LinkStep && s.service.env.isNotEmpty) {
      final pairs = [for (final k in s.service.env.keys) '$k=<from ${s.service.from}>'];
      lines.add('\$ dokku config:set --no-restart ${p.app} ${pairs.join(' ')}');
    }
  }
  return lines.join('\n');
}

final _domain = RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$', caseSensitive: false);
final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final _memory = RegExp(r'^\d+[kmg]?$', caseSensitive: false);

/// Whether a kept mount is handed to a uid with chown on the host, which
/// only a root or sudo login can do. Without [mounts], any such mount counts.
bool needsChown(AppTemplate t, {Set<String>? mounts}) =>
    t.mounts.any((m) => m.uid != null && (mounts == null || mounts.contains(m.name)));

/// Why the install cannot start yet, in the order to fix things. [shell] is
/// whether the login can run commands on the host itself.
List<String> installProblems(AppTemplate t, InstallChoices c, {required Set<String> plugins, required Iterable<String> apps, bool shell = true}) => [
      if (!appNamePattern.hasMatch(c.app)) 'Name the app with lowercase letters, digits and dashes.',
      if (apps.contains(c.app)) 'An app named ${c.app} already exists.',
      if (!shell && needsChown(t, mounts: c.mounts))
        'Handing storage to uid ${t.mounts.firstWhere((m) => m.uid != null && c.mounts.contains(m.name)).uid} needs root. '
            'Connect as root or as a user with sudo.',
      for (final s in t.services)
        if (c.services.contains(s.type) && c.urlOf(s.type).isEmpty && !plugins.contains(s.type))
          'The ${s.type} plugin is not installed. Install it, or give the URL of one running elsewhere.',
      for (final s in t.services)
        if (c.services.contains(s.type) && c.urlOf(s.type).isNotEmpty && !looksLikeServiceUrl(c.urlOf(s.type)))
          'The ${s.type} URL needs a scheme and a host, like ${serviceUrlExample(s.type)}.',
      if (c.letsencrypt && !plugins.contains('letsencrypt')) 'The letsencrypt plugin is not installed.',
      if (c.letsencrypt && !_email.hasMatch(c.email.trim())) "Let's Encrypt needs an email address.",
      if (c.domain.trim().isNotEmpty && !_domain.hasMatch(c.domain.trim())) 'That does not look like a domain.',
      if (c.memory.trim().isNotEmpty && !_memory.hasMatch(c.memory.trim())) 'Memory is a number with k, m or g, such as 512m.',
    ];
