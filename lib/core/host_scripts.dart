/// Fixed shell scripts for hosts connected with a shell (non-dokku) user.
/// These never interpolate user input.
library;

import 'dart:convert';

/// Put in front of a script that calls `sudo`, so that it also runs as root on
/// a server that does not have sudo installed, as minimal Debian images do not.
const sudoShim = r'''if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do shift; done; env "$@"; }
fi
''';

String _docker(String sub) => '(docker $sub 2>/dev/null || sudo -n docker $sub 2>/dev/null)';

final metricsScript = '''
echo "@@load"; cat /proc/loadavg
echo "@@nproc"; nproc
echo "@@stat1"; head -1 /proc/stat; sleep 0.5; echo "@@stat2"; head -1 /proc/stat
echo "@@mem"; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
echo "@@disk"; df -P -B1 / | tail -1
echo "@@uptime"; cat /proc/uptime
echo "@@stats"; ${_docker("stats --no-stream --format '{{json .}}'")}
echo "@@ps"; ${_docker("ps -a --format '{{json .}}'")}
echo "@@end"
''';

final systemScript = '''
echo "@@os"; (. /etc/os-release && echo "\$PRETTY_NAME")
echo "@@kernel"; uname -r
echo "@@arch"; uname -m
echo "@@hostname"; hostname
echo "@@docker"; ${_docker("version --format '{{.Server.Version}}'")}
echo "@@uptime"; cat /proc/uptime
echo "@@installer"; systemctl is-enabled dokku-installer 2>/dev/null || echo absent
echo "@@registries"; (cat /home/dokku/.docker/config.json 2>/dev/null || sudo -n cat /home/dokku/.docker/config.json 2>/dev/null) | grep -B1 '"auth"' | grep -oE '"[^"]+": *[{]' | cut -d'"' -f2
echo "@@end"
''';

const preflightScript = r'''
echo "@@os"; (. /etc/os-release && echo "$ID|$VERSION_ID|$VERSION_CODENAME|$PRETTY_NAME")
echo "@@arch"; uname -m
echo "@@user"; id -un; id -u; (sudo -n true 2>/dev/null && echo sudo-ok) || echo sudo-no
echo "@@nginx"; if [ -d /etc/nginx/sites-enabled ]; then ls -1 /etc/nginx/sites-enabled | wc -l; else echo none; fi
echo "@@keys"; (grep -cE '^(ssh-|ecdsa-|sk-)' ~/.ssh/authorized_keys 2>/dev/null) || echo 0
echo "@@dokku"; (command -v dokku >/dev/null && dokku version 2>/dev/null) || echo none
echo "@@ip"; (hostname -I 2>/dev/null | awk '{print $1}')
echo "@@mem"; grep MemTotal /proc/meminfo
echo "@@end"
''';

const upgradeScript = r'''set -e
export DEBIAN_FRONTEND=noninteractive
echo "-----> Current: $(dokku version)"
echo "-----> apt-get update"
sudo -n apt-get update -qq
echo "-----> Upgrading dokku package"
sudo -n apt-get -qq -y install --only-upgrade dokku
echo "-----> Installing core plugin dependencies"
sudo -n dokku plugin:install-dependencies --core
echo "=====> Now running $(dokku version)"
''';

/// One line per third-party plugin: its name, the commit it is at and the tip
/// of the branch it tracks, which is what `plugin:update` pulls. A detached
/// checkout is `pinned`, since a pull would not move it; a clone that cannot be
/// read or reached is `error`. The clones belong to the dokku user, so git is
/// told to trust them whoever runs this. Core plugins are not clones.
const pluginUpdatesScript = r'''for d in /var/lib/dokku/plugins/available/*/; do
  [ -d "$d/.git" ] || continue
  n=$(basename "$d")
  g="git -c safe.directory=* -c safe.directory=${d%/} -C $d"
  head=$($g rev-parse HEAD 2>/dev/null) || { echo "$n error"; continue; }
  branch=$($g rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then echo "$n pinned $head"; continue; fi
  remote=$(timeout 20 $g ls-remote --quiet origin "refs/heads/$branch" 2>/dev/null | cut -f1)
  echo "$n $head ${remote:-error}"
done
echo "@@end"
''';

/// Whether a plugin's origin has moved on since it was installed or updated.
enum PluginState {
  current,
  outdated,

  /// Not checked, or the check failed for this plugin or could not reach its origin.
  unknown,
}

/// Plugin name to state, from [pluginUpdatesScript] output.
Map<String, PluginState> parsePluginUpdates(String out) {
  final res = <String, PluginState>{};
  for (final line in out.split('\n')) {
    final f = line.trim().split(_ws);
    if (f.length < 2 || f[0].startsWith('@@')) continue;
    res[f[0]] = switch (f[1]) {
      'error' => PluginState.unknown,
      'pinned' => PluginState.current,
      _ when f.length < 3 || f[2] == 'error' => PluginState.unknown,
      _ => f[1] == f[2] ? PluginState.current : PluginState.outdated,
    };
  }
  return res;
}

final _marker = RegExp(r'^@@(\w+)$');

/// Splits "@@section" delimited output into section → trimmed body.
Map<String, String> sections(String out) {
  final res = <String, StringBuffer>{};
  StringBuffer? cur;
  for (final line in out.split('\n')) {
    final m = _marker.firstMatch(line.trim());
    if (m != null) {
      cur = res[m[1]!] = StringBuffer();
      continue;
    }
    cur?.writeln(line);
  }
  return res.map((k, v) => MapEntry(k, v.toString().trim()));
}

