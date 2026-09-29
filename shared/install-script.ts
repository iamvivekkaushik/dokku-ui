// Generates the Dokku install script shown in the Install wizard. The same
// generator runs on the server when the script is executed, so the browser can
// only choose options, never inject arbitrary shell.
import { shq } from './shq';

export interface InstallOptions {
  method: 'bootstrap' | 'apt' | 'source';
  verMode: 'tag' | 'branch';
  dokkuTag: string;
  dokkuBranch: string;
  sourceRepo: string;
  noRecommends: boolean;
  vhost: boolean;
  hostname: string;
  skipKey: boolean;
  keyFile: string;
  nginx: boolean;
  keyMode: 'authz' | 'paste';
  keyName: string;
  publicKey: string;
  domainMode: 'custom' | 'ip' | 'sslip';
  globalDomain: string;
  serverIp: string;
  post: { disableInstaller: boolean; letsencrypt: boolean; createFirst: boolean };
  firstApp: string;
}

export const defaultInstallOptions = (serverIp = ''): InstallOptions => ({
  method: 'bootstrap', verMode: 'tag', dokkuTag: 'v0.35.12', dokkuBranch: 'master',
  sourceRepo: 'https://github.com/dokku/dokku.git',
  noRecommends: false, vhost: true, hostname: '', skipKey: false, keyFile: '/root/.ssh/authorized_keys', nginx: true,
  keyMode: 'authz', keyName: 'admin', publicKey: '',
  domainMode: 'sslip', globalDomain: '', serverIp,
  post: { disableInstaller: true, letsencrypt: true, createFirst: false }, firstApp: 'hello-world',
});

export type ScriptLineKind = 'comment' | 'cmd' | 'emph' | 'warn' | 'blank';
export interface ScriptLine { text: string; kind: ScriptLineKind }

const TAG = /^v?\d+\.\d+\.\d+$/;
const BRANCH = /^[A-Za-z0-9._/-]{1,100}$/;
const NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const DOMAIN = /^[A-Za-z0-9.-]{1,253}$/;
const PUBKEY = /^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( [^\n]*)?$/;

