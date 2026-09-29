import { useQuery } from '@tanstack/react-query';
import { api } from './api';
import { useHost } from './host';
import { parsePlugins, parseReports, parseServiceNames, type PluginInfo, type Report } from './parse';

export interface DatastoreDef {
  type: string; name: string; glyph: string; hue: string; version: string; port: number; repo: string; envVar: string;
}

export const DATASTORES: DatastoreDef[] = [
  { type: 'postgres', name: 'PostgreSQL', glyph: 'pg', hue: '#3b82f6', version: '17.2', port: 5432, repo: 'https://github.com/dokku/dokku-postgres.git', envVar: 'DATABASE_URL' },
  { type: 'redis', name: 'Redis', glyph: 'rd', hue: '#ef4444', version: '7.4', port: 6379, repo: 'https://github.com/dokku/dokku-redis.git', envVar: 'REDIS_URL' },
  { type: 'mysql', name: 'MySQL', glyph: 'my', hue: '#3b82f6', version: '8.4', port: 3306, repo: 'https://github.com/dokku/dokku-mysql.git', envVar: 'DATABASE_URL' },
  { type: 'mariadb', name: 'MariaDB', glyph: 'md', hue: '#22c55e', version: '11.4', port: 3306, repo: 'https://github.com/dokku/dokku-mariadb.git', envVar: 'DATABASE_URL' },
  { type: 'mongo', name: 'MongoDB', glyph: 'mg', hue: '#22c55e', version: '7.0', port: 27017, repo: 'https://github.com/dokku/dokku-mongo.git', envVar: 'MONGO_URL' },
  { type: 'elasticsearch', name: 'Elasticsearch', glyph: 'es', hue: '#f59e0b', version: '8.15.0', port: 9200, repo: 'https://github.com/dokku/dokku-elasticsearch.git', envVar: 'ELASTICSEARCH_URL' },
  { type: 'rabbitmq', name: 'RabbitMQ', glyph: 'mq', hue: '#f59e0b', version: '3.13', port: 5672, repo: 'https://github.com/dokku/dokku-rabbitmq.git', envVar: 'RABBITMQ_URL' },
  { type: 'meilisearch', name: 'Meilisearch', glyph: 'ms', hue: '#a78bfa', version: 'v1.9', port: 7700, repo: 'https://github.com/dokku/dokku-meilisearch.git', envVar: 'MEILISEARCH_URL' },
];

export interface Service {
  type: string;
  name: string;
  info: Report;
  links: string[];
  status: string;
  version: string;
  exposed: string;
  dsn: string;
}

export interface DatastoreState {
  plugins: PluginInfo[];
  installed: Set<string>;
  services: Service[];
}

export function useDatastores() {
  const { host } = useHost();
  return useQuery<DatastoreState, Error>({
    queryKey: ['dokku', host?.id, 'datastores'],
    enabled: !!host,
    staleTime: 15_000,
    queryFn: async () => {
      const id = host!.id;
      const [pl] = await api.batch(id, [['plugin:list']]);
      const plugins = parsePlugins(pl.stdout);
      const installed = new Set(plugins.filter((p) => p.enabled).map((p) => p.name));
      const types = DATASTORES.filter((d) => installed.has(d.type)).map((d) => d.type);
      if (!types.length) return { plugins, installed, services: [] };
      const lists = await api.batch(id, types.map((t) => [`${t}:list`]));
      const pairs = types.flatMap((t, i) => parseServiceNames(lists[i].stdout).map((name) => ({ type: t, name })));
      const infos = pairs.length ? await api.batch(id, pairs.map((p) => [`${p.type}:info`, p.name])) : [];
      const services = pairs.map((p, i) => {
        const info = Object.values(parseReports(infos[i].stdout))[0] ?? {};
        return {
          ...p, info,
          links: (info.links ?? '').split(/[\s,]+/).filter((x) => x && x !== '-'),
          status: info.status ?? 'unknown',
          version: info.version ?? '',
          exposed: info['exposed ports'] ?? '-',
          dsn: info.dsn ?? '',
        };
      });
      return { plugins, installed, services };
    },
  });
}

export const defOf = (type: string) => DATASTORES.find((d) => d.type === type);
