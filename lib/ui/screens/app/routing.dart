import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/format.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../data/platform.dart';
import '../../../state/queries.dart';
import '../../../state/router.dart';
import '../../actions.dart';
import '../../widgets/kit.dart';
import 'shared.dart';

const _proxies = ['nginx', 'caddy', 'traefik', 'haproxy', 'openresty'];
const _schemes = ['http', 'https', 'tcp', 'udp', 'grpc', 'grpcs'];

const _proxyNotes = {
  'nginx': 'The default. Vhost configs are kept in /home/dokku/<app>/nginx.conf and custom templates are supported.',
  'caddy': 'Automatic HTTPS through Caddy. Start it once with caddy:start after switching.',
  'traefik': 'Label-based routing with Traefik. Start it once with traefik:start after switching.',
  'haproxy': 'HAProxy through the haproxy-vhosts plugin. Works well for TCP.',
  'openresty': 'OpenResty (nginx with Lua) through the openresty-vhosts plugin.',
};

final _domainPattern = RegExp(r'^[a-z0-9*.-]+\.[a-z]{2,}$');
final _emailPattern = RegExp(r'^\S+@\S+\.\S+$');
/// Hands a web address to the browser. A provider so that tests can see what is opened.
final openUrlProvider = Provider<Future<void> Function(Uri url)>((_) => (url) async {
      try {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } on Object {
        // This device has nothing that opens web addresses.
      }
    });

class RoutingTab extends StatelessWidget {
  const RoutingTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context) => TwoCol(
        left: [_DomainsCard(host, app), _PortsCard(host, app)],
        right: [_CertificateCard(host, app), _ProxyCard(host, app)],
      );
}

class _DomainsCard extends ConsumerStatefulWidget {
  const _DomainsCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_DomainsCard> createState() => _DomainsCardState();
}

class _DomainsCardState extends ConsumerState<_DomainsCard> with Busy {
  final _domain = TextEditingController();

  @override
  void dispose() {
    _domain.dispose();
    super.dispose();
  }

  String get _typed => _domain.text.trim().toLowerCase();

  Future<void> _add() async {
    final domain = _typed;
    if (!_domainPattern.hasMatch(domain)) return;
    await busy('add', () async {
      final r = await runDokku(context, ref, widget.host, ['domains:add', widget.app, domain]);
      if (r?.ok == true) _domain.clear();
    });
  }

