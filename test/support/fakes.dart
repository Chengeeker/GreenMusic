import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/data/qq_music_api.dart';

Song fixtureSong(int id) => Song.fromJson({
  'id': id,
  'mid': 'song$id',
  'title': '歌曲 $id',
  'interval': 180,
  'singer': [
    {'id': 1, 'mid': 'artist', 'name': '歌手'},
  ],
  'album': {'id': 1, 'mid': '', 'name': '测试专辑'},
  'file': {'media_mid': 'media$id'},
});
Json envelope(Json data) => {
  'code': 0,
  'req_0': {'code': 0, 'data': data},
};
Json credential({int type = 2, String id = '123'}) => {
  'musicid': id,
  'musickey': 'fixture-secret',
  'loginType': type,
  'encryptUin': 'fixture-uin',
};

class JsonAdapter implements HttpClientAdapter {
  JsonAdapter(this.handle);
  final FutureOr<Json> Function(RequestOptions, Json) handle;
  final requests = <({RequestOptions options, Json body})>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = await requestStream?.fold<List<int>>(
      [],
      (a, b) => a..addAll(b),
    );
    final body = bytes == null || bytes.isEmpty
        ? <String, dynamic>{}
        : obj(jsonDecode(utf8.decode(bytes)));
    requests.add((options: options, body: body));
    return ResponseBody.fromString(
      jsonEncode(await handle(options, body)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakePlayer extends Fake implements AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(minutes: 3);
  @override
  Duration get bufferedPosition => duration!;
  @override
  double get speed => 1;
  Uri? loadedUri;
  int playCount = 0;
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => _positions.stream;
  void emit() => _states.add(PlayerState(playing, processingState));
  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
    emit();
  }

  @override
  Future<void> pause() async {
    playing = false;
    emit();
  }

  @override
  Future<void> play() async {
    playing = true;
    playCount++;
    emit();
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async {
    position = value ?? Duration.zero;
    _positions.add(position);
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loadedUri = (source as UriAudioSource).uri;
    position = initialPosition ?? Duration.zero;
    processingState = ProcessingState.ready;
    emit();
    return duration;
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
  }
}

class FakeApi extends QqMusicApi {
  final streamResults = <int, Completer<SongStream>>{};
  final streamRequests = <int>[];
  @override
  Future<List<MusicList>> featured() async => const [
    MusicList(id: 1, name: '测试推荐歌单'),
  ];
  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [
    LyricLine(Duration.zero, '第一句'),
    LyricLine(Duration(seconds: 10), '第二句', translation: '翻译'),
  ];
  @override
  Future<SongStream> stream(Song input, String quality) {
    streamRequests.add(input.id);
    return streamResults
        .putIfAbsent(input.id, Completer<SongStream>.new)
        .future;
  }
}
