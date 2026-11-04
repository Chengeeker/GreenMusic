import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';

import 'support/fakes.dart';

class CacheAdapter implements HttpClientAdapter {
  CacheAdapter(this.status, this.contentType);
  final int status;
  final String contentType;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    [73, 68, 51, 4],
    status,
    headers: {
      'content-type': [contentType],
      'content-length': ['4'],
    },
  );
  @override
  void close({bool force = false}) {}
}

class PendingAudioAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final chunks = StreamController<Uint8List>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    return ResponseBody(
      chunks.stream,
      200,
      headers: {
        'content-type': ['audio/mpeg'],
        'content-length': ['100'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late AudioCache cache;
  final stream = SongStream(
    Uri.parse('https://dl.stream.qqmusic.qq.com/test.mp3'),
    'standard',
    'mp3',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('greenmusic-cache-test-');
    cache = AudioCache(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'complete cache uses final name and clears only its owned cache folder',
    () async {
      final http = Dio()..httpClientAdapter = CacheAdapter(200, 'audio/mpeg');
      await cache.save(http, 'anonymous', fixtureSong(1), stream);
      expect(
        await cache.file('anonymous', fixtureSong(1), stream).readAsBytes(),
        [73, 68, 51, 4],
      );
      expect(await cache.size(), 4);
      expect(await directory.list().length, 2);
      final entries = await AudioCache(directory).entries('anonymous');
      expect(entries.single.song.name, '歌曲 1');
      expect(entries.single.quality, 'standard');
      expect(entries.single.bytes, 4);
      expect(await cache.entries('another-account'), isEmpty);
      expect(
        await File('${entries.single.file.path}.json').readAsString(),
        isNot(contains('https://')),
      );
      await cache.clear();
      expect(await cache.size(), 0);
      http.close(force: true);
    },
  );
  test('cancelling an in-progress transfer removes partial bytes and completed entries', () async {
    final adapter = PendingAudioAdapter();
    final http = Dio()..httpClientAdapter = adapter;
    final outcome = expectLater(
      cache.save(http, 'anonymous', fixtureSong(1), stream),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
      ),
    );
    await adapter.started.future;
    adapter.chunks.add(Uint8List.fromList([73, 68, 51]));
    for (
      var i = 0;
      i < 100 && (cache.progress.value?.received ?? 0) == 0;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(cache.progress.value!.received, 3);
    await cache.cancel();
    await outcome;
    expect(cache.progress.value, isNull);
    expect(await cache.entries('anonymous'), isEmpty);
    expect(await directory.list().length, 0);
    await adapter.chunks.close();
    http.close(force: true);
  });
  test('a full download quota never evicts an existing song', () async {
    final http = Dio()..httpClientAdapter = CacheAdapter(200, 'audio/mpeg');
    cache.maxBytes = 4;
    await cache.save(http, 'anonymous', fixtureSong(1), stream);
    await expectLater(
      cache.save(http, 'anonymous', fixtureSong(2), stream),
      throwsA(isA<MusicError>()),
    );
    expect((await cache.entries('anonymous')).single.song.id, 1);
    expect(await cache.size(), 4);
    expect(cache.progress.value, isNull);
    http.close(force: true);
  });
  test(
    'old manual downloads migrate with metadata and deletion is account-scoped',
    () async {
      final legacy = Directory('${directory.path}/old');
      final persistent = Directory('${directory.path}/persistent');
      await legacy.create();
      final old = AudioCache(legacy);
      await old.file('123', fixtureSong(7), stream).writeAsBytes([1, 2, 3]);
      final downloads = AudioCache(persistent, legacyDirectory: legacy);
      final entries = await downloads.entries(
        '123',
        knownSongs: [fixtureSong(7)],
      );
      expect(entries.single.song.name, '歌曲 7');
      expect(entries.single.file.parent.uri, persistent.uri);
      expect(await old.file('123', fixtureSong(7), stream).exists(), isFalse);
      expect(
        (await AudioCache(persistent).entries('123')).single.song.mid,
        'song7',
      );
      await expectLater(
        downloads.remove('456', entries.single),
        throwsA(isA<MusicError>()),
      );
      expect(await entries.single.file.exists(), isTrue);
      await downloads.remove('123', entries.single);
      expect(await downloads.entries('123'), isEmpty);
    },
  );
  test('an oversized transfer leaves neither a partial file nor a false completed entry', () async {
    final http = Dio()..httpClientAdapter = CacheAdapter(200, 'audio/mpeg');
    cache.maxBytes = 3;
    await expectLater(
      cache.save(http, 'anonymous', fixtureSong(1), stream),
      throwsA(isA<MusicError>()),
    );
    expect(await cache.entries('anonymous'), isEmpty);
    expect(await directory.list().length, 0);
    expect(cache.progress.value, isNull);
    http.close(force: true);
  });
  test('startup removes owned interrupted fragments without deleting completed audio or other files', () async {
    final target = cache.file('anonymous', fixtureSong(1), stream);
    await target.writeAsBytes([1, 2, 3]);
    final part = File('${target.path}.part'),
        pendingIndex = File('${target.path}.json.tmp');
    await part.writeAsBytes([1]);
    await pendingIndex.writeAsString('{}');
    final unrelated = File('${directory.path}/keep.txt');
    await unrelated.writeAsString('keep');
    await cache.cleanupInterrupted();
    expect(await target.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await part.exists(), isFalse);
    expect(await pendingIndex.exists(), isFalse);
  });
  for (final response in [(206, 'audio/mpeg'), (200, 'application/json')]) {
    test('partial or non-audio response is not persisted $response', () async {
      final http = Dio()
        ..httpClientAdapter = CacheAdapter(response.$1, response.$2);
      await expectLater(
        cache.save(http, 'anonymous', fixtureSong(1), stream),
        throwsA(isA<MusicError>()),
      );
      expect(await directory.list().length, 0);
      http.close(force: true);
    });
  }
}
