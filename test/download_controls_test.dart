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

import 'download_storage_test.dart' show AudioResponse, Documents;
import 'support/fakes.dart';

class RetryApi extends FakeApi {
  int calls = 0;
  @override
  Future<SongStream> stream(Song song, String quality) async {
    if (++calls == 1) {
      final request = RequestOptions(path: '/audio');
      throw DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 503),
        type: DioExceptionType.badResponse,
      );
    }
    return SongStream(Uri.https('example.test', '/audio'), quality, 'mp3');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'single-song download shares retry settings and saves only one final file',
    () async {
      SharedPreferences.setMockInitialValues({'downloadRetries': 1});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = RetryApi()..http.httpClientAdapter = AudioResponse();
      final directory = await Directory.systemTemp.createTemp('single-retry');
      final handler = MusicHandler(
        api,
        AuthService(api),
        prefs,
        AudioCache(directory),
        audioPlayer: FakePlayer(),
      );
      try {
        await handler.downloadSong(fixtureSong(1));
        expect(api.calls, 2);
        expect(handler.downloadQueue.items.single.attempt, 1);
        expect(handler.downloadQueue.items.single.status, DownloadStatus.saved);
        expect(await handler.cache.privateSize(), 4);
      } finally {
        await handler.disposeHandler();
        api.http.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
  test('concurrent private reservations cannot exceed quota; public downloads neither count nor enforce it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('download-budget');
    final documents = Documents(prefs);
    final cache = AudioCache(directory, storage: documents, maxBytes: 6);
    final http = Dio()..httpClientAdapter = AudioResponse();
    final stream = SongStream(
      Uri.https('example.test', '/audio'),
      'standard',
      'mp3',
    );
    try {
      final outcomes = await Future.wait([
        for (var id = 1; id <= 3; id++)
          () async {
            try {
              await cache.save(http, 'a', fixtureSong(id), stream);
              return true;
            } on DownloadSpaceError {
              return false;
            }
          }(),
      ]);
      expect(outcomes.where((v) => v).length, 1);
      expect(await cache.privateSize(), 4);
      expect(cache.transfers.value, isEmpty);
      cache.maxBytes = 1;
      await prefs.setString('downloadTree', 'content://test/tree/music');
      await Future.wait([
        for (var id = 10; id <= 12; id++)
          cache.save(http, 'a', fixtureSong(id), stream),
      ]);
      expect(documents.files.length, 3);
      expect(await cache.privateSize(), 4);
      expect(await cache.size(), 16);
      await prefs.remove('downloadTree');
      cache.maxBytes = 8;
      await cache.save(http, 'a', fixtureSong(20), stream);
      expect(await cache.privateSize(), 8);
      await expectLater(
        cache.save(http, 'a', fixtureSong(21), stream),
        throwsA(isA<DownloadSpaceError>()),
      );
      expect(
        (await directory.list().toList()).any((f) => f.path.contains('.part')),
        false,
      );
    } finally {
      http.close();
      cache.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('three source lookups have independent progress and account switch discards all late URLs', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = FakeApi(),
        directory = await Directory.systemTemp.createTemp('parallel-handler');
    final auth = AuthService(api);
    final cache = AudioCache(directory);
    final handler = MusicHandler(
      api,
      auth,
      prefs,
      cache,
      audioPlayer: FakePlayer(),
    );
    try {
      final work = handler.downloadSongs('list', [
        for (var i = 1; i <= 6; i++) fixtureSong(i),
      ]);
      for (var i = 0; i < 100 && api.streamRequests.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(api.streamRequests, unorderedEquals([1, 2, 3]));
      expect(cache.transfers.value.keys, containsAll([1, 2, 3]));
      await auth.replaceFromBackup(MusicSession(credential(id: '456')));
      await handler.cancelDownload();
      for (final pending in api.streamResults.values) {
        pending.complete(
          SongStream(Uri.https('example.test', '/late.mp3'), 'standard', 'mp3'),
        );
      }
      await work;
      expect(api.streamRequests, unorderedEquals([1, 2, 3]));
      expect(handler.downloadQueue.count(DownloadStatus.cancelled), 6);
      expect(cache.transfers.value, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    } finally {
      await handler.cancelDownload();
      for (final pending in api.streamResults.values) {
        if (!pending.isCompleted) {
          pending.completeError(const MusicError('测试清理'));
        }
      }
      await handler.disposeHandler();
      await directory.delete(recursive: true);
    }
  });
}
