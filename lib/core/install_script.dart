/// Generates the Dokku install script shown in the install wizard. Options are
/// validated and every value is quoted, so choices can never inject shell.
library;

import 'command.dart';

enum InstallMethod { bootstrap, apt, source }

enum VersionMode { tag, branch }

enum KeyMode { authorizedKeys, paste }

enum DomainMode { custom, ip, sslip }

class InstallOptions {
  const InstallOptions({
    this.method = InstallMethod.bootstrap,
    this.versionMode = VersionMode.tag,
    this.dokkuTag = 'v0.35.20',
    this.dokkuBranch = 'master',
    this.sourceRepo = 'https://github.com/dokku/dokku.git',
    this.noRecommends = false,
    this.vhost = true,
    this.hostname = '',
    this.skipKey = false,
    this.keyFile = '/root/.ssh/authorized_keys',
    this.nginx = true,
    this.keyMode = KeyMode.authorizedKeys,
    this.keyName = 'admin',
    this.publicKey = '',
    this.domainMode = DomainMode.sslip,
    this.globalDomain = '',
    this.serverIp = '',
    this.disableInstaller = true,
    this.letsencrypt = true,
    this.createFirst = false,
    this.firstApp = 'hello-world',
  });

  final InstallMethod method;
  final VersionMode versionMode;
  final String dokkuTag;
  final String dokkuBranch;
  final String sourceRepo;
  final bool noRecommends;
  final bool vhost;
  final String hostname;
  final bool skipKey;
  final String keyFile;
  final bool nginx;
  final KeyMode keyMode;
  final String keyName;
  final String publicKey;
  final DomainMode domainMode;
  final String globalDomain;
  final String serverIp;
  final bool disableInstaller;
  final bool letsencrypt;
  final bool createFirst;
  final String firstApp;

  InstallOptions copyWith({
    InstallMethod? method,
    VersionMode? versionMode,
    String? dokkuTag,
    String? dokkuBranch,
    String? sourceRepo,
    bool? noRecommends,
    bool? vhost,
    String? hostname,
    bool? skipKey,
    String? keyFile,
    bool? nginx,
    KeyMode? keyMode,
    String? keyName,
    String? publicKey,
    DomainMode? domainMode,
    String? globalDomain,
    String? serverIp,
    bool? disableInstaller,
    bool? letsencrypt,
    bool? createFirst,
    String? firstApp,
  }) =>
      InstallOptions(
        method: method ?? this.method,
        versionMode: versionMode ?? this.versionMode,
        dokkuTag: dokkuTag ?? this.dokkuTag,
        dokkuBranch: dokkuBranch ?? this.dokkuBranch,
        sourceRepo: sourceRepo ?? this.sourceRepo,
        noRecommends: noRecommends ?? this.noRecommends,
        vhost: vhost ?? this.vhost,
        hostname: hostname ?? this.hostname,
        skipKey: skipKey ?? this.skipKey,
        keyFile: keyFile ?? this.keyFile,
        nginx: nginx ?? this.nginx,
        keyMode: keyMode ?? this.keyMode,
        keyName: keyName ?? this.keyName,
        publicKey: publicKey ?? this.publicKey,
        domainMode: domainMode ?? this.domainMode,
        globalDomain: globalDomain ?? this.globalDomain,
        serverIp: serverIp ?? this.serverIp,
        disableInstaller: disableInstaller ?? this.disableInstaller,
        letsencrypt: letsencrypt ?? this.letsencrypt,
        createFirst: createFirst ?? this.createFirst,
        firstApp: firstApp ?? this.firstApp,
      );
}

enum ScriptLineKind { comment, cmd, emph, warn, blank }

class ScriptLine {
  const ScriptLine(this.text, this.kind);
  final String text;
  final ScriptLineKind kind;
}

