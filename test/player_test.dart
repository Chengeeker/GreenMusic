import 'dart:io';
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';

import 'support/fakes.dart';

class CountingLyricsApi extends FakeApi {
  final pending = <int, Completer<List<LyricLine>>>{};
  final requests = <int, int>{};
  @override
  Future<List<LyricLine>> lyrics(Song song) {
    requests.update(song.id, (count) => count + 1, ifAbsent: () => 1);
    return pending[song.id]?.future ?? super.lyrics(song);
  }
}

Future<void> until(bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

SongStream fixtureStream(int id) => SongStream(
  Uri.parse('https://dl.stream.qqmusic.qq.com/$id.mp3'),
  'standard',
  'mp3',
);

void main() {
  late FakeApi api;
  late FakePlayer player;
  late MusicHandler handler;
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    api = FakeApi();
    player = FakePlayer();
    directory = await Directory.systemTemp.createTemp(
      'greenmusic-player-test-',
    );
    handler = MusicHandler(
      api,
      AuthService(api),
      await SharedPreferences.getInstance(),
      AudioCache(directory),
      audioPlayer: player,
    );
  });
  tearDown(() async {
    await handler.disposeHandler();
    api.http.close(force: true);
    await directory.delete(recursive: true);
  });
  test(
    'adding the first queue song exposes paused playback controls',
    () async {
      await handler.addSong(fixtureSong(1));
      expect(handler.current!.id, 1);
      expect(handler.index, 0);
      expect(player.playing, isFalse);
    },
  );
  test('lyrics share pending results, keep failures until retry and bound the cache', () async {
    final lyricApi = CountingLyricsApi();
    final shared = MusicHandler(
      lyricApi,
      AuthService(lyricApi),
      handler.prefs,
      AudioCache(directory),
      audioPlayer: FakePlayer(),
    );
    try {
      lyricApi.pending[1] = Completer<List<LyricLine>>();
      final first = shared.lyricsFor(fixtureSong(1));
      expect(identical(first, shared.lyricsFor(fixtureSong(1))), isTrue);
      expect(lyricApi.requests[1], 1);
      lyricApi.pending[1]!.complete(const [LyricLine(Duration.zero, '缓存歌词')]);
      expect((await first).single.text, '缓存歌词');
      lyricApi.pending[2] = Completer<List<LyricLine>>();
      final failed = shared.lyricsFor(fixtureSong(2));
      lyricApi.pending[2]!.completeError(const MusicError('暂时失败'));
      await Future<void>.delayed(Duration.zero);
      await expectLater(failed, throwsA(isA<MusicError>()));
      expect(identical(failed, shared.lyricsFor(fixtureSong(2))), isTrue);
      expect(lyricApi.requests[2], 1);
      lyricApi.pending[2] = Completer<List<LyricLine>>();
      final revision = shared.changes.value;
      final retry = shared.lyricsFor(fixtureSong(2), refresh: true);
      expect(shared.changes.value, revision + 1);
      lyricApi.pending[2]!.complete(const [LyricLine(Duration.zero, '重试成功')]);
      expect((await retry).single.text, '重试成功');
      expect(lyricApi.requests[2], 2);
      for (var id = 3; id <= 12; id++) {
        await shared.lyricsFor(fixtureSong(id));
      }
      await shared.lyricsFor(fixtureSong(1));
      expect(lyricApi.requests[1], 2);
    } finally {
      await shared.disposeHandler();
      lyricApi.http.close(force: true);
    }
  });
  test('native media card has clean metadata and synchronized shuffle/repeat actions', () async {
    await handler.addSong(fixtureSong(1));
    final item = handler.mediaItem.value!;
    expect(item.title, '歌曲 1');
    expect(item.displayTitle, item.title);
    expect(item.displaySubtitle, item.artist);
    expect(item.displayDescription, isNull);
    expect(item.album, '测试专辑');
    expect(item.duration, const Duration(minutes: 3));
    expect(item.artHeaders?['Referer'], 'https://y.qq.com/');
    expect(item.artHeaders?.containsKey('Cookie'), isFalse);
    var state = handler.playbackState.value;
    expect(state.controls.map((c) => c.action), [
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.skipToNext,
      MediaAction.custom,
      MediaAction.custom,
    ]);
    expect(state.controls.map((c) => c.label).take(3), ['上一首', '播放', '下一首']);
    expect(state.controls.take(3).map((c) => c.androidIcon), [
      'drawable/ic_media_skip_previous',
      'drawable/ic_media_play_arrow',
      'drawable/ic_media_skip_next',
    ]);
    expect(state.androidCompactActionIndices, [0, 1, 2]);
    expect(state.systemActions, contains(MediaAction.seek));
    final shuffleAction = state.controls[3].customAction!.name;
    final repeatAction = state.controls[4].customAction!.name;
    expect(state.controls[3].androidIcon, 'drawable/ic_media_shuffle');
    await handler.customAction(shuffleAction);
    expect(handler.shuffle, isTrue);
    expect(handler.prefs.getBool('shuffle'), isTrue);
    expect(
      handler.playbackState.value.controls[3].androidIcon,
      'drawable/ic_media_shuffle_on',
    );
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(handler.playbackState.value.controls[3].label, '开启随机播放');
    for (final mode in [
      AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.one,
      AudioServiceRepeatMode.none,
    ]) {
      await handler.customAction(repeatAction);
      expect(handler.repeat, mode);
      expect(handler.prefs.getInt('repeat'), mode.index);
      expect(handler.playbackState.value.repeatMode, mode);
    }
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    expect(
      handler.playbackState.value.controls[4].androidIcon,
      'drawable/ic_media_repeat_one_on',
    );
    await handler.setRepeatMode(AudioServiceRepeatMode.group);
    expect(handler.playbackState.value.controls[4].label, '循环：分组模式，切换为关闭');
    await handler.customAction(repeatAction);
    expect(handler.repeat, AudioServiceRepeatMode.none);
    player.playing = true;
    player.emit();
    await until(() => handler.playbackState.value.playing);
    state = handler.playbackState.value;
    expect(state.controls[1].action, MediaAction.pause);
    expect(state.controls[1].label, '暂停');
    expect(state.controls[1].androidIcon, 'drawable/ic_media_pause');
    expect(state.controls.any((c) => c.action == MediaAction.stop), isFalse);
    await handler.stop();
    expect(handler.currentStream, isNull);
    expect(handler.playbackState.value.playing, isFalse);
  });
  test(
    'late URL from a previous selection cannot replace the new song',
    () async {
      final first = handler.playSongs([fixtureSong(1), fixtureSong(2)]);
      await until(() => api.streamRequests.contains(1));
      final second = handler.skipToQueueItem(1);
      await until(() => api.streamRequests.contains(2));
      api.streamResults[2]!.complete(fixtureStream(2));
      await second;
      api.streamResults[1]!.complete(fixtureStream(1));
      await first;
      expect(handler.current!.id, 2);
      expect(player.loadedUri!.path, '/2.mp3');
      expect(player.playCount, 1);
    },
  );
  test('cancelling a download during source lookup ignores its late URL and duplicate taps', () async {
    final downloading = expectLater(
      handler.downloadSong(fixtureSong(11)),
      throwsA(isA<MusicError>()),
    );
    await until(() => api.streamRequests.contains(11));
    expect(handler.cache.progress.value!.song.id, 11);
    await expectLater(
      handler.downloadSong(fixtureSong(12)),
      throwsA(isA<MusicError>()),
    );
    expect(api.streamRequests, [11]);
    await handler.cancelDownload();
    api.streamResults[11]!.complete(fixtureStream(11));
    await downloading;
    expect(handler.cache.progress.value, isNull);
    expect(await handler.cache.size(), 0);
  });
  test('pause while fetching URL keeps new audio paused', () async {
    final loading = handler.playSongs([fixtureSong(1)]);
    await until(() => api.streamRequests.contains(1));
    await handler.pause();
    expect(handler.playRequested, isFalse);
    api.streamResults[1]!.complete(fixtureStream(1));
    await loading;
    expect(player.playing, isFalse);
    expect(player.playCount, 0);
    await handler.play();
    expect(player.playing, isTrue);
  });
  test(
    'stop cancels pending selection and cannot resurrect playback',
    () async {
      final loading = handler.playSongs([fixtureSong(1)]);
      await until(() => api.streamRequests.contains(1));
      await handler.stop();
      api.streamResults[1]!.complete(fixtureStream(1));
      await loading;
      expect(player.loadedUri, isNull);
      expect(player.playing, isFalse);
      expect(handler.loading, isFalse);
    },
  );
  test(
    'permission rejection leaves an error and never starts the decoder',
    () async {
      final loading = handler.playSongs([fixtureSong(1)]);
      await until(() => api.streamRequests.contains(1));
      api.streamResults[1]!.completeError(const MusicError('需要相应权限'));
      await loading;
      expect(handler.errors.value, '需要相应权限');
      expect(player.loadedUri, isNull);
      expect(player.playing, isFalse);
    },
  );
  test('downloaded audio plays offline within its account without another source request', () async {
    final song = fixtureSong(1),
        stream = fixtureStream(1),
        cache = handler.cache;
    expect(
      cache.file('123', song, stream).path,
      isNot(cache.file('456', song, stream).path),
    );
    await cache.file('anonymous', song, stream).writeAsBytes([1, 2, 3]);
    await handler.playSongs([song]);
    expect(api.streamRequests, isEmpty);
    expect(player.loadedUri!.scheme, 'file');
    await handler.removeDownload(
      (await cache.entries('anonymous', knownSongs: [song])).single,
    );
    expect(await cache.size(), 0);
    expect(player.playing, isFalse);
  });
  test('offline download selection preserves quality and removing the active file stops playback', () async {
    final song = fixtureSong(8);
    const quality = 'lossless';
    final stream = SongStream(Uri(), quality, 'flac');
    await handler.cache.file('anonymous', song, stream).writeAsBytes([1, 2, 3]);
    final entry = (await handler.cache.entries(
      'anonymous',
      knownSongs: [song],
    )).single;
    await handler.playDownloaded(entry);
    expect(api.streamRequests, isEmpty);
    expect(handler.currentStream!.quality, quality);
    expect(player.playing, isTrue);
    handler.currentStream = SongStream(
      Uri.file('${directory.path}/legacy-file.flac'),
      quality,
      'flac',
    );
    await handler.removeDownload(entry);
    expect(player.playing, isFalse);
    expect(await handler.cache.entries('anonymous'), isEmpty);
  });
  test('removing current queue item does not preserve a previous-track seek offset', () async {
    final loading = handler.playSongs([fixtureSong(1), fixtureSong(2)]);
    await until(() => api.streamRequests.contains(1));
    api.streamResults[1]!.complete(fixtureStream(1));
    await loading;
    await handler.seek(const Duration(seconds: 40));
    await handler.removeSong(0);
    final play = handler.play();
    await until(() => api.streamRequests.contains(2));
    api.streamResults[2]!.complete(fixtureStream(2));
    await play;
    expect(handler.current!.id, 2);
    expect(player.position, Duration.zero);
  });
}
