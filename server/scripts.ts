// Fixed shell scripts for hosts connected with a shell (non-dokku) user.
// These never interpolate user input.

const DOCKER = (sub: string) => `(docker ${sub} 2>/dev/null || sudo -n docker ${sub} 2>/dev/null)`;

export const METRICS_SCRIPT = `
echo "@@load"; cat /proc/loadavg
echo "@@nproc"; nproc
echo "@@stat1"; head -1 /proc/stat; sleep 0.5; echo "@@stat2"; head -1 /proc/stat
echo "@@mem"; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
echo "@@disk"; df -P -B1 / | tail -1
echo "@@uptime"; cat /proc/uptime
echo "@@stats"; ${DOCKER(`stats --no-stream --format '{{json .}}'`)}
echo "@@ps"; ${DOCKER(`ps -a --format '{{json .}}'`)}
echo "@@end"
`;

export const SYSTEM_SCRIPT = `
echo "@@os"; (. /etc/os-release && echo "$PRETTY_NAME")
echo "@@kernel"; uname -r
echo "@@arch"; uname -m
echo "@@hostname"; hostname
echo "@@docker"; ${DOCKER(`version --format '{{.Server.Version}}'`)}
echo "@@uptime"; cat /proc/uptime
echo "@@installer"; systemctl is-enabled dokku-installer 2>/dev/null || echo absent
echo "@@registries"; (cat /home/dokku/.docker/config.json 2>/dev/null || sudo -n cat /home/dokku/.docker/config.json 2>/dev/null) | grep -B1 '"auth"' | grep -oE '"[^"]+": *[{]' | cut -d'"' -f2
echo "@@end"
`;

export const PREFLIGHT_SCRIPT = `
echo "@@os"; (. /etc/os-release && echo "$ID|$VERSION_ID|$VERSION_CODENAME|$PRETTY_NAME")
echo "@@arch"; uname -m
echo "@@user"; id -un; id -u; (sudo -n true 2>/dev/null && echo sudo-ok) || echo sudo-no
echo "@@nginx"; if [ -d /etc/nginx/sites-enabled ]; then ls -1 /etc/nginx/sites-enabled | wc -l; else echo none; fi
echo "@@keys"; (grep -cE '^(ssh-|ecdsa-|sk-)' ~/.ssh/authorized_keys 2>/dev/null) || echo 0
echo "@@dokku"; (command -v dokku >/dev/null && dokku version 2>/dev/null) || echo none
echo "@@ip"; (hostname -I 2>/dev/null | awk '{print $1}')
echo "@@mem"; grep MemTotal /proc/meminfo
echo "@@end"
`;

export const UPGRADE_SCRIPT = `set -e
export DEBIAN_FRONTEND=noninteractive
echo "-----> Current: $(dokku version)"
echo "-----> apt-get update"
sudo -n apt-get update -qq
echo "-----> Upgrading dokku package"
sudo -n apt-get -qq -y install --only-upgrade dokku
echo "-----> Installing core plugin dependencies"
sudo -n dokku plugin:install-dependencies --core
echo "=====> Now running $(dokku version)"
`;

/** Splits "@@section" delimited output into a map of section → trimmed body. */
export function sections(out: string): Record<string, string> {
  const res: Record<string, string> = {};
  let cur = '';
  for (const line of out.split('\n')) {
    const m = /^@@(\w+)$/.exec(line.trim());
    if (m) { cur = m[1]; res[cur] = ''; continue; }
    if (cur) res[cur] += line + '\n';
  }
  for (const k of Object.keys(res)) res[k] = res[k].trim();
  return res;
}

const UNITS: Record<string, number> = { b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4 };
export function parseSize(s: string): number {
  const m = /^([\d.]+)\s*([a-z]+)?$/i.exec(s.trim());
  if (!m) return 0;
  return parseFloat(m[1]) * (UNITS[(m[2] ?? 'b').toLowerCase()] ?? 1);
}

export interface ContainerMetric {
  name: string; id: string; image: string; state: string; status: string;
  cpuPct: number | null; memBytes: number | null; memLimit: number | null;
}

export function parseMetrics(out: string) {
  const s = sections(out);
  const stat = (line: string) => line.split(/\s+/).slice(1).map(Number);
  const a = stat(s.stat1 ?? ''), b = stat(s.stat2 ?? '');
  const total = (x: number[]) => x.reduce((p, c) => p + (c || 0), 0);
  const idle = (x: number[]) => (x[3] || 0) + (x[4] || 0);
  const dt = total(b) - total(a);
  const cpuPct = dt > 0 ? Math.max(0, Math.min(100, (1 - (idle(b) - idle(a)) / dt) * 100)) : null;
  const mem: Record<string, number> = {};
  for (const line of (s.mem ?? '').split('\n')) {
    const m = /^(\w+):\s+(\d+)/.exec(line);
    if (m) mem[m[1]] = Number(m[2]) * 1024;
  }
  const df = (s.disk ?? '').split(/\s+/);
  const stats = new Map<string, { cpu: number; mem: number; limit: number }>();
  for (const line of (s.stats ?? '').split('\n')) {
    try {
      const j = JSON.parse(line);
      const [used, limit] = String(j.MemUsage ?? '').split('/').map((x: string) => parseSize(x));
      stats.set(j.Name, { cpu: parseFloat(j.CPUPerc), mem: used, limit });
    } catch { /* skip */ }
  }
  const containers: ContainerMetric[] = [];
  for (const line of (s.ps ?? '').split('\n')) {
    try {
      const j = JSON.parse(line);
      const st = stats.get(j.Names);
      containers.push({ name: j.Names, id: String(j.ID).slice(0, 12), image: j.Image, state: j.State, status: j.Status, cpuPct: st?.cpu ?? null, memBytes: st?.mem ?? null, memLimit: st?.limit ?? null });
    } catch { /* skip */ }
  }
  return {
    cpuPct,
    load: (s.load ?? '').split(/\s+/).slice(0, 3).map(Number),
    cores: Number(s.nproc) || null,
    mem: { total: mem.MemTotal ?? 0, available: mem.MemAvailable ?? 0 },
    swap: { total: mem.SwapTotal ?? 0, free: mem.SwapFree ?? 0 },
    disk: { device: df[0] ?? '', total: Number(df[1]) || 0, used: Number(df[2]) || 0, avail: Number(df[3]) || 0, mount: df[5] ?? '/' },
    uptimeSec: Number((s.uptime ?? '').split(/\s+/)[0]) || null,
    dockerAvailable: !!s.ps,
    containers,
  };
}

export type Metrics = ReturnType<typeof parseMetrics>;