  static (String, Tone) _dnsStatus(AsyncValue<Map<String, DnsCheck>>? dns, String domain) {
    final check = dns?.value?[domain];
    if (check == null) return (dns != null && dns.hasError ? 'DNS could not be checked' : 'Checking DNS', Tone.mute);
    if (check.addresses.isEmpty) return ('No DNS record', Tone.bad);
    if (check.matches == true) return ('DNS ok', Tone.ok);
    return ('Resolves to ${check.addresses.first}${check.matches == false ? ', not this host' : ''}', Tone.warn);
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final dom = ref.report(host, 'domains', app);
    final certs = ref.report(host, 'certs', app);
    final domains = words(dom.data?['domains app vhosts']);
    final globalVhosts =
        ref.watch(appsProvider(host.id)).value?.globalVhosts ?? words(dom.data?['domains global vhosts']);
    final dns = domains.isEmpty ? null : ref.watch(dnsProvider(DnsQuery(host.id, domains)));
    final sslOn = isYes(certs.data?['ssl enabled']);
    final names = words(certs.data?['ssl hostnames']);
    bool covered(String d) => sslOn && names.any((n) => n == d || (n.startsWith('*.') && d.endsWith(n.substring(1))));
    final typed = _typed;

    return Panel.column(children: [
      PanelHead(
        'Domains',
        trailing: Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'global fallback: '),
            TextSpan(
              text: globalVhosts.isEmpty ? 'none' : globalVhosts.map((g) => '$app.$g').join(', '),
              style: T.mono(11, color: C.soft),
            ),
          ]),
          style: T.hint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      ?cardPlaceholder(dom, 'domains'),
      if (dom.data != null && domains.isEmpty)
        const EmptyBox('No domains yet. The app cannot be reached through the proxy until you add one.'),
      for (final (i, d) in domains.indexed)
        () {
          final tls = covered(d);
          final url = '${tls ? 'https' : 'http'}://$d';
          final (text, tone) = _dnsStatus(dns, d);
          final name = Text(d, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(13, weight: FontWeight.w500));
          return PanelRow(
            first: i == 0,
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  // A wildcard is a pattern, not an address that can be opened.
                  if (d.contains('*'))
                    name
                  else
                    Tooltip(
                      message: 'Open $url',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(onTap: () => ref.read(openUrlProvider)(Uri.parse(url)), child: name),
                      ),
                    ),
                  const SizedBox(height: 3),
                  Dot(text, tone: tone),
                ]),
              ),
              const SizedBox(width: 10),
              Pill(tls ? 'TLS' : 'no cert', tone: tls ? Tone.ok : Tone.warn, mono: true, dot: false),
              const SizedBox(width: 6),
              RemoveBtn(
                tooltip: 'Remove domain',
                busy: isBusy('remove $d'),
                onPressed: () => busy(
                  'remove $d',
                  () => runDokku(context, ref, host, ['domains:remove', app, d],
                      ask: Confirm(
                        title: 'Remove $d?',
                        body: 'The proxy stops routing this hostname to the app.',
                        label: 'Remove domain',
                        danger: true,
                      )),
                ),
              ),
            ]),
          );
        }(),
      PanelRow(
        tint: C.w(.02),
        child: Row(children: [
          Expanded(
            child: AppInput(
              controller: _domain,
              hint: 'app.example.com',
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          Btn('Add domain', loading: isBusy('add'), onPressed: _domainPattern.hasMatch(typed) ? _add : null),
        ]),
      ),
      CmdFooter(
        '${footerCommand(['domains:add', app, typed.isEmpty ? '<domain>' : typed])}  ·  domains:remove  ·  domains:report'
        '  ·  DNS should point at ${host.host}',
      ),
    ]);
  }
}

class _PortsCard extends ConsumerStatefulWidget {
  const _PortsCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_PortsCard> createState() => _PortsCardState();
}

class _PortsCardState extends ConsumerState<_PortsCard> with Busy {
  var _scheme = 'http';
  final _hostPort = TextEditingController();
  final _containerPort = TextEditingController();

  @override
  void dispose() {
    _hostPort.dispose();
    _containerPort.dispose();
    super.dispose();
  }

  static bool _isPort(String text) {
    final n = int.tryParse(text);
    return n != null && n > 0 && n < 65536;
  }

  bool get _valid => _isPort(_hostPort.text) && _isPort(_containerPort.text);

