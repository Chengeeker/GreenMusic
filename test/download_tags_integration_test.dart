import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/audio_tags.dart';
import 'package:greenmusic/player/download_metadata.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_storage_test.dart' show Documents;
import 'support/fakes.dart';

class TaggedApi extends FakeApi {
  @override
  Future<Song> songDetail(Song song) async => Song.fromJson({
    ...song.raw,
    'time_public': '2024-02-01',
    'album': {'name': '专辑'},
  });
  @override
  Future<SongStream> stream(Song song, String quality) async {
    streamRequests.add(song.id);
    return SongStream(Uri.https('example.test', '/song'), 'standard', 'mp3');
  }
}

class TagAudioResponse extends Fake implements HttpClientAdapter {
  RequestOptions? request;
  List<int> bytes = [255, 251, 144, 0, ...List.filled(4096, 42)];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('tag settings apply to single/batch and SAF without LRC; duplicates skip after quality fallback', () async {
    SharedPreferences.setMockInitialValues({
      'downloadTags': true,
      'downloadTree': 'content://test/tree/music',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('tags-integration');
    final api = TaggedApi();
    final auth = AuthService(api), documents = Documents(prefs);
    final adapter = TagAudioResponse();
    api.http.httpClientAdapter = adapter;
    final cache = AudioCache(directory, storage: documents);
    final handler = MusicHandler(
      api,
      auth,
      prefs,
      cache,
      audioPlayer: FakePlayer(),
    );
    try {
      await handler.downloadSong(fixtureSong(1));
      expect(documents.files.length, 1);
      expect(documents.files.values.single.take(3), ascii.encode('ID3'));
      expect(documents.names.single, endsWith('.mp3'));
      final entry = (await cache.entries('anonymous')).single;
      expect(entry.song.releaseYear, '2024');
      expect(entry.bytes, documents.files.values.single.length);
      expect(entry.bytes, greaterThan(adapter.bytes.length));
      await prefs.setString('downloadQuality', 'lossless');
      await handler.downloadSongs('list', [fixtureSong(1), fixtureSong(2)]);
      expect(documents.files.length, 2);
      expect(handler.downloadQueue.items.first.status.name, 'skipped');
      expect(adapter.request!.headers['Cookie'], '');
      expect(
        (await directory.list().toList()).every(
          (f) => f.path.endsWith('.json'),
        ),
        true,
      );
    } finally {
      await handler.disposeHandler();
      await directory.delete(recursive: true);
    }
  });

  test('tag overhead counts against quota and leaves no partial or complete file', () async {
    final directory = await Directory.systemTemp.createTemp('tags-quota');
    final cache = AudioCache(directory, maxBytes: 4100);
    final http = Dio()..httpClientAdapter = TagAudioResponse();
    try {
      await expectLater(
        cache.save(
          http,
          'a',
          fixtureSong(1),
          SongStream(Uri.https('example.test', '/audio'), 'standard', 'mp3'),
          tags: const AudioTags(title: 'Title'),
        ),
        throwsA(isA<MusicError>()),
      );
      expect(await directory.list().toList(), isEmpty);
      final interrupted = File(
        '${cache.file('a', fixtureSong(1), SongStream(Uri(), 'standard', 'mp3')).path}.part.tags.part',
      );
      await interrupted.writeAsString('partial');
      await cache.cleanupInterrupted();
      expect(await interrupted.exists(), false);
    } finally {
      cache.dispose();
      http.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'cover fetch omits credentials and rejects invalid or oversized images',
    () async {
      final adapter = TagAudioResponse();
      final http = Dio()..httpClientAdapter = adapter;
      try {
        await expectLater(
          downloadMetadata(
            http,
            Song.fromJson({
              ...fixtureSong(1).raw,
              'album': {'mid': 'cover'},
            }),
            '',
            CancelToken(),
          ),
          throwsA(isA<MusicError>()),
        );
        expect(adapter.request!.headers['Cookie'], '');
        adapter.bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQWBAAAAH0ARFrslX0AAAAAElFTkSuQmCC',
        );
        final valid = await downloadMetadata(
          http,
          Song.fromJson({
            ...fixtureSong(1).raw,
            'album': {'mid': 'cover'},
          }),
          '',
          CancelToken(),
        );
        expect(valid.mime, 'image/png');
        expect((valid.width, valid.height), (1, 1));
        expect(valid.cover, adapter.bytes);
        adapter.bytes = List.filled(5 * 1024 * 1024 + 1, 0);
        await expectLater(
          downloadMetadata(
            http,
            Song.fromJson({
              ...fixtureSong(1).raw,
              'album': {'mid': 'cover'},
            }),
            '',
            CancelToken(),
          ),
          throwsA(isA<MusicError>()),
        );
      } finally {
        http.close();
      }
    },
  );
}