final _tag = RegExp(r'^v?\d+\.\d+\.\d+$');
final _branch = RegExp(r'^[A-Za-z0-9._/-]{1,100}$');
final _name = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final _domain = RegExp(r'^[A-Za-z0-9.-]{1,253}$');
final _ip = RegExp(r'^[0-9a-fA-F.:]+$');
final _path = RegExp(r'^/[\w./-]+$');
final _repo = RegExp(r'''^https://[^\s'"]+\.git$''');
final publicKeyPattern =
    RegExp(r'^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( [^\n]*)?$');

List<String> validateInstallOptions(InstallOptions o) {
  final errs = <String>[];
  final bootstrap = o.method == InstallMethod.bootstrap;
  if (bootstrap && o.versionMode == VersionMode.tag && !_tag.hasMatch(o.dokkuTag)) {
    errs.add('DOKKU_TAG must look like v0.35.20');
  }
  if (bootstrap && o.versionMode == VersionMode.branch && !_branch.hasMatch(o.dokkuBranch)) {
    errs.add('invalid branch name');
  }
  if (o.method == InstallMethod.source && !_repo.hasMatch(o.sourceRepo)) {
    errs.add('source repo must be an https .git URL');
  }
  if (o.hostname.isNotEmpty && !_domain.hasMatch(o.hostname)) errs.add('invalid hostname');
  if (!_name.hasMatch(o.keyName)) errs.add('key name must be lowercase letters, digits and dashes');
  if (o.keyMode == KeyMode.paste && !publicKeyPattern.hasMatch(o.publicKey.trim())) {
    errs.add('public key must be a single OpenSSH public key line');
  }
  if (o.domainMode == DomainMode.custom && !_domain.hasMatch(o.globalDomain)) errs.add('invalid global domain');
  if (o.domainMode != DomainMode.custom && !_ip.hasMatch(o.serverIp)) errs.add('server IP unknown');
  if (o.createFirst && !_name.hasMatch(o.firstApp)) errs.add('invalid first app name');
  if (!o.skipKey && o.method == InstallMethod.apt && !_path.hasMatch(o.keyFile)) errs.add('invalid key file path');
  return errs;
}

String globalDomainFor(InstallOptions o) => switch (o.domainMode) {
      DomainMode.custom => o.globalDomain.isEmpty ? 'dokku.me' : o.globalDomain,
      DomainMode.ip => o.serverIp,
      DomainMode.sslip => '${o.serverIp}.sslip.io',
    };

