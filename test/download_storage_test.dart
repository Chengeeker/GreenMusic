import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/download_storage.dart';
import 'package:greenmusic/player/music_handler.dart';

import 'support/fakes.dart';

class AudioResponse extends Fake implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    [73, 68, 51, 4],
    200,
    headers: {
      'content-type': ['audio/mpeg'],
      'content-length': ['4'],
    },
  );
  @override
  void close({bool force = false}) {}
}

class Documents extends DownloadStorage {
  Documents(super.prefs);
  final files = <String, List<int>>{};
  final names = <String>[];
  bool failLyrics = false;
  Completer<void>? gate, started;
  int id = 0;
  @override
  Future<String> write(
    String tree,
    String name,
    String path,
    String mime,
  ) async {
    started?.complete();
    started = null;
    await gate?.future;
    if (mime == 'text/plain' && failLyrics) throw const MusicError('歌词写入失败');
    final uri = '$tree/document/${++id}';
    files[uri] = await File(path).readAsBytes();
    names.add(name);
    return uri;
  }

  @override
  Future<bool> exists(String uri) async => files.containsKey(uri);
  @override
  Future<void> delete(String uri) async {
    files.remove(uri);
  }
}

class DownloadApi extends FakeApi {
  String? requested;
  @override
  Future<SongStream> stream(Song song, String quality) async {
    requested = quality;
    return SongStream(
      Uri.https('stream.qqmusic.qq.com', '/song'),
      quality,
      quality == 'lossless' ? 'flac' : 'mp3',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences prefs;
  late Documents documents;
  late AudioCache cache;
  late Dio http;
  final stream = SongStream(
    Uri.https('stream.qqmusic.qq.com', '/fixture'),
    'standard',
    'mp3',
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('greenmusic-documents-');
    documents = Documents(prefs);
    cache = AudioCache(directory, storage: documents);
    http = Dio()..httpClientAdapter = AudioResponse();
  });
  tearDown(() async {
    http.close(force: true);
    cache.dispose();
    await directory.delete(recursive: true);
  });
  test('local and selected folders coexist, restart, scope, LRC, quota and deletion', () async {
    await cache.save(http, 'a', fixtureSong(1), stream, lyrics: '[00:01.00]一');
    await prefs.setString('downloadTree', 'content://fixtures/tree/music');
    await cache.save(http, 'a', fixtureSong(2), stream, lyrics: '[00:01.00]二');
    expect(documents.files.length, 2);
    expect(documents.names.last, endsWith('.lrc'));
    expect(
      documents.names.first.replaceFirst('.mp3', '.lrc'),
      documents.names.last,
    );
    final restarted = AudioCache(directory, storage: documents);
    final entries = await restarted.entries('a');
    expect(entries.length, 2);
    expect(entries.map((e) => e.stream.uri.scheme).toSet(), {
      'file',
      'content',
    });
    expect(await restarted.entries('b'), isEmpty);
    expect(await restarted.size(), 8);
    cache.maxBytes = 4;
    await cache.save(http, 'a', fixtureSong(4), stream);
    expect(documents.files.length, 3);
    expect(await cache.privateSize(), 4);
    final extra = (await cache.entries('a')).singleWhere((e) => e.song.id == 4);
    await cache.remove('a', extra);
    expect(documents.files.length, 2);
    final remote = entries.singleWhere((e) => e.documentUri != null);
    final audioBytes = documents.files.remove(remote.documentUri!)!;
    expect(await restarted.size(), 4);
    expect(await restarted.entries('a'), hasLength(1));
    documents.files[remote.documentUri!] = audioBytes;
    expect(await remote.file.exists(), isFalse);
    expect(
      await File('${remote.file.path}.json').readAsString(),
      isNot(contains('https://')),
    );
    await expectLater(
      restarted.remove('b', remote),
      throwsA(isA<MusicError>()),
    );
    await documents.resetDirectory();
    expect(
      (await restarted.find(
        'a',
        fixtureSong(2),
        'standard',
      ))!.stream.uri.scheme,
      'content',
    );
    await restarted.remove('a', remote);
    expect(documents.files, isEmpty);
    expect(await restarted.size(), 4);
    await restarted.clear();
    expect(await directory.list().length, 0);
    restarted.dispose();
  });
  test('lyrics failure and cancellation roll back remote documents and staging files', () async {
    await prefs.setString('downloadTree', 'content://fixtures/tree/music');
    documents.failLyrics = true;
    await expectLater(
      cache.save(http, 'a', fixtureSong(1), stream, lyrics: '[00:01.00]一'),
      throwsA(isA<MusicError>()),
    );
    expect(documents.files, isEmpty);
    expect(await directory.list().length, 0);
    documents.failLyrics = false;
    documents.gate = Completer<void>();
    final started = documents.started = Completer<void>();
    final work = cache.save(http, 'a', fixtureSong(1), stream);
    final outcome = expectLater(work, throwsA(isA<DioException>()));
    await started.future;
    final cancel = cache.cancel();
    documents.gate!.complete();
    await outcome;
    await cancel;
    expect(documents.files, isEmpty);
    expect(await directory.list().length, 0);
  });
  test('directory picker cancellation, persisted choice, error and one-time notification request', () async {
    final calls = <String>[];
    Object? selection;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DownloadStorage.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'chooseDirectory') return selection;
      if (call.method == 'exists') {
        throw PlatformException(code: 'storage_permission', message: '目录授权已失效');
      }
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(DownloadStorage.channel, null),
    );
    final access = DownloadStorage(prefs);
    expect(await access.chooseDirectory(), false);
    selection = {'uri': 'content://fixtures/tree/music', 'label': 'Music'};
    expect(await access.chooseDirectory(), true);
    expect(DownloadStorage(prefs).label, 'Music');
    await expectLater(
      access.exists('content://fixtures/tree/music/document/1'),
      throwsA(isA<MusicError>()),
    );
    await access.requestNotificationOnce();
    await access.requestNotificationOnce();
    expect(calls.where((m) => m == 'requestNotifications').length, 1);
    selection = {'uri': 'file:///wrong', 'label': 'bad'};
    await expectLater(access.chooseDirectory(), throwsA(isA<MusicError>()));
    expect(access.label, 'Music');
  });
  test('LRC encodes time, sanitizes newlines and keeps translations', () {
    expect(
      encodeLrc([
        const LyricLine(
          Duration(milliseconds: 61234),
          '一\n二',
          translation: 'three',
        ),
      ]),
      '[01:01.23]一 二\n[01:01.23]three',
    );
    expect(encodeLrc([]), '');
  });
  test('download quality and lyrics preferences apply without changing playback quality', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await prefs.setString('quality', 'standard');
    await prefs.setString('downloadQuality', 'lossless');
    await prefs.setBool('downloadLyrics', true);
    final api = DownloadApi();
    api.http.httpClientAdapter = AudioResponse();
    final auth = AuthService(api);
    final handler = MusicHandler(
      api,
      auth,
      prefs,
      AudioCache(directory, storage: documents),
      audioPlayer: FakePlayer(),
    );
    try {
      await handler.downloadSong(fixtureSong(3));
      expect(api.requested, 'lossless');
      expect(prefs.getString('quality'), 'standard');
      final entry = (await cache.entries('anonymous')).single;
      expect(entry.format, 'flac');
      final lyrics = File(entry.file.path.replaceFirst('.flac', '.lrc'));
      expect(await lyrics.readAsString(), contains('[00:10.00]翻译'));
      await handler.downloadSong(fixtureSong(4), quality: 'exhigh');
      expect(api.requested, 'exhigh');
      expect(prefs.getString('downloadQuality'), 'lossless');
      expect(prefs.getString('quality'), 'standard');
      final overrideEntry = (await cache.entries('anonymous'))
          .singleWhere((entry) => entry.song.id == 4);
      expect(overrideEntry.quality, 'exhigh');
    } finally {
      await handler.disposeHandler();
      api.http.close(force: true);
    }
  });
}
