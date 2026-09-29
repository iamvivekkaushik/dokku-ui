import { useEffect, useSyncExternalStore } from 'react';

export type Route =
  | { view: 'dash' }
  | { view: 'apps' }
  | { view: 'app'; app: string; tab: AppTab }
  | { view: 'data' }
  | { view: 'monitor' }
  | { view: 'server' }
  | { view: 'install' };

export const APP_TABS = ['overview', 'deploys', 'build', 'scale', 'env', 'domains', 'storage', 'logs', 'settings'] as const;
export type AppTab = (typeof APP_TABS)[number];

export function parseHash(hash: string): Route {
  const parts = hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
  switch (parts[0]) {
    case 'apps':
      if (parts[1]) return { view: 'app', app: parts[1], tab: (APP_TABS as readonly string[]).includes(parts[2]) ? (parts[2] as AppTab) : 'overview' };
      return { view: 'apps' };
    case 'datastores': return { view: 'data' };
    case 'monitoring': return { view: 'monitor' };
    case 'server': return { view: 'server' };
    case 'install': return { view: 'install' };
    default: return { view: 'dash' };
  }
}

export function href(r: Route): string {
  switch (r.view) {
    case 'dash': return '#/';
    case 'apps': return '#/apps';
    case 'app': return `#/apps/${encodeURIComponent(r.app)}${r.tab === 'overview' ? '' : `/${r.tab}`}`;
    case 'data': return '#/datastores';
    case 'monitor': return '#/monitoring';
    case 'server': return '#/server';
    case 'install': return '#/install';
  }
}

export function navigate(r: Route) {
  const h = href(r);
  if (location.hash !== h) location.hash = h;
}

const subscribe = (cb: () => void) => {
  window.addEventListener('hashchange', cb);
  return () => window.removeEventListener('hashchange', cb);
};

export function useRoute(): Route {
  const hash = useSyncExternalStore(subscribe, () => location.hash);
  return parseHash(hash);
}

export function useTitle(title: string) {
  useEffect(() => { document.title = title ? `${title} · Dokku Console` : 'Dokku Console'; }, [title]);
}