List<ScriptLine> buildInstallScript(InstallOptions o) {
  final out = <ScriptLine>[];
  void c(String text) => out.add(ScriptLine('# $text', ScriptLineKind.comment));
  void l(String text, [ScriptLineKind kind = ScriptLineKind.cmd]) => out.add(ScriptLine(text, kind));
  void blank() => out.add(const ScriptLine('', ScriptLineKind.blank));
  void debconf(String key, String type, String value) =>
      l('echo ${shq('dokku dokku/$key $type $value')} | sudo debconf-set-selections');
  final hostname = o.hostname.isEmpty ? globalDomainFor(o) : o.hostname;

  l('#!/usr/bin/env bash', ScriptLineKind.comment);
  l('set -euo pipefail', ScriptLineKind.comment);
  l('export DEBIAN_FRONTEND=noninteractive', ScriptLineKind.comment);
  blank();

  switch (o.method) {
    case InstallMethod.bootstrap:
      c('install dokku via bootstrap.sh');
      debconf('vhost_enable', 'boolean', '${o.vhost}');
      debconf('hostname', 'string', hostname);
      debconf('nginx_enable', 'boolean', '${o.nginx}');
      final env = <String>[];
      if (o.versionMode == VersionMode.tag) {
        final tag = o.dokkuTag.startsWith('v') ? o.dokkuTag : 'v${o.dokkuTag}';
        l('wget -NP . ${shq('https://dokku.com/install/$tag/bootstrap.sh')}');
        env.add('DOKKU_TAG=${shq(tag)}');
      } else {
        l('wget -NP . https://raw.githubusercontent.com/dokku/dokku/master/bootstrap.sh');
        env.add('DOKKU_BRANCH=${shq(o.dokkuBranch)}');
      }
      if (o.noRecommends) env.add('DOKKU_NO_INSTALL_RECOMMENDS=true');
      l('sudo ${env.join(' ')} bash bootstrap.sh', ScriptLineKind.emph);
    case InstallMethod.apt:
      c('unattended install: debconf + apt');
      debconf('vhost_enable', 'boolean', '${o.vhost}');
      debconf('hostname', 'string', hostname);
      debconf('skip_key_file', 'boolean', '${o.skipKey}');
      if (!o.skipKey) debconf('key_file', 'string', o.keyFile);
      debconf('nginx_enable', 'boolean', '${o.nginx}');
      l('command -v docker >/dev/null || wget -nv -O - https://get.docker.com/ | sudo sh');
      l('wget -qO- https://packagecloud.io/dokku/dokku/gpgkey | sudo tee /etc/apt/trusted.gpg.d/dokku.asc >/dev/null');
      l(r'''DISTRO="$(awk -F= '$1=="ID" { print tolower($2) ;}' /etc/os-release)"''');
      l(r'''OS_ID="$(awk -F= '$1=="VERSION_CODENAME" { print tolower($2) ;}' /etc/os-release)"''');
      l(r'echo "deb https://packagecloud.io/dokku/dokku/${DISTRO}/ ${OS_ID} main" | sudo tee /etc/apt/sources.list.d/dokku.list');
      l('sudo apt-get update -qq && sudo apt-get -qq -y ${o.noRecommends ? '--no-install-recommends ' : ''}install dokku',
          ScriptLineKind.emph);
      l('sudo dokku plugin:install-dependencies --core');
    case InstallMethod.source:
      c('install from source');
      l('rm -rf dokku-src && git clone --depth 1 ${shq(o.sourceRepo)} dokku-src && cd dokku-src');
      l('sudo make install', ScriptLineKind.emph);
      l('cd ..');
  }

  blank();
  c('admin ssh key');
  if (o.keyMode == KeyMode.authorizedKeys) {
    l('n=0');
    l("grep -E '^(ssh-|ecdsa-|sk-)' ~/.ssh/authorized_keys | while read -r key; do n=\$((n+1)); echo \"\$key\" | sudo dokku ssh-keys:add ${shq(o.keyName)}-\$n || true; done");
  } else {
    l('PUBLIC_KEY=${shq(o.publicKey.trim())}');
    l('echo "\$PUBLIC_KEY" | sudo dokku ssh-keys:add ${shq(o.keyName)}');
  }

  blank();
  c('global domain');
  l('sudo dokku domains:set-global ${shq(globalDomainFor(o))}');

  if (o.disableInstaller || o.letsencrypt || o.createFirst) {
    blank();
    c('post-install');
  }
  if (o.disableInstaller) l('sudo systemctl disable --now dokku-installer 2>/dev/null || true');
  if (o.letsencrypt) {
    l('sudo dokku plugin:list | grep -q letsencrypt || sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git');
  }
  if (o.createFirst) {
    l('sudo dokku apps:exists ${shq(o.firstApp)} 2>/dev/null || sudo dokku apps:create ${shq(o.firstApp)}');
  }
  blank();
  l(r'''echo "=====> Dokku $(dokku version | awk '{print $3}') installed."''', ScriptLineKind.comment);
  if (o.method == InstallMethod.bootstrap && o.versionMode == VersionMode.branch) {
    blank();
    out.add(const ScriptLine('# warning: source install from an unreleased branch', ScriptLineKind.warn));
  }
  return out;
}

String installScriptText(InstallOptions o) => '${buildInstallScript(o).map((l) => l.text).join('\n')}\n';
