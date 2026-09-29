import { useQuery, useQueryClient } from '@tanstack/react-query';
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { ConnStatus } from '../../shared/types';
import { api, type HostWithStatus } from './api';

interface HostCtx {
  hosts: HostWithStatus[];
  loading: boolean;
  host: HostWithStatus | null;
  setHostId: (id: string) => void;
  status: ConnStatus & { checking?: boolean };
  reconnect: () => void;
  refreshHosts: () => void;
}

const Ctx = createContext<HostCtx | null>(null);
const KEY = 'dkc.host';

function readStored(): string | null {
  try { return localStorage.getItem(KEY); } catch { return null; }
}

export function HostProvider({ children }: { children: ReactNode }) {
  const qc = useQueryClient();
  const hostsQ = useQuery({ queryKey: ['hosts'], queryFn: api.hosts, staleTime: 30_000 });
  const [hostId, setHostIdState] = useState<string | null>(readStored);
  const hosts = useMemo(() => hostsQ.data ?? [], [hostsQ.data]);
  const host = hosts.find((h) => h.id === hostId) ?? hosts[0] ?? null;

  const setHostId = useCallback((id: string) => {
    setHostIdState(id);
    try { localStorage.setItem(KEY, id); } catch { /* ignore */ }
  }, []);

  const statusQ = useQuery({
    queryKey: ['status', host?.id],
    queryFn: () => api.status(host!.id),
    enabled: !!host,
    refetchInterval: (q) => (q.state.data?.state === 'connected' ? 20_000 : 6_000),
    retry: false,
  });

  const reconnect = useCallback(() => {
    statusQ.refetch().then(() => qc.invalidateQueries({ queryKey: ['dokku', host?.id] }));
  }, [statusQ, qc, host?.id]);

  // Refresh data after a dropped connection comes back.
  const state = statusQ.data?.state;
  useEffect(() => {
    if (state === 'connected') qc.invalidateQueries({ queryKey: ['dokku', host?.id], refetchType: 'active' });
  }, [state, qc, host?.id]);

  const status: HostCtx['status'] = statusQ.data
    ? { ...statusQ.data, checking: statusQ.isFetching }
    : { state: host ? 'connecting' : 'idle', checking: statusQ.isFetching };

  const value: HostCtx = {
    hosts, loading: hostsQ.isLoading, host, setHostId, status, reconnect,
    refreshHosts: () => qc.invalidateQueries({ queryKey: ['hosts'] }),
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useHost(): HostCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error('useHost outside HostProvider');
  return c;
}

/** Current host; only call inside views that render when a host exists. */
export function useCurrentHost(): HostWithStatus {
  const { host } = useHost();
  if (!host) throw new Error('no host selected');
  return host;
}
