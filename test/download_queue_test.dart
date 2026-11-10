import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/download_queue.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancel during retry backoff finishes promptly without dispatching again',
    () async {
      final queue = DownloadQueue();
      var calls = 0;
      final work = queue.run(
        title: 'retry',
        owner: 'a',
        songs: [fixtureSong(1), fixtureSong(2)],
        options: const DownloadOptions(quality: 'standard', retries: 3),
        account: () => 'a',
        download: (_, _) async {
          calls++;
          throw DioException(requestOptions: RequestOptions(path: '/audio'));
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(queue.items.first.error, contains('重试'));
      queue.cancel();
      await work.timeout(const Duration(milliseconds: 500));
      expect(calls, 1);
      expect(queue.count(DownloadStatus.cancelled), 2);
      queue.dispose();
    },
  );
  test('three workers fill available slots, stop dispatch on cancel and keep independent results', () async {
    final queue = DownloadQueue();
    final gates = <int, Completer<bool>>{};
    final work = queue.run(
      title: 'parallel',
      owner: 'a',
      songs: [for (var i = 1; i <= 6; i++) fixtureSong(i)],
      options: const DownloadOptions(quality: 'standard', concurrent: 3),
      account: () => 'a',
      download: (song, _) => (gates[song.id] = Completer<bool>()).future,
    );
    expect(gates.keys, [1, 2, 3]);
    gates[2]!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(gates.keys, [1, 2, 3, 4]);
    queue.cancel();
    for (final gate in gates.values.where((c) => !c.isCompleted)) {
      gate.completeError(const MusicError('取消'));
    }
    await work;
    expect(queue.count(DownloadStatus.saved), 1);
    expect(queue.count(DownloadStatus.cancelled), 5);
    queue.dispose();
  });
  test(
    'transient network failure retries, permanent denial does not',
    () async {
      for (final status in [503, 403]) {
        final queue = DownloadQueue();
        var calls = 0;
        await queue.run(
          title: 'retry',
          owner: 'a',
          songs: [fixtureSong(1)],
          options: const DownloadOptions(quality: 'standard', retries: 1),
          account: () => 'a',
          download: (_, _) async {
            calls++;
            if (calls == 1) {
              final request = RequestOptions(path: '/audio');
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: request, statusCode: status),
              );
            }
            return true;
          },
        );
        expect(calls, status == 503 ? 2 : 1);
        expect(
          queue.items.single.status,
          status == 503 ? DownloadStatus.saved : DownloadStatus.failed,
        );
        queue.dispose();
      }
    },
  );
  test(
    'full pagination deduplicates and rejects stalled or cancelled reads',
    () async {
      final offsets = <int>[];
      final result = await loadDownloadSongs((offset) async {
        offsets.add(offset);
        return offset == 0
            ? SongPage([fixtureSong(1), fixtureSong(2)], 100, true)
            : SongPage([fixtureSong(2), fixtureSong(3)], 103, false);
      }, active: () => true);
      expect(offsets, [0, 100]);
      expect(result.map((s) => s.id), [1, 2, 3]);
      await expectLater(
        loadDownloadSongs(
          (_) async => SongPage([fixtureSong(1)], 1, true),
          active: () => true,
        ),
        throwsA(isA<MusicError>()),
      );
      var active = true;
      await expectLater(
        loadDownloadSongs((_) async {
          active = false;
          return SongPage([fixtureSong(1)], 1, false);
        }, active: () => active),
        throwsA(isA<MusicError>()),
      );
    },
  );

  test(
    'queue is sequential, deduplicates, skips and continues after failure',
    () async {
      final queue = DownloadQueue();
      addTearDown(queue.dispose);
      final seen = <int>[];
      var concurrent = 0;
      await queue.run(
        title: 'list',
        owner: 'a',
        songs: [
          for (final id in [1, 2, 2, 3, 4]) fixtureSong(id),
        ],
        options: const DownloadOptions(quality: 'standard'),
        account: () => 'a',
        download: (song, options) async {
          concurrent++;
          expect(concurrent, 1);
          seen.add(song.id);
          await Future<void>.delayed(Duration.zero);
          concurrent--;
          if (song.id == 2) throw const MusicError('无可用音源');
          return song.id != 3;
        },
      );
      expect(seen, [1, 2, 3, 4]);
      expect(queue.count(DownloadStatus.saved), 2);
      expect(queue.count(DownloadStatus.failed), 1);
      expect(queue.count(DownloadStatus.skipped), 1);
      expect(queue.items[1].error, '无可用音源');
      expect(queue.busy, false);
    },
  );

  test(
    'cancel and account switch stop pending jobs and reject duplicate batches',
    () async {
      for (final switchAccount in [false, true]) {
        final queue = DownloadQueue();
        var account = 'a';
        final pending = Completer<bool>();
        final work = queue.run(
          title: 'list',
          owner: 'a',
          songs: [fixtureSong(1), fixtureSong(2)],
          options: const DownloadOptions(quality: 'lossless'),
          account: () => account,
          download: (_, _) => pending.future,
        );
        await expectLater(
          queue.run(
            title: 'other',
            owner: 'a',
            songs: [fixtureSong(3)],
            options: const DownloadOptions(quality: 'standard'),
            account: () => account,
            download: (_, _) async => true,
          ),
          throwsA(isA<MusicError>()),
        );
        if (switchAccount) {
          account = 'b';
        } else {
          queue.cancel();
        }
        pending.completeError(const MusicError('取消'));
        await work;
        expect(
          queue.items.every((i) => i.status == DownloadStatus.cancelled),
          true,
        );
        queue.dispose();
      }
    },
  );

  test('handler cancels URL preparation; no late file or next task; retry remains possible', () async {
    SharedPreferences.setMockInitialValues({
      'downloadConcurrent': 1,
      'downloadRetries': 0,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = FakeApi();
    final auth = AuthService(api);
    final dir = await Directory.systemTemp.createTemp('queue-test');
    final handler = MusicHandler(
      api,
      auth,
      prefs,
      AudioCache(dir),
      audioPlayer: FakePlayer(),
    );
    try {
      final work = handler.downloadSongs('list', [
        fixtureSong(1),
        fixtureSong(2),
      ]);
      while (api.streamRequests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await handler.cancelDownload();
      api.streamResults[1]!.complete(
        SongStream(Uri.parse('https://example.test/1.mp3'), 'standard', 'mp3'),
      );
      await work;
      expect(api.streamRequests, [1]);
      expect(await dir.list().toList(), isEmpty);
      expect(handler.downloadQueue.count(DownloadStatus.cancelled), 2);
      api.streamResults.clear();
      final retry = handler.retryDownloads();
      while (api.streamRequests.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await handler.cancelDownload();
      api.streamResults[1]!.completeError(const MusicError('取消'));
      await retry;
    } finally {
      await handler.disposeHandler();
      auth.dispose();
      await dir.delete(recursive: true);
    }
  });

  test(
    'quota failure stops the batch without requesting the remaining songs',
    () async {
      final queue = DownloadQueue();
      var calls = 0;
      await queue.run(
        title: 'list',
        owner: 'a',
        songs: [fixtureSong(1), fixtureSong(2)],
        options: const DownloadOptions(quality: 'standard'),
        account: () => 'a',
        download: (_, _) async {
          calls++;
          throw const DownloadSpaceError('空间不足');
        },
      );
      expect(calls, 1);
      expect(queue.stopReason, '空间不足');
      expect(queue.items.last.status, DownloadStatus.cancelled);
      queue.dispose();
    },
  );
  test('release year only accepts year/date fields, never an epoch or missing value', () {
    expect(Song.fromJson({'time_public': '2024-03-15'}).releaseYear, '2024');
    expect(Song.fromJson({'time_public': '1700000000'}).releaseYear, '');
    expect(
      Song.fromJson({
        'album': {'publishDate': '1998/02/01'},
      }).releaseYear,
      '1998',
    );
    expect(Song.fromJson({}).releaseYear, '');
  });
}
