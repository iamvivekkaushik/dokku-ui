/// The Store: recipes that turn an official Docker image into a running Dokku
/// app the way one would set it up by hand. Storage is mounted, config set,
/// datastores provisioned and linked, the port mapped, and then the image is
/// deployed. Every step is an ordinary Dokku command, shown before it runs.
library;

import 'dart:convert';
import 'dart:math';

import 'command.dart';

/// Where Dokku keeps app storage on the host.
const storageRoot = '/var/lib/dokku/data/storage';

/// A directory the app has to keep between deploys.
class TemplateMount {
  const TemplateMount(this.path, {required this.name, required this.what, this.owner = 'heroku'});

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
    category: 'Background jobs',
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
    category: 'Webhooks',
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
    category: 'Monitoring',
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
    category: 'Passwords',
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
];

AppTemplate? templateOf(String id) => templates.where((t) => t.id == id).firstOrNull;

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

  /// Generated values, by variable.
  final Map<String, String> secrets;

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

/// The variables an app expects, from the URL a link set:
/// `postgres://user:password@host:5432/database`.
Map<String, String> deriveEnv(TemplateService s, String url) {
  final trimmed = url.trim();
  final u = Uri.tryParse(trimmed);
  final info = (u?.userInfo ?? '').split(':');
  final values = {
    'url': trimmed,
    'host': u?.host ?? '',
    'port': u == null || !u.hasPort ? '' : '${u.port}',
    'user': Uri.decodeComponent(info.first),
    'password': info.length > 1 ? Uri.decodeComponent(info.sublist(1).join(':')) : '',
    'database': Uri.decodeComponent((u?.path ?? '').replaceFirst('/', '')),
  };
  return {for (final e in s.env.entries) e.key: fill(e.value, values)};
}

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
  const InstallPlan(this.template, this.choices, {required this.domain, required this.url, required this.env, required this.steps});
  final AppTemplate template;
  final InstallChoices choices;

  /// The domain the app will answer on, custom or default.
  final String domain;
  final String url;

  /// What `config:set` sets before the deploy, decoded.
  final Map<String, String> env;
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
/// gives the app when no domain is chosen.
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
    if (t.startCommand != null) 'DOKKU_DOCKERFILE_START_CMD': t.startCommand!,
  };
  final memory = c.memory.trim();
  return InstallPlan(t, c, domain: domain, url: url, env: env, steps: [
    RunStep(['apps:create', app]),
    for (final m in t.mounts)
      if (c.mounts.contains(m.name)) ...[
        RunStep(['storage:ensure-directory', if (m.owner != 'herokuish') ...['--chown', m.owner], '$app-${m.name}']),
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
      if (c.services.contains(s.type)) ...[
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

/// The commands as they will run, for reading: config values decoded, secrets
/// and passwords hidden, and the variables a link provides marked as such.
String describePlan(InstallPlan p) {
  final secret = {...p.template.secrets};
  final lines = <String>[];
  for (final s in p.steps) {
    if (s.args.first == 'config:set') {
      final pairs = [for (final e in p.env.entries) '${e.key}=${secret.contains(e.key) ? _mask : shq(e.value)}'];
      lines.add('\$ dokku config:set --no-restart ${p.app} ${pairs.join(' ')}');
      continue;
    }
    lines.add('\$ ${displayCommand(s.args)}');
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

/// Why the install cannot start yet, in the order to fix things.
List<String> installProblems(AppTemplate t, InstallChoices c, {required Set<String> plugins, required Iterable<String> apps}) => [
      if (!appNamePattern.hasMatch(c.app)) 'Name the app with lowercase letters, digits and dashes.',
      if (apps.contains(c.app)) 'An app named ${c.app} already exists.',
      for (final s in t.services)
        if (c.services.contains(s.type) && !plugins.contains(s.type)) 'The ${s.type} plugin is not installed.',
      if (c.letsencrypt && !plugins.contains('letsencrypt')) 'The letsencrypt plugin is not installed.',
      if (c.letsencrypt && !_email.hasMatch(c.email.trim())) "Let's Encrypt needs an email address.",
      if (c.domain.trim().isNotEmpty && !_domain.hasMatch(c.domain.trim())) 'That does not look like a domain.',
      if (c.memory.trim().isNotEmpty && !_memory.hasMatch(c.memory.trim())) 'Memory is a number with k, m or g, such as 512m.',
    ];