  Future<void> _add() async {
    if (!_valid) return;
    final mapping = '$_scheme:${_hostPort.text}:${_containerPort.text}';
    await busy('add', () async {
      final r = await runDokku(context, ref, widget.host, ['ports:add', widget.app, mapping]);
      if (r?.ok != true) return;
      _hostPort.clear();
      _containerPort.clear();
      _scheme = 'http';
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ports = ref.report(host, 'ports', app);
    final set = words(ports.data?['ports map']);
    final detected = words(ports.data?['ports map detected']);
    final shown = set.isNotEmpty ? set : detected;
    final action = 26 + touchPad(context);

    Widget port(TextEditingController c, String hint) => AppInput(
          controller: c,
          hint: hint,
          keyboardType: TextInputType.number,
          inputFormatters: digitsOnly,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _add(),
        );
    final scheme = AppSelect<String>(value: _scheme, options: _schemes, onChanged: (v) => setState(() => _scheme = v));
    final hostPort = port(_hostPort, '80'), containerPort = port(_containerPort, '5000');
    final add = Btn('Map port', loading: isBusy('add'), onPressed: _valid ? _add : null);

    return Panel.column(children: [
      const PanelHead('Ports', note: 'scheme : host → container'),
      THead([th('scheme', width: 80), th('host port'), th('container'), SizedBox(width: action)]),
      ?cardPlaceholder(ports, 'port mappings'),
      if (ports.data != null && shown.isEmpty)
        const EmptyBox('No port mappings yet. Dokku detects them on the first deploy.'),
      for (final raw in shown)
        () {
          final p = raw.split(':');
          return PanelRow(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Row(children: [
              SizedBox(
                width: 80,
                child: Text(p[0], maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: C.soft)),
              ),
              Expanded(child: Text(p.elementAtOrNull(1) ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code)),
              Expanded(
                child: Text(p.elementAtOrNull(2) ?? '',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: C.soft)),
              ),
              // A detected mapping is not set anywhere, so there is nothing to remove.
              if (set.isEmpty)
                SizedBox(width: action)
              else
                RemoveBtn(
                  tooltip: 'Remove mapping',
                  busy: isBusy('remove $raw'),
                  onPressed: () => busy('remove $raw', () => runDokku(context, ref, host, ['ports:remove', app, raw])),
                ),
            ]),
          );
        }(),
      if (set.isEmpty && detected.isNotEmpty)
        PanelRow(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
              'These mappings were detected, not set. Dokku applies them on each deploy until you map your own, '
              'which replaces them.',
              style: T.tiny),
        ),
      PanelRow(
        tint: C.w(.02),
        child: LayoutBuilder(builder: (context, box) {
          // Three fields and a button do not fit side by side on a phone.
          if (box.maxWidth < 420) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                SizedBox(width: 92, child: scheme),
                const SizedBox(width: 8),
                Expanded(child: hostPort),
                const SizedBox(width: 8),
                Expanded(child: containerPort),
              ]),
              const SizedBox(height: 8),
              add,
            ]);
          }
          return Row(children: [
            SizedBox(width: 80, child: scheme),
            const SizedBox(width: 8),
            Expanded(child: hostPort),
            const SizedBox(width: 8),
            Expanded(child: containerPort),
            const SizedBox(width: 8),
            add,
          ]);
        }),
      ),
      CmdFooter(
        '${footerCommand([
              'ports:add',
              app,
              '$_scheme:${_hostPort.text.isEmpty ? '<host>' : _hostPort.text}:${_containerPort.text.isEmpty ? '<container>' : _containerPort.text}',
            ])}  ·  ports:remove  ·  ports:clear',
      ),
    ]);
  }
}

class _CertificateCard extends ConsumerStatefulWidget {
  const _CertificateCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_CertificateCard> createState() => _CertificateCardState();
}

