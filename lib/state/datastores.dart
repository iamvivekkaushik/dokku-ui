import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/parse.dart';
import '../data/models.dart';
import 'core.dart';
import 'queries.dart';

class DatastoreDef {
  const DatastoreDef(this.type, this.name, this.glyph, this.hue, this.version, this.port, this.envVar);
  final String type;
  final String name;
  final String glyph;
  final Color hue;

  /// Suggested image version in the provision dialog.
  final String version;
  final int port;

  /// The variable linking sets on the app.
  final String envVar;

  String get repo => 'https://github.com/dokku/dokku-$type.git';
}

const datastores = [
  DatastoreDef('postgres', 'PostgreSQL', 'pg', Color(0xFF3B82F6), '17.2', 5432, 'DATABASE_URL'),
  DatastoreDef('redis', 'Redis', 'rd', Color(0xFFEF4444), '7.4', 6379, 'REDIS_URL'),
  DatastoreDef('mysql', 'MySQL', 'my', Color(0xFF3B82F6), '8.4', 3306, 'DATABASE_URL'),
  DatastoreDef('mariadb', 'MariaDB', 'md', Color(0xFF22C55E), '11.4', 3306, 'DATABASE_URL'),
  DatastoreDef('mongo', 'MongoDB', 'mg', Color(0xFF22C55E), '7.0', 27017, 'MONGO_URL'),
  DatastoreDef('elasticsearch', 'Elasticsearch', 'es', Color(0xFFF59E0B), '8.15.0', 9200, 'ELASTICSEARCH_URL'),
  DatastoreDef('rabbitmq', 'RabbitMQ', 'mq', Color(0xFFF59E0B), '3.13', 5672, 'RABBITMQ_URL'),
  DatastoreDef('meilisearch', 'Meilisearch', 'ms', Color(0xFFA78BFA), 'v1.9', 7700, 'MEILISEARCH_URL'),
];

DatastoreDef? datastoreOf(String type) => datastores.where((d) => d.type == type).firstOrNull;

class Service {
  const Service({required this.type, required this.name, required this.info});
  final String type;
  final String name;
  final Report info;

  String get key => '$type/$name';
  String get status => info['status'] ?? 'unknown';
  bool get running => status.toLowerCase().contains('running');
  String get version => info['version'] ?? '';
  String get exposed => info['exposed ports'] ?? '-';
  bool get isExposed => exposed.isNotEmpty && exposed != '-';
  List<String> get links =>
      (info['links'] ?? '').split(RegExp(r'[\s,]+')).where((x) => x.isNotEmpty && x != '-').toList();

  /// `redis:7.4` whether the plugin reports the image name or only the tag.
  String get image => version.contains(':') ? version : '$type:${version.isEmpty ? '?' : version}';
}

class DatastoreState {
  const DatastoreState(this.plugins, this.services);
  final List<PluginInfo> plugins;
  final List<Service> services;

  bool installed(String type) => plugins.any((p) => p.name == type && p.enabled);
  PluginInfo? plugin(String type) => plugins.where((p) => p.name == type).firstOrNull;
  bool get anyInstalled => datastores.any((d) => installed(d.type));
  List<DatastoreDef> get available => [for (final d in datastores) if (installed(d.type)) d];
}

/// Installed datastore plugins and every service they manage.
final datastoresProvider = FutureProvider.autoDispose.family<DatastoreState, String>((ref, hostId) async {
  ref.watch(generationProvider(hostId));
  final hosts = await ref.watch(hostsProvider.future);
  final Host host = hosts.firstWhere((h) => h.id == hostId, orElse: () => throw StateError('This host is no longer saved.'));
  final ssh = ref.watch(sshServiceProvider);

  final list = await ssh.dokku(host, ['plugin:list']);
  if (!list.ok) throw DokkuError(list);
  final plugins = parsePlugins(list.stdout);
  final types = [for (final d in datastores) if (plugins.any((p) => p.name == d.type && p.enabled)) d.type];
  if (types.isEmpty) return DatastoreState(plugins, const []);

  final lists = await ssh.dokkuAll(host, [for (final t in types) ['$t:list']]);
  final pairs = [
    for (final (i, t) in types.indexed)
      for (final name in parseServiceNames(lists[i].stdout)) (type: t, name: name),
  ];
  final infos = pairs.isEmpty ? <ExecResult>[] : await ssh.dokkuAll(host, [for (final p in pairs) ['${p.type}:info', p.name]]);
  return DatastoreState(plugins, [
    for (final (i, p) in pairs.indexed) Service(type: p.type, name: p.name, info: parseReport(infos[i].stdout)),
  ]);
});
