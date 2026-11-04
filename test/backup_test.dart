import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/services/backup_service.dart';
import 'package:greenmusic/core/services/webdav_service.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';

import 'support/fakes.dart';

class DavAdapter implements HttpClientAdapter {
  final requests = <({RequestOptions options, List<int> bytes})>[];
  List<int>? saved;
  bool rejectCreate = false, redirect = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes =
        await requestStream?.fold<List<int>>([], (a, b) => a..addAll(b)) ?? [];
    requests.add((options: options, bytes: bytes));
    if (redirect) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://other.example/'],
        },
      );
    }
    if (options.method == 'PROPFIND') return ResponseBody.fromString('', 207);
    if (options.method == 'MKCOL') {
      return ResponseBody.fromString('', rejectCreate ? 403 : 405);
    }
    if (options.method == 'PUT') {
      saved = bytes;
      return ResponseBody.fromString('', 201);
    }
    return ResponseBody.fromBytes(saved ?? [], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late BackupService store;
  late MusicHandler handler;
  late AuthService auth;
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'themeMode': 1,
      'quality': 'standard',
      'queue': jsonEncode([fixtureSong(1).raw]),
      'history': '[]',
      'webdavUrl': 'https://dav.example/dav/',
      'webdavUsername': 'user',
    });
    FlutterSecureStorage.setMockInitialValues({
      'webdav_password': 'private-dav-password',
    });
    final api = FakeApi();
    auth = AuthService(api);
    api.session = MusicSession(credential());
    final prefs = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp(
      'greenmusic-backup-test-',
    );
    handler = MusicHandler(
      api,
      auth,
      prefs,
      AudioCache(directory),
      audioPlayer: FakePlayer(),
    );
    store = BackupService(prefs, auth, handler);
  });
  tearDown(() async {
    await handler.disposeHandler();
    auth.http.close(force: true);
    auth.api.http.close(force: true);
    await directory.delete(recursive: true);
  });
  test(
    'safe backup exports settings and queue without account or WebDAV secrets',
    () async {
      final data = await store.exportAllData();
      final encoded = jsonEncode(data);
      expect(data['backup_mode'], 'safe');
      expect(data.containsKey('credentials'), isFalse);
      expect(encoded, isNot(contains('fixture-secret')));
      expect(encoded, isNot(contains('private-dav-password')));
      expect(obj(data['preferences'])['queue'], contains('song1'));
      BackupService.validate(data);
    },
  );
  test('retired UI style is omitted and ignored in older backups', () async {
    await store.prefs.setBool('saltUi', true);
    final backup = await store.exportAllData();
    expect((backup['preferences'] as Map).containsKey('saltUi'), false);
    await store.prefs.remove('saltUi');
    (backup['preferences'] as Map)['saltUi'] = true;
    (backup['preferences'] as Map)['themeMode'] = 2;
    await store.restoreAllData(backup);
    expect(store.prefs.containsKey('saltUi'), false);
    expect(store.prefs.getInt('themeMode'), 2);
  });
  test('download preferences restore, while device grants and folder paths stay local', () async {
    await store.prefs.setString('downloadQuality', 'lossless');
    await store.prefs.setBool('downloadLyrics', true);
    await store.prefs.setString(
      'downloadTree',
      'content://device/tree/private',
    );
    await store.prefs.setString('downloadTreeLabel', 'Music');
    await store.prefs.setBool('notificationAsked', true);
    final backup = await store.exportAllData();
    final settings = obj(backup['preferences']);
    expect(settings['downloadQuality'], 'lossless');
    expect(settings['downloadLyrics'], true);
    expect(settings.containsKey('downloadTree'), false);
    expect(settings.containsKey('downloadTreeLabel'), false);
    expect(settings.containsKey('notificationAsked'), false);
    await store.prefs.remove('downloadQuality');
    await store.prefs.remove('downloadLyrics');
    await store.restoreAllData(backup);
    expect(store.prefs.getString('downloadQuality'), 'lossless');
    expect(store.prefs.getBool('downloadLyrics'), true);
    expect(
      store.prefs.getString('downloadTree'),
      'content://device/tree/private',
    );
    settings['downloadQuality'] = 'invalid';
    final invalid = {...backup, 'preferences': settings};
    expect(() => BackupService.validate(invalid), throwsA(isA<MusicError>()));
  });
  test('safe restore preserves login and same-server password, refreshing paused queue', () async {
    final backup = await store.exportAllData();
    obj(backup['preferences']);
    (backup['preferences'] as Map)['queue'] = '[]';
    (backup['preferences'] as Map)['themeMode'] = 2;
    (backup['preferences'] as Map)['appTextScale'] = 1;
    await store.restoreAllData(backup);
    expect(auth.session!.id, '123');
    expect(await store.getWebDavPassword(), 'private-dav-password');
    expect(handler.current, isNull);
    expect(handler.mediaItem.value, isNull);
    expect(store.prefs.getInt('themeMode'), 2);
    expect(store.prefs.getDouble('appTextScale'), 1.0);
  });
  test(
    'retired appIcon setting is omitted and ignored in legacy backups',
    () async {
      await store.prefs.setString('appIcon', 'alias2');
      final backup = await store.exportAllData();
      expect((backup['preferences'] as Map).containsKey('appIcon'), isFalse);
      await store.prefs.remove('appIcon');
      (backup['preferences'] as Map)['appIcon'] = 'alias1';
      (backup['preferences'] as Map)['themeMode'] = 2;
      await store.restoreAllData(backup);
      expect(store.prefs.getInt('themeMode'), 2);
      expect(store.prefs.containsKey('appIcon'), isFalse);
    },
  );
  test('safe restore cannot send retained password to a changed WebDAV destination', () async {
    final backup = await store.exportAllData();
    (backup['preferences'] as Map)['webdavUrl'] =
        'https://changed.example/dav/';
    await store.restoreAllData(backup);
    expect(await store.getWebDavPassword(), '');
    expect(auth.session!.id, '123');
  });
  test('full backup restores session into secure storage and reloads local settings', () async {
    final backup = await store.exportAllData(includeCredentials: true);
    (backup['credentials'] as Map)['qqmusic'] = credential(id: '456');
    await store.restoreAllData(backup);
    expect(auth.session!.id, '456');
    expect(await auth.storage.read(key: 'qqmusic_session'), contains('456'));
    expect(await store.getWebDavPassword(), 'private-dav-password');
  });
  test(
    'invalid or foreign backup changes nothing and does not stop playback',
    () async {
      final player = handler.player as FakePlayer;
      player.playing = true;
      for (final invalid in [
        {
          'app': 'review',
          'schema': 1,
          'backup_mode': 'safe',
          'preferences': {'themeMode': 2},
        },
        {
          'app': 'greenmusic',
          'schema': 1,
          'backup_mode': 'safe',
          'preferences': {'themeMode': '2'},
        },
        {
          'app': 'greenmusic',
          'schema': 1,
          'backup_mode': 'safe',
          'preferences': {'queue': '[{"id":0}]'},
        },
        {
          'app': 'greenmusic',
          'schema': 1,
          'backup_mode': 'full',
          'preferences': {},
          'credentials': {
            'qqmusic': {'musickey': 'bad'},
            'webdavPassword': 'x',
          },
        },
      ]) {
        await expectLater(
          store.restoreAllData(invalid),
          throwsA(isA<MusicError>()),
        );
      }
      expect(store.prefs.getInt('themeMode'), 1);
      expect(player.playing, isTrue);
      expect(auth.session!.id, '123');
    },
  );
  test('WebDAV uses UTF-8 PUT bytes, encoded paths, latest/history and GET roundtrip', () async {
    final adapter = DavAdapter(),
        service = WebDavService(dio: Dio()..httpClientAdapter = adapter);
    final data = await store.exportAllData();
    expect(
      await service.testConnection(
        serverUrl: 'https://dav.example/remote.php/dav/files/user/',
        username: '用户',
        password: '密码',
      ),
      isTrue,
    );
    expect(
      await service.uploadBackup(
        serverUrl: 'https://dav.example/remote.php/dav/files/user/',
        username: '用户',
        password: '密码',
        directoryName: '音乐 备份',
        data: data,
      ),
      isTrue,
    );
    final puts = adapter.requests
        .where((r) => r.options.method == 'PUT')
        .toList();
    expect(puts.length, 2);
    expect(
      puts.first.options.uri.toString(),
      contains(
        '%E9%9F%B3%E4%B9%90%20%E5%A4%87%E4%BB%BD/backup_greenmusic_latest.json',
      ),
    );
    expect(jsonDecode(utf8.decode(puts.first.bytes)), data);
    expect(
      puts.first.options.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('用户:密码'))}',
    );
    final restored = await service.downloadLatestBackup(
      serverUrl: 'https://dav.example/remote.php/dav/files/user/',
      username: '用户',
      password: '密码',
      directoryName: '音乐 备份',
    );
    expect(restored, data);
  });
  test(
    'WebDAV directory denial or redirect cannot become a successful backup',
    () async {
      final adapter = DavAdapter()..rejectCreate = true,
          service = WebDavService(dio: Dio()..httpClientAdapter = adapter);
      expect(
        await service.uploadBackup(
          serverUrl: 'https://dav.example/',
          username: 'u',
          password: 'p',
          directoryName: 'GreenMusic',
          data: {},
        ),
        isFalse,
      );
      expect(adapter.requests.where((r) => r.options.method == 'PUT'), isEmpty);
      adapter.redirect = true;
      expect(
        await service.testConnection(
          serverUrl: 'https://dav.example/',
          username: 'u',
          password: 'p',
        ),
        isFalse,
      );
      expect(adapter.requests.last.options.followRedirects, isFalse);
    },
  );
  test('WebDAV rejects prefix spoofing, credentials in URLs and directory traversal', () {
    for (final url in [
      'http://localhost.evil.example/',
      'http://127.0.0.1.evil.example/',
      'https://user:secret@dav.example/',
      'https://dav.example/#fragment',
    ]) {
      expect(WebDavService.isSecureUrl(url), isFalse);
    }
    expect(WebDavService.isSecureUrl('dav.example/dav/'), isTrue);
    expect(WebDavService.isSecureUrl('http://127.0.0.1:8080/'), isTrue);
    expect(
      () => WebDavService.directoryUri('https://dav.example/', '../Review'),
      throwsFormatException,
    );
  });
}