class _CertificateCardState extends ConsumerState<_CertificateCard> with Busy {
  final _email = SyncedController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _enable(String currentEmail) async {
    final host = widget.host, app = widget.app;
    final email = _email.text.trim();
    if (!_emailPattern.hasMatch(email)) return;
    await busy('le', () async {
      final run = DokkuRunner(ref, host);
      if (email != currentEmail) {
        final r = await run(['letsencrypt:set', app, 'email', email]);
        if (!r.ok) return;
      }
      final r = await run(['letsencrypt:enable', app], title: 'Let\'s Encrypt for $app', timeout: const Duration(minutes: 10));
      if (!r.ok) return;
      // The certificate is already issued; a missing cron job is not worth an error dialog.
      await run(['letsencrypt:cron-job', '--add'], title: 'Schedule certificate renewal', quiet: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final certs = ref.report(host, 'certs', app);
    final domains = words(ref.report(host, 'domains', app).data?['domains app vhosts']);
    final le = ref.dokku(host, ['letsencrypt:report', app],
        (r) => (installed: r.ok && !notSupported(r.output), report: parseLetsencrypt(r.stdout)),
        lenient: true);
    final leList = ref.dokku(host, ['letsencrypt:list'],
        (r) => (installed: r.ok && !notSupported(r.output), lines: parseLines(r.stdout)),
        lenient: true);

    final sslOn = isYes(certs.data?['ssl enabled']);
    final expires = certs.data?['ssl expires at'] ?? '';
    final days = daysUntil(expires);
    final expired = days != null && days < 0;
    final tone = !sslOn
        ? Tone.warn
        : days != null && days < 14
            ? Tone.bad
            : days != null && days < 30
                ? Tone.warn
                : Tone.ok;
    final status = !sslOn
        ? 'no certificate'
        : expired
            ? 'expired'
            : days != null
                ? 'valid · ${days}d'
                : 'valid';

    final report = le.data?.report ?? const <String, String>{};
    final leInstalled = (le.data?.installed ?? false) || (leList.data?.installed ?? false);
    final leLoading = !leInstalled && (le.loading || leList.loading);
    final leActive = report['active'] == 'true' || (leList.data?.lines ?? const []).any((l) => words(l).firstOrNull == app);
    final currentEmail = report['computed email'] ?? '';
    if (le.data != null) {
      _email.sync([currentEmail, report['email'], report['global email']].firstWhere((e) => e != null && e.isNotEmpty, orElse: () => '')!);
    }
    final email = _email.text.trim();
    final canEnable = _emailPattern.hasMatch(email) && domains.isNotEmpty;
    final renews = report['expiration'] ?? '';

    final String footer;
    if (!leInstalled) {
      footer = '${footerCommand(['certs:add', app])} < cert-key.tar  ·  certs:report $app';
    } else if (leActive) {
      footer = '${footerCommand(['letsencrypt:auto-renew', app])}  ·  letsencrypt:disable $app';
    } else if (email.isNotEmpty && email != currentEmail) {
      footer = '${footerCommand(['letsencrypt:set', app, 'email', email])}  ·  letsencrypt:enable $app';
    } else {
      footer = '${footerCommand(['letsencrypt:enable', app])}  ·  letsencrypt:auto-renew $app';
    }

    return Panel.column(children: [
      PanelHead('Certificate',
          trailing: certs.data == null ? null : Pill(status, tone: tone, mono: true, dot: false)),
      cardPlaceholder(certs, 'the certificate') ??
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: KVList([
              ('Issuer', _or(certs.data?['ssl issuer'])),
              (
                'Expires',
                expires.isEmpty
                    ? '—'
                    : days == null
                        ? expires
                        : expired
                            ? '$expires · expired ${-days} days ago'
                            : '$expires · in $days days',
              ),
              ('SANs', _or(certs.data?['ssl hostnames'])),
              ('Verified', _or(certs.data?['ssl verified'])),
            ]),
          ),
      PanelRow(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (leLoading)
            const Skeleton(height: 14)
          else if (leInstalled) ...[
            SwitchRow(
              title: 'Let\'s Encrypt',
              desc: leActive
                  ? 'Managed by the letsencrypt plugin${renews.isEmpty ? '' : ' · renews before ${dateOnly(renews, fallback: renews)}'}'
                  : 'Issue and renew a free certificate for the domains of this app.',
              value: leActive,
              busy: isBusy('le'),
              onChanged: leActive
                  ? (_) => busy(
                        'le',
                        () => runDokku(context, ref, host, ['letsencrypt:disable', app],
                            ask: const Confirm(
                              title: 'Disable Let\'s Encrypt?',
                              body: 'The certificate is removed and the app falls back to HTTP.',
                              label: 'Disable',
                              danger: true,
                            )),
                      )
                  : (canEnable ? (_) => _enable(currentEmail) : null),
            ),
            const SizedBox(height: 12),
            if (!leActive) ...[
              Row(children: [
                Expanded(
                  child: AppInput(
                    controller: _email.controller,
                    hint: 'ops@example.com',
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Btn('Enable',
                    variant: BtnVariant.primary,
                    loading: isBusy('le'),
                    onPressed: canEnable ? () => _enable(currentEmail) : null),
              ]),
              const SizedBox(height: 5),
              Text(
                domains.isEmpty
                    ? 'Add a domain first. Let\'s Encrypt issues certificates for the domains of the app.'
                    : 'Let\'s Encrypt needs an email address for expiry notices.',
                style: T.tiny,
              ),
            ] else
              Wrap(spacing: 6, runSpacing: 6, children: [
                Btn('Renew now',
                    loading: isBusy('renew'),
                    onPressed: () => busy(
                        'renew',
                        () => runDokku(context, ref, host, ['letsencrypt:auto-renew', app],
                            timeout: const Duration(minutes: 10)))),
                Btn('Schedule auto-renew',
                    loading: isBusy('cron'),
                    onPressed: () => busy('cron', () => runDokku(context, ref, host, ['letsencrypt:cron-job', '--add']))),
              ]),
          ] else ...[
            Text('The letsencrypt plugin is not installed. Install it from the Server page, under Plugins, to issue free certificates.',
                style: T.hint),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: LinkText('Open the Server page',
                  style: T.hint, onTap: () => ref.read(routerProvider.notifier).section(const ServerRoute())),
            ),
          ],
          const SizedBox(height: 12),
          Container(height: 1, color: C.lineSoft),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Custom certificate', style: T.body),
                const SizedBox(height: 2),
                Text('Upload server.crt and server.key (PEM)', style: T.hint),
              ]),
            ),
            const SizedBox(width: 12),
            Btn('Upload', onPressed: () => showAppDialog<void>(context, (_) => _CertificateDialog(host, app))),
            const SizedBox(width: 6),
            Btn('Remove',
                variant: BtnVariant.dangerGhost,
                loading: isBusy('remove'),
                onPressed: sslOn
                    ? () => busy(
                          'remove',
                          () => runDokku(context, ref, host, ['certs:remove', app],
                              ask: const Confirm(
                                title: 'Remove certificate?',
                                body: 'HTTPS stops working for this app until a new certificate is added.',
                                label: 'Remove certificate',
                                danger: true,
                              )),
                        )
                    : null),
          ]),
        ]),
      ),
      CmdFooter(footer),
    ]);
  }

  static String _or(String? v) => v == null || v.isEmpty ? '—' : v;
}