const _units = <String, num>{
  'b': 1, 'kb': 1e3, 'mb': 1e6, 'gb': 1e9, 'tb': 1e12,
  'kib': 1024, 'mib': 1048576, 'gib': 1073741824, 'tib': 1099511627776,
};
final _size = RegExp(r'^([\d.]+)\s*([a-z]+)?$', caseSensitive: false);

double parseSize(String s) {
  final m = _size.firstMatch(s.trim());
  if (m == null) return 0;
  return double.parse(m[1]!) * (_units[(m[2] ?? 'b').toLowerCase()] ?? 1);
}

class ContainerMetric {
  const ContainerMetric({
    required this.name,
    required this.id,
    required this.image,
    required this.state,
    required this.status,
    this.cpuPct,
    this.memBytes,
    this.memLimit,
  });
  final String name;
  final String id;
  final String image;
  final String state;
  final String status;
  final double? cpuPct;
  final double? memBytes;
  final double? memLimit;

  bool get running => state == 'running';
}

class HostMetrics {
  const HostMetrics({
    required this.cpuPct,
    required this.load,
    required this.cores,
    required this.memTotal,
    required this.memAvailable,
    required this.swapTotal,
    required this.swapFree,
    required this.diskDevice,
    required this.diskTotal,
    required this.diskUsed,
    required this.diskAvail,
    required this.diskMount,
    required this.uptimeSec,
    required this.dockerAvailable,
    required this.containers,
    required this.at,
  });
  final double? cpuPct;
  final List<double> load;
  final int? cores;
  final double memTotal;
  final double memAvailable;
  final double swapTotal;
  final double swapFree;
  final String diskDevice;
  final double diskTotal;
  final double diskUsed;
  final double diskAvail;
  final String diskMount;
  final double? uptimeSec;
  final bool dockerAvailable;
  final List<ContainerMetric> containers;
  final DateTime at;
}

final _ws = RegExp(r'\s+');
final _memRow = RegExp(r'^(\w+):\s+(\d+)');

HostMetrics parseMetrics(String out, {DateTime? at}) {
  final s = sections(out);
  List<double> stat(String line) =>
      line.split(_ws).skip(1).map((x) => double.tryParse(x) ?? 0).toList();
  double total(List<double> x) => x.fold(0, (p, c) => p + c);
  double idle(List<double> x) => (x.length > 3 ? x[3] : 0) + (x.length > 4 ? x[4] : 0);

  final a = stat(s['stat1'] ?? ''), b = stat(s['stat2'] ?? '');
  final dt = total(b) - total(a);
  final cpu = dt > 0 ? ((1 - (idle(b) - idle(a)) / dt) * 100).clamp(0, 100).toDouble() : null;

  final mem = <String, double>{};
  for (final line in (s['mem'] ?? '').split('\n')) {
    final m = _memRow.firstMatch(line);
    if (m != null) mem[m[1]!] = double.parse(m[2]!) * 1024;
  }

  final df = (s['disk'] ?? '').split(_ws);
  double dfAt(int i) => i < df.length ? double.tryParse(df[i]) ?? 0 : 0;

  final stats = <String, ({double? cpu, double mem, double limit})>{};
  for (final line in (s['stats'] ?? '').split('\n')) {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      final usage = '${j['MemUsage'] ?? ''}'.split('/').map(parseSize).toList();
      stats['${j['Name']}'] = (
        cpu: double.tryParse('${j['CPUPerc']}'.replaceAll('%', '')),
        mem: usage.isNotEmpty ? usage[0] : 0,
        limit: usage.length > 1 ? usage[1] : 0,
      );
    } on Object {
      // not a JSON line
    }
  }

  final containers = <ContainerMetric>[];
  for (final line in (s['ps'] ?? '').split('\n')) {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      final st = stats['${j['Names']}'];
      final id = '${j['ID']}';
      containers.add(ContainerMetric(
        name: '${j['Names']}',
        id: id.length > 12 ? id.substring(0, 12) : id,
        image: '${j['Image']}',
        state: '${j['State']}',
        status: '${j['Status']}',
        cpuPct: st?.cpu,
        memBytes: st?.mem,
        memLimit: st?.limit,
      ));
    } on Object {
      // not a JSON line
    }
  }

  return HostMetrics(
    cpuPct: cpu,
    load: (s['load'] ?? '').split(_ws).take(3).map((x) => double.tryParse(x) ?? 0).toList(),
    cores: int.tryParse(s['nproc'] ?? ''),
    memTotal: mem['MemTotal'] ?? 0,
    memAvailable: mem['MemAvailable'] ?? 0,
    swapTotal: mem['SwapTotal'] ?? 0,
    swapFree: mem['SwapFree'] ?? 0,
    diskDevice: df.isNotEmpty ? df[0] : '',
    diskTotal: dfAt(1),
    diskUsed: dfAt(2),
    diskAvail: dfAt(3),
    diskMount: df.length > 5 ? df[5] : '/',
    uptimeSec: double.tryParse((s['uptime'] ?? '').split(_ws).first),
    dockerAvailable: (s['ps'] ?? '').isNotEmpty,
    containers: containers,
    at: at ?? DateTime.now(),
  );
}
