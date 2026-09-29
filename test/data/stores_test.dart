import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/stores.dart';
import 'package:flutter_test/flutter_test.dart';

Host draft({String host = '203.0.113.10', AuthMethod auth = AuthMethod.key, String username = 'dokku', bool sudo = false}) => Host(
    id: '', name: 'prod', host: host, username: username, auth: auth, sudo: sudo, createdAt: DateTime(2026));

void main() {
  late MemoryStore plain, secure;
  late HostRepository repo;
  setUp(() {
    plain = MemoryStore();
    secure = MemoryStore();
    repo = HostRepository(plain: plain, secure: secure);
  });

  test('secrets go to the keystore and never to plain storage', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: '-----BEGIN KEY-----\nabc', passphrase: 'hunter2'));
    final plainText = plain.data.values.join();
    expect(plainText, isNot(contains('BEGIN KEY')));
    expect(plainText, isNot(contains('hunter2')));
    expect(plainText, contains('203.0.113.10'));
    final s = await repo.secrets(h.id);
    expect(s.privateKey, '-----BEGIN KEY-----\nabc\n');
    expect(s.passphrase, 'hunter2');
  });

  test('hosts survive a restart', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: 'k'));
    final again = HostRepository(plain: plain, secure: secure);
    expect((await again.load()).single.id, h.id);
    expect((await again.secrets(h.id)).privateKey, 'k\n');
  });

  test('blank secret fields keep what is stored', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: 'k', passphrase: 'p'));
    await repo.update(h.copyWith(name: 'renamed'), const HostSecrets());
    final s = await repo.secrets(h.id);
    expect(s.privateKey, 'k\n');
    expect(s.passphrase, 'p');
    expect((await repo.load()).single.name, 'renamed');
  });

  test('switching sign-in method drops the secrets it no longer uses', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: 'k', passphrase: 'p'));
    await repo.update(h.copyWith(auth: AuthMethod.password), const HostSecrets(password: 'pw'));
    final s = await repo.secrets(h.id);
    expect(s.privateKey, isNull);
    expect(s.passphrase, isNull);
    expect(s.password, 'pw');
  });

  test('the host key is pinned once and cleared when the address changes', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: 'k'));
    await repo.pinHostKey(h.id, 'ssh-ed25519', 'SHA256:first');
    await repo.pinHostKey(h.id, 'ssh-ed25519', 'SHA256:second');
    var saved = (await repo.load()).single;
    expect(saved.hostKey, 'SHA256:first');
    saved = await repo.update(saved.copyWith(host: '198.51.100.7'), const HostSecrets());
    expect(saved.hostKey, isNull);
  });

  test('sudo is ignored for the dokku user', () async {
    final h = await repo.create(draft(sudo: true), const HostSecrets(privateKey: 'k'));
    expect(h.sudo, isFalse);
    final root = await repo.create(draft(username: 'deploy', sudo: true), const HostSecrets(privateKey: 'k'));
    expect(root.sudo, isTrue);
  });

  test('deleting a host removes its secrets', () async {
    final h = await repo.create(draft(), const HostSecrets(privateKey: 'k'));
    await repo.delete(h.id);
    expect(await repo.load(), isEmpty);
    expect(secure.data, isEmpty);
  });

  test('validateHost', () {
    expect(validateHost(name: 'prod-01', host: '203.0.113.10', port: 22, username: 'dokku'), isEmpty);
    expect(validateHost(name: 'prod', host: 'dokku.example.com', port: 2222, username: 'root'), isEmpty);
    expect(validateHost(name: '', host: 'a b', port: 0, username: '1bad'), hasLength(4));
  });

  test('git remote follows the ssh port', () {
    expect(draft().gitRemote('api'), 'dokku@203.0.113.10:api');
    expect(Host(id: '', name: 'x', host: 'h.example.com', port: 3022, createdAt: DateTime(2026)).gitRemote('api'),
        'ssh://dokku@h.example.com:3022/api');
  });

  group('activity log', () {
    test('keeps newest first, trims stderr, survives restart', () async {
      final store = MemoryStore();
      final log = ActivityLog(store);
      await log.add(hostId: 'a', command: 'dokku ps:restart x', code: 0, durationMs: 10, stderr: 'ignored on success');
      await log.add(hostId: 'a', command: 'dokku ps:stop x', code: 1, durationMs: 20, stderr: 'e' * 5000);
      final list = await ActivityLog(store).load();
      expect(list.map((e) => e.command), ['dokku ps:stop x', 'dokku ps:restart x']);
      expect(list.first.stderr, hasLength(2000));
      expect(list.last.stderr, isNull);
      expect(list.first.id, greaterThan(list.last.id));
    });
  });
}