class _CertificateDialog extends ConsumerStatefulWidget {
  const _CertificateDialog(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_CertificateDialog> createState() => _CertificateDialogState();
}

class _CertificateDialogState extends ConsumerState<_CertificateDialog> with Busy {
  final _crt = TextEditingController();
  final _key = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _crt.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _pick(TextEditingController into) async {
    try {
      final file = await pickTextFile();
      if (file == null || !mounted) return;
      setState(() {
        into.text = file.text;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e is FormatException ? e.message : 'That file could not be read.');
    }
  }

  Future<void> _install() async {
    final r = await busy(
      'install',
      () => runDokku(context, ref, widget.host, ['certs:add', widget.app],
          files: {'server.crt': _crt.text, 'server.key': _key.text}, title: 'Install certificate'),
    );
    if (r?.ok == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _crt.text.contains('BEGIN CERTIFICATE') && _key.text.contains('PRIVATE KEY');

    Widget pem(String label, TextEditingController c, String hint) => Field(
          label,
          trailing: Btn('Choose file', size: BtnSize.xs, onPressed: () => _pick(c)),
          child: AppInput(controller: c, hint: hint, minLines: 6, maxLines: 6, onChanged: (_) => setState(() {})),
        );

    return AppDialog(
      title: 'Upload certificate',
      width: 560,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Install certificate',
            size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('install'), onPressed: valid ? _install : null),
      ],
      children: [
        pem('server.crt (PEM, full chain)', _crt, '-----BEGIN CERTIFICATE-----'),
        pem('server.key (PEM)', _key, '-----BEGIN PRIVATE KEY-----'),
        if (_error != null) Text(_error!, style: T.sans(12, color: C.bad, height: 1.45)),
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'Both files are sent as one archive on standard input: '),
            TextSpan(text: 'dokku certs:add ${widget.app} < cert-key.tar', style: T.mono(10.5, color: C.muted)),
          ]),
          style: T.tiny,
        ),
      ],
    );
  }
}

class _ProxyCard extends ConsumerStatefulWidget {
  const _ProxyCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_ProxyCard> createState() => _ProxyCardState();
}

