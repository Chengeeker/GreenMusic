import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/auth_service.dart';
import '../data/models.dart';
import '../data/qq_music_api.dart';
import 'audio_cache.dart';
import 'download_metadata.dart';
import 'download_queue.dart';
import 'download_transfer.dart';

String encodeLrc(List<LyricLine> lines) => lines
    .map((line) {
      final ms = line.time.inMilliseconds;
      final time =
          '[${(ms ~/ 60000).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${((ms % 1000) ~/ 10).toString().padLeft(2, '0')}]';
      final text = line.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
      final translated = line.translation.replaceAll(RegExp(r'[\r\n]+'), ' ');
      return '$time$text${translated.isEmpty ? '' : '\n$time$translated'}';
    })
    .join('\n');

class MusicHandler extends BaseAudioHandler with SeekHandler {
  MusicHandler(
    this.api,
    this.auth,
    this.prefs,
    this.cache, {
    AudioPlayer? audioPlayer,
  }) : player =
           audioPlayer ??
           AudioPlayer(
             userAgent: qqUserAgent,
             useProxyForRequestHeaders: false,
           ) {
    _subscriptions.add(player.playbackEventStream.listen((_) => _broadcast()));
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        _broadcast();
        if (state.processingState == ProcessingState.completed && !_loading) {
          unawaited(_completed());
        }
      }),
    );
    _subscriptions.add(
      player.errorStream.listen(
        (e) => _failed(const MusicError('音频解码或播放失败，请重试或切换音质')),
      ),
    );
    _subscriptions.add(
      player.durationStream.listen((duration) {
        final item = mediaItem.value;
        if (item != null && duration != null) {
          mediaItem.add(item.copyWith(duration: duration));
        }
      }),
    );
    _restoreQueue();
    auth.addListener(_downloadAccountChanged);
  }
  final QqMusicApi api;
  final AuthService auth;
  final SharedPreferences prefs;
  final AudioCache cache;
  final AudioPlayer player;
  final changes = ValueNotifier<int>(0);
  final errors = ValueNotifier<String?>(null);
  final downloadQueue = DownloadQueue();
  Future<void>? _batchWork;
  String? _downloadOwner;
  final _metadataCancels = <int, CancelToken>{};
  DownloadLimiter? _batchLimiter;

  void _downloadAccountChanged() {
    if (_downloadOwner != null && _downloadOwner != account ||
        downloadQueue.busy && downloadQueue.owner != account) {
      unawaited(cancelDownload());
    }
  }

  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _lyricCache = <(int, String), Future<List<LyricLine>>>{};
  List<Song> tracks = [];
  int index = -1, _generation = 0, _downloadGeneration = 0;
  bool _loading = false, _wantPlay = false, shuffle = false;
  AudioServiceRepeatMode repeat = AudioServiceRepeatMode.none;
  SongStream? currentStream;
  Song? get current =>
      index >= 0 && index < tracks.length ? tracks[index] : null;
  bool get loading => _loading;
  bool get playRequested => _wantPlay;
  String get quality => prefs.getString('quality') ?? 'standard';
  String get account => api.session?.id ?? 'anonymous';
  Future<void> configure() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  void _notify() {
    changes.value++;
    _broadcast();
  }

  Future<List<LyricLine>> lyricsFor(Song song, {bool refresh = false}) {
    final key = (song.id, song.mid);
    final cached = _lyricCache.remove(key);
    final future = !refresh && cached != null ? cached : api.lyrics(song);
    // A cached request may fail before its next view attaches a listener.
    if (refresh || cached == null) future.ignore();
    _lyricCache[key] = future;
    while (_lyricCache.length > 8) {
      _lyricCache.remove(_lyricCache.keys.first);
    }
    if (refresh) changes.value++;
    return future;
  }

  MediaItem _item(Song song) => MediaItem(
    id: '${song.id}',
    title: song.name,
    artist: song.artistNames,
    album: song.album.name,
    displayTitle: song.name,
    displaySubtitle: song.artistNames,
    artUri: song.cover.isEmpty ? null : Uri.tryParse(song.cover),
    artHeaders: const {
      'User-Agent': qqUserAgent,
      'Referer': 'https://y.qq.com/',
    },
    duration: song.duration,
  );
  void _broadcast() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious.copyWith(
            label: '上一首',
            androidIcon: 'drawable/ic_media_skip_previous',
          ),
          player.playing
              ? MediaControl.pause.copyWith(
                  label: '暂停',
                  androidIcon: 'drawable/ic_media_pause',
                )
              : MediaControl.play.copyWith(
                  label: '播放',
                  androidIcon: 'drawable/ic_media_play_arrow',
                ),
          MediaControl.skipToNext.copyWith(
            label: '下一首',
            androidIcon: 'drawable/ic_media_skip_next',
          ),
          MediaControl.custom(
            androidIcon: 'drawable/ic_media_shuffle${shuffle ? '_on' : ''}',
            label: shuffle ? '关闭随机播放' : '开启随机播放',
            name: 'com.green.music.toggleShuffle',
          ),
          MediaControl.custom(
            androidIcon:
                'drawable/ic_media_${switch (repeat) {
                  AudioServiceRepeatMode.none => 'repeat',
                  AudioServiceRepeatMode.one => 'repeat_one_on',
                  _ => 'repeat_on',
                }}',
            label: switch (repeat) {
              AudioServiceRepeatMode.none => '循环：已关闭，切换为列表循环',
              AudioServiceRepeatMode.all => '循环：列表循环，切换为单曲循环',
              AudioServiceRepeatMode.one => '循环：单曲循环，切换为关闭',
              AudioServiceRepeatMode.group => '循环：分组模式，切换为关闭',
            },
            name: 'com.green.music.cycleRepeat',
          ),
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setRepeatMode,
          MediaAction.setShuffleMode,
        },
        androidCompactActionIndices: [0, 1, 2],
        processingState: _loading
            ? AudioProcessingState.loading
            : switch (player.processingState) {
                ProcessingState.idle => AudioProcessingState.idle,
                ProcessingState.loading => AudioProcessingState.loading,
                ProcessingState.buffering => AudioProcessingState.buffering,
                ProcessingState.ready => AudioProcessingState.ready,
                ProcessingState.completed => AudioProcessingState.completed,
              },
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: index < 0 ? null : index,
        repeatMode: repeat,
        shuffleMode: shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  void _restoreQueue() {
    try {
      final saved = jsonDecode(prefs.getString('queue') ?? '[]');
      tracks = songs(saved);
      index = tracks.isEmpty
          ? -1
          : (prefs.getInt('queueIndex') ?? 0).clamp(0, tracks.length - 1);
      repeat =
          AudioServiceRepeatMode.values[(prefs.getInt('repeat') ?? 0).clamp(
            0,
            AudioServiceRepeatMode.values.length - 1,
          )];
      shuffle = prefs.getBool('shuffle') ?? false;
      queue.add(tracks.map(_item).toList());
      mediaItem.add(current == null ? null : _item(current!));
    } on FormatException {
      tracks = [];
      index = -1;
    }
  }

  void reloadSavedState() {
    currentStream = null;
    cache.maxBytes = (prefs.getInt('cacheLimitMb') ?? 256) * 1024 * 1024;
    _restoreQueue();
    _notify();
  }

  Future<void> _persist() async {
    await prefs.setString(
      'queue',
      jsonEncode(tracks.map((s) => s.raw).toList()),
    );
    await prefs.setInt('queueIndex', index);
  }

  Future<void> playSongs(List<Song> songs, {int start = 0}) async {
    if (songs.isEmpty || start < 0 || start >= songs.length) return;
    tracks = List.of(songs);
    queue.add(tracks.map(_item).toList());
    await _select(start);
  }

  Future<void> _select(
    int next, {
    Duration? position,
    DownloadedSong? downloaded,
  }) async {
    if (next < 0 || next >= tracks.length) return;
    final generation = ++_generation;
    index = next;
    _loading = true;
    _wantPlay = true;
    currentStream = null;
    errors.value = null;
    final song = tracks[index];
    final owner = account;
    mediaItem.add(_item(song));
    _notify();
    try {
      // Stop immediately so the old decoder cannot play after a new selection.
      await player.stop();
      if (generation != _generation) return;
      await _persist();
      await prefs.setInt('position', position?.inMilliseconds ?? 0);
      if (generation != _generation) return;
      final local = await cache.find(
        owner,
        song,
        downloaded?.quality ?? quality,
      );
      if (downloaded != null && local == null) {
        throw const MusicError('下载文件已不存在，请重新下载');
      }
      if (local == null && api.session?.expired == true) {
        await auth.ensureSession();
      }
      final stream = local?.stream ?? await api.stream(song, quality);
      if (generation != _generation) return;
      if (owner != account) throw const MusicError('账号已切换，请重新选择歌曲');
      final item = _item(song);
      await player.setAudioSource(
        AudioSource.uri(stream.uri, tag: item),
        initialPosition: position,
      );
      if (generation != _generation) return;
      currentStream = stream;
      _loading = false;
      _notify();
      if (_wantPlay) {
        unawaited(
          player.play().catchError((Object e) {
            if (generation == _generation) _failed(e);
          }),
        );
      }
      final history = songsFromHistory();
      await prefs.setString(
        'history',
        jsonEncode(
          [
            song,
            ...history.where((s) => s.id != song.id),
          ].take(100).map((s) => s.raw).toList(),
        ),
      );
    } catch (e) {
      if (generation == _generation) {
        _loading = false;
        _wantPlay = false;
        _failed(e);
      }
    }
  }

  List<Song> songsFromHistory() {
    try {
      return songs(jsonDecode(prefs.getString('history') ?? '[]'));
    } on FormatException {
      return [];
    }
  }

  void _failed(Object error) {
    _wantPlay = false;
    errors.value = error is PlayerException
        ? '音源加载或解码失败（${error.code}），请检查网络或重新下载歌曲'
        : errorText(error);
    _loading = false;
    _notify();
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: errors.value,
      ),
    );
  }

  Future<void> _completed() async {
    if (repeat == AudioServiceRepeatMode.one) {
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }
    if (index < tracks.length - 1 ||
        repeat == AudioServiceRepeatMode.all ||
        shuffle) {
      await skipToNext();
    } else {
      await pause();
      await seek(Duration.zero);
    }
  }

  @override
  Future<void> play() async {
    _wantPlay = true;
    if (current == null) return;
    if (_loading) return;
    if (currentStream == null ||
        player.processingState == ProcessingState.idle) {
      await _select(
        index,
        position: Duration(milliseconds: prefs.getInt('position') ?? 0),
      );
      return;
    }
    if (player.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero);
    }
    unawaited(player.play().catchError((Object e) => _failed(e)));
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    await player.pause();
    await prefs.setInt('position', player.position.inMilliseconds);
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    await prefs.setInt('position', position.inMilliseconds);
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _wantPlay = false;
    _loading = false;
    await player.stop();
    currentStream = null;
    _notify();
    await super.stop();
  }

  int get nextQueueIndex {
    if (tracks.isEmpty) return -1;
    var next = index + 1;
    if (shuffle && tracks.length > 1) {
      next = Random().nextInt(tracks.length - 1);
      if (next >= index) next++;
    }
    if (next >= tracks.length) next = 0;
    return next;
  }

  @override
  Future<void> skipToNext() => _select(nextQueueIndex);

  @override
  Future<void> skipToPrevious() async {
    if (player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (tracks.isNotEmpty) {
      await _select(index <= 0 ? tracks.length - 1 : index - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _select(index);
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    repeat = repeatMode;
    await prefs.setInt('repeat', repeatMode.index);
    _notify();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    shuffle = shuffleMode != AudioServiceShuffleMode.none;
    await prefs.setBool('shuffle', shuffle);
    _notify();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) {
    return switch (name) {
      'com.green.music.toggleShuffle' => setShuffleMode(
        shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
      ),
      'com.green.music.cycleRepeat' => setRepeatMode(switch (repeat) {
        AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
        _ => AudioServiceRepeatMode.none,
      }),
      _ => super.customAction(name, extras),
    };
  }

  Future<void> addSong(Song song) async {
    tracks.add(song);
    if (index < 0) {
      index = 0;
      mediaItem.add(_item(song));
    }
    queue.add(tracks.map(_item).toList());
    await _persist();
    _notify();
  }

  Future<void> removeSong(int at) async {
    if (at < 0 || at >= tracks.length) return;
    if (at == index) {
      await stop();
      tracks.removeAt(at);
      index = tracks.isEmpty ? -1 : at.clamp(0, tracks.length - 1);
      await prefs.setInt('position', 0);
    } else {
      tracks.removeAt(at);
      if (at < index) index--;
    }
    queue.add(tracks.map(_item).toList());
    mediaItem.add(current == null ? null : _item(current!));
    await _persist();
    _notify();
  }

  Future<void> cacheCurrent() async {
    final song = current;
    if (song == null) throw const MusicError('请先选择歌曲');
    await downloadSong(song);
  }

  Future<void> downloadSong(Song song, {String? quality}) async {
    await downloadSongs(
      song.name,
      [song],
      options: DownloadOptions.fromPrefs(
        prefs,
        quality ?? prefs.getString('downloadQuality') ?? this.quality,
      ),
    );
    final item = downloadQueue.items.single;
    if (item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.cancelled) {
      throw item.failure ?? const MusicError('下载已取消');
    }
  }

  Future<void> downloadSongs(
    String title,
    List<Song> songs, {
    DownloadOptions? options,
  }) async {
    if (downloadQueue.busy || cache.progress.value != null) {
      throw const MusicError('已有下载任务，请先等待或取消');
    }
    options ??= DownloadOptions.fromPrefs(
      prefs,
      prefs.getString('downloadQuality') ?? quality,
    );
    _batchLimiter = DownloadLimiter(options.speedKiB * 1024);
    final work = downloadQueue.run(
      title: title,
      owner: account,
      songs: songs,
      options: options,
      account: () => account,
      download: _downloadSong,
    );
    _batchWork = work;
    try {
      await work;
    } finally {
      if (identical(_batchWork, work)) {
        _batchWork = null;
        _batchLimiter = null;
      }
    }
  }

  Future<void> retryDownloads() async {
    if (downloadQueue.owner != account) throw const MusicError('请切回原账号后重试');
    await downloadSongs(
      downloadQueue.title,
      downloadQueue.items
          .where(
            (i) => [
              DownloadStatus.failed,
              DownloadStatus.cancelled,
            ].contains(i.status),
          )
          .map((i) => i.song)
          .toList(),
      options: downloadQueue.options,
    );
  }

  Future<bool> _downloadSong(Song song, DownloadOptions options) async {
    final generation = _downloadGeneration;
    final owner = account;
    _downloadOwner = owner;
    final cancel = CancelToken();
    _metadataCancels[song.id] = cancel;
    void check() {
      if (generation != _downloadGeneration) throw const MusicError('下载已取消');
      if (owner != account) throw const MusicError('账号已切换，请重新下载');
    }

    cache.report(SongDownloadProgress(owner, song, 0, 0, stage: '正在读取歌曲信息'));
    try {
      if (await cache.find(owner, song, options.quality, exact: true) != null) {
        check();
        return false;
      }
      check();
      if (api.session?.expired == true) await auth.ensureSession();
      check();
      if (options.tags) {
        song = await api.songDetail(song);
        check();
      }
      final stream = await api.stream(song, options.quality);
      check();
      if (await cache.find(owner, song, stream.quality, exact: true) != null) {
        check();
        return false;
      }
      final lyrics = options.lyrics || options.tags
          ? encodeLrc(await api.lyrics(song))
          : '';
      check();
      final tags = options.tags
          ? await downloadMetadata(api.http, song, lyrics, cancel)
          : null;
      check();
      await cache.save(
        api.http,
        owner,
        song,
        stream,
        lyrics: options.lyrics ? lyrics : null,
        tags: tags,
        options: options,
        limiter: downloadQueue.busy ? _batchLimiter : null,
      );
      return true;
    } finally {
      if (generation == _downloadGeneration) {
        cache.finishProgress(song.id);
        _metadataCancels.remove(song.id);
        if (_metadataCancels.isEmpty) _downloadOwner = null;
      }
    }
  }

  Future<void> cancelDownload() async {
    downloadQueue.cancel();
    for (final token in _metadataCancels.values) {
      token.cancel('download cancelled');
    }
    _metadataCancels.clear();
    _downloadOwner = null;
    final generation = ++_downloadGeneration;
    await cache.cancel();
    if (generation == _downloadGeneration) cache.clearProgress();
  }

  Future<void> playDownloaded(DownloadedSong entry) async {
    tracks = [entry.song];
    queue.add(tracks.map(_item).toList());
    await _select(0, downloaded: entry);
  }

  Future<void> removeDownload(DownloadedSong entry) async {
    // A legacy file may have moved to persistent storage after the decoder opened it.
    if (['file', 'content'].contains(currentStream?.uri.scheme) &&
        current?.id == entry.song.id &&
        currentStream?.quality == entry.quality) {
      await stop();
    }
    await cache.remove(account, entry);
  }

  @override
  Future<void> onTaskRemoved() async {
    if (!player.playing) await stop();
  }

  Future<void> disposeHandler() async {
    auth.removeListener(_downloadAccountChanged);
    await cancelDownload();
    await _batchWork;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await player.dispose();
    _lyricCache.clear();
    changes.dispose();
    errors.dispose();
    downloadQueue.dispose();
    cache.dispose();
  }
}