export function validateInstallOptions(o: InstallOptions): string[] {
  const errs: string[] = [];
  if (!['bootstrap', 'apt', 'source'].includes(o.method)) errs.push('unknown install method');
  if (o.method === 'bootstrap' && o.verMode === 'tag' && !TAG.test(o.dokkuTag)) errs.push('DOKKU_TAG must look like v0.35.12');
  if (o.method === 'bootstrap' && o.verMode === 'branch' && !BRANCH.test(o.dokkuBranch)) errs.push('invalid branch name');
  if (o.method === 'source' && !/^https:\/\/[^\s'"]+\.git$/.test(o.sourceRepo)) errs.push('source repo must be an https .git URL');
  if (o.hostname && !DOMAIN.test(o.hostname)) errs.push('invalid hostname');
  if (!NAME.test(o.keyName)) errs.push('key name must be lowercase letters, digits and dashes');
  if (o.keyMode === 'paste' && !PUBKEY.test(o.publicKey.trim())) errs.push('public key must be a single OpenSSH public key line');
  if (o.domainMode === 'custom' && !DOMAIN.test(o.globalDomain)) errs.push('invalid global domain');
  if (o.domainMode !== 'custom' && !/^[0-9a-fA-F.:]+$/.test(o.serverIp)) errs.push('server IP unknown');
  if (o.post.createFirst && !NAME.test(o.firstApp)) errs.push('invalid first app name');
  if (!o.skipKey && o.method === 'apt' && !/^\/[\w./-]+$/.test(o.keyFile)) errs.push('invalid key file path');
  return errs;
}

export function globalDomainFor(o: InstallOptions): string {
  if (o.domainMode === 'custom') return o.globalDomain || 'dokku.me';
  if (o.domainMode === 'ip') return o.serverIp;
  return `${o.serverIp}.sslip.io`;
}

export function buildInstallScript(o: InstallOptions): ScriptLine[] {
  const out: ScriptLine[] = [];
  const c = (text: string) => out.push({ text: `# ${text}`, kind: 'comment' });
  const l = (text: string, kind: ScriptLineKind = 'cmd') => out.push({ text, kind });
  const blank = () => out.push({ text: '', kind: 'blank' });
  const debconf = (key: string, type: string, value: string) =>
    l(`echo ${shq(`dokku dokku/${key} ${type} ${value}`)} | sudo debconf-set-selections`);
  const hostname = o.hostname || globalDomainFor(o);

  l('#!/usr/bin/env bash', 'comment');
  l('set -euo pipefail', 'comment');
  l('export DEBIAN_FRONTEND=noninteractive', 'comment');
  blank();

  if (o.method === 'bootstrap') {
    c('install dokku via bootstrap.sh');
    debconf('vhost_enable', 'boolean', String(o.vhost));
    debconf('hostname', 'string', hostname);
    debconf('nginx_enable', 'boolean', String(o.nginx));
    const env: string[] = [];
    if (o.verMode === 'tag') {
      const tag = o.dokkuTag.startsWith('v') ? o.dokkuTag : `v${o.dokkuTag}`;
      l(`wget -NP . ${shq(`https://dokku.com/install/${tag}/bootstrap.sh`)}`);
      env.push(`DOKKU_TAG=${shq(tag)}`);
    } else {
      l('wget -NP . https://raw.githubusercontent.com/dokku/dokku/master/bootstrap.sh');
      env.push(`DOKKU_BRANCH=${shq(o.dokkuBranch)}`);
    }
    if (o.noRecommends) env.push('DOKKU_NO_INSTALL_RECOMMENDS=true');
    l(`sudo ${env.join(' ')} bash bootstrap.sh`, 'emph');
  } else if (o.method === 'apt') {
    c('unattended install: debconf + apt');
    debconf('vhost_enable', 'boolean', String(o.vhost));
    debconf('hostname', 'string', hostname);
    debconf('skip_key_file', 'boolean', String(o.skipKey));
    if (!o.skipKey) debconf('key_file', 'string', o.keyFile);
    debconf('nginx_enable', 'boolean', String(o.nginx));
    l('command -v docker >/dev/null || wget -nv -O - https://get.docker.com/ | sudo sh');
    l('wget -qO- https://packagecloud.io/dokku/dokku/gpgkey | sudo tee /etc/apt/trusted.gpg.d/dokku.asc >/dev/null');
    l(`DISTRO="$(awk -F= '$1=="ID" { print tolower($2) ;}' /etc/os-release)"`);
    l(`OS_ID="$(awk -F= '$1=="VERSION_CODENAME" { print tolower($2) ;}' /etc/os-release)"`);
    l('echo "deb https://packagecloud.io/dokku/dokku/${DISTRO}/ ${OS_ID} main" | sudo tee /etc/apt/sources.list.d/dokku.list');
    l(`sudo apt-get update -qq && sudo apt-get -qq -y ${o.noRecommends ? '--no-install-recommends ' : ''}install dokku`, 'emph');
    l('sudo dokku plugin:install-dependencies --core');
  } else {
    c('install from source');
    l(`rm -rf dokku-src && git clone --depth 1 ${shq(o.sourceRepo)} dokku-src && cd dokku-src`);
    l('sudo make install', 'emph');
    l('cd ..');
  }

  blank();
  c('admin ssh key');
  if (o.keyMode === 'authz') {
    l('n=0');
    l(`grep -E '^(ssh-|ecdsa-|sk-)' ~/.ssh/authorized_keys | while read -r key; do n=$((n+1)); echo "$key" | sudo dokku ssh-keys:add ${shq(o.keyName)}-$n || true; done`);
  } else {
    l(`PUBLIC_KEY=${shq(o.publicKey.trim())}`);
    l(`echo "$PUBLIC_KEY" | sudo dokku ssh-keys:add ${shq(o.keyName)}`);
  }

  blank();
  c('global domain');
  l(`sudo dokku domains:set-global ${shq(globalDomainFor(o))}`);

  if (o.post.disableInstaller || o.post.letsencrypt || o.post.createFirst) { blank(); c('post-install'); }
  if (o.post.disableInstaller) l('sudo systemctl disable --now dokku-installer 2>/dev/null || true');
  if (o.post.letsencrypt) l('sudo dokku plugin:list | grep -q letsencrypt || sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git');
  if (o.post.createFirst) l(`sudo dokku apps:exists ${shq(o.firstApp)} 2>/dev/null || sudo dokku apps:create ${shq(o.firstApp)}`);
  blank();
  l('echo "=====> Dokku $(dokku version | awk \'{print $3}\') installed."', 'comment');
  if (o.method === 'bootstrap' && o.verMode === 'branch') { blank(); out.push({ text: '# warning: source install from an unreleased branch', kind: 'warn' }); }
  return out;
}

export function installScriptText(o: InstallOptions): string {
  return buildInstallScript(o).map((l) => l.text).join('\n') + '\n';
}