class _ProxyCardState extends ConsumerState<_ProxyCard> with Busy {
  /// Changes an nginx property, then rebuilds the config so it takes effect.
  Future<void> _nginx(String key, String property, bool value) => busy(key, () async {
        final app = widget.app;
        final run = DokkuRunner(ref, widget.host);
        final r = await run(['nginx:set', app, property, '$value']);
        if (r.ok) await run(['proxy:build-config', app], title: 'Rebuild nginx config');
      });

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final proxy = ref.report(host, 'proxy', app);
    final type = proxy.data?['proxy type'] ?? '';
    final computed = proxy.data?['proxy computed type'] ?? '';
    final effective = computed.isEmpty ? 'nginx' : computed;
    final on = isYes(proxy.data?['proxy enabled']);
    final nginx = proxy.data != null && effective == 'nginx' ? ref.report(host, 'nginx', app).data : null;
    final hsts = isYes(nginx?['nginx computed hsts']);

    return Panel.column(children: [
      PanelHead(
        'Reverse proxy',
        trailing: HeadSwitch(
          label: 'Reverse proxy',
          value: on,
          busy: isBusy('enabled'),
          onChanged: proxy.data == null
              ? null
              : (v) => busy(
                    'enabled',
                    () => runDokku(context, ref, host, [v ? 'proxy:enable' : 'proxy:disable', app],
                        ask: v
                            ? null
                            : const Confirm(
                                title: 'Disable the proxy?',
                                body: 'Domains stop routing to this app. Its containers can then only be reached on their published ports.',
                                label: 'Disable proxy',
                                danger: true,
                              )),
                  ),
        ),
      ),
      cardPlaceholder(proxy, 'proxy settings') ??
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Seg<String>(
                value: effective,
                options: _proxies,
                onChanged: isBusy('type')
                    ? null
                    : (v) {
                        if (v == type) return;
                        busy(
                          'type',
                          () => runDokku(context, ref, host, ['proxy:set', app, v],
                              ask: Confirm(
                                title: 'Switch proxy to $v?',
                                body: 'Routing is rebuilt with the $v plugin.'
                                    '${v == 'nginx' ? '' : ' Its service has to be started once with $v:start.'}',
                                label: 'Switch proxy',
                              )),
                        );
                      },
              ),
              const SizedBox(height: 10),
              Text('${_proxyNotes[effective] ?? 'A custom proxy plugin.'}${type.isEmpty ? ' (using the global default)' : ''}',
                  style: T.hint),
              if (nginx != null) ...[
                const SizedBox(height: 10),
                Container(height: 1, color: C.lineSoft),
                const SizedBox(height: 10),
                SwitchRow(
                  title: 'HSTS',
                  desc: 'max-age ${nginx['nginx computed hsts max age'] ?? ''}',
                  value: hsts,
                  busy: isBusy('hsts'),
                  onChanged: (v) => _nginx('hsts', 'hsts', v),
                ),
                const SizedBox(height: 8),
                SwitchRow(
                  title: 'HSTS include subdomains',
                  value: isYes(nginx['nginx computed hsts include subdomains']),
                  busy: isBusy('hsts-subdomains'),
                  onChanged: (v) => _nginx('hsts-subdomains', 'hsts-include-subdomains', v),
                ),
                const SizedBox(height: 8),
                SwitchRow(
                  title: 'HSTS preload',
                  value: isYes(nginx['nginx computed hsts preload']),
                  busy: isBusy('hsts-preload'),
                  onChanged: (v) => _nginx('hsts-preload', 'hsts-preload', v),
                ),
                const SizedBox(height: 8),
                Text(
                  'HTTP is redirected to HTTPS whenever a certificate is installed. '
                  'Largest request body: ${nginx['nginx computed client max body size'] ?? ''}.',
                  style: T.tiny,
                ),
              ],
            ]),
          ),
      CmdFooter(
        '${footerCommand(['proxy:set', app, effective])}  ·  proxy:${on ? 'disable' : 'enable'} $app'
        '${effective == 'nginx' ? '  ·  nginx:set $app hsts ${!hsts}' : ''}',
      ),
    ]);
  }
}
