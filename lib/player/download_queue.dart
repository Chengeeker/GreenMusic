import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';

class DownloadOptions {
  const DownloadOptions({
    required this.quality,
    this.lyrics = false,
    this.tags = false,
    this.tree,
    this.concurrent = 1,
    this.connections = 1,
    this.speedKiB = 0,
    this.retries = 0,
  });
  factory DownloadOptions.fromPrefs(SharedPreferences prefs, String quality) =>
      DownloadOptions(
        quality: quality,
        lyrics: prefs.getBool('downloadLyrics') ?? false,
        tags: prefs.getBool('downloadTags') ?? false,
        tree: prefs.getString('downloadTree'),
        concurrent: (prefs.getInt('downloadConcurrent') ?? 3).clamp(1, 5),
        connections: [1, 2, 4].contains(prefs.getInt('downloadConnections'))
            ? prefs.getInt('downloadConnections')!
            : 1,
        speedKiB: (prefs.getInt('downloadSpeedKiB') ?? 0).clamp(0, 10240),
        retries: (prefs.getInt('downloadRetries') ?? 2).clamp(0, 3),
      );
  final String quality;
  final bool lyrics, tags;
  final String? tree;
  final int concurrent, connections, speedKiB, retries;
}

enum DownloadStatus { queued, running, saved, skipped, failed, cancelled }

class DownloadItem {
  DownloadItem(this.song);
  final Song song;
  DownloadStatus status = DownloadStatus.queued;
  String? error;
  Object? failure;
  int attempt = 0;
}

class DownloadQueue extends ChangeNotifier {
  List<DownloadItem> items = [];
  String title = '', owner = '';
  DownloadOptions? options;
  bool busy = false, cancelled = false;
  String? stopReason;
  Completer<void>? _cancelled;
  int get finished => items
      .where(
        (i) =>
            ![DownloadStatus.queued, DownloadStatus.running].contains(i.status),
      )
      .length;
  int count(DownloadStatus status) =>
      items.where((i) => i.status == status).length;

  Future<void> run({
    required String title,
    required String owner,
    required List<Song> songs,
    required DownloadOptions options,
    required String Function() account,
    required Future<bool> Function(Song, DownloadOptions) download,
  }) async {
    if (busy) throw const MusicError('已有批量下载任务，请先等待或取消');
    final seen = <int>{};
    items = songs
        .where((s) => s.valid && seen.add(s.id))
        .map(DownloadItem.new)
        .toList();
    if (items.isEmpty) throw const MusicError('请至少选择一首歌曲');
    this.title = title;
    this.owner = owner;
    this.options = options;
    busy = true;
    cancelled = false;
    stopReason = null;
    _cancelled = Completer<void>();
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (!cancelled &&
          stopReason == null &&
          account() == owner &&
          next < items.length) {
        final item = items[next++];
        item.status = DownloadStatus.running;
        notifyListeners();
        for (var attempt = 0; ; attempt++) {
          item.attempt = attempt;
          if (attempt > 0) {
            item.error = null;
            notifyListeners();
          }
          try {
            final saved = await download(item.song, options);
            item.status = saved ? DownloadStatus.saved : DownloadStatus.skipped;
            item.error = null;
            break;
          } catch (e) {
            final transient =
                e is DioException &&
                !CancelToken.isCancel(e) &&
                (e.response == null ||
                    [408, 429].contains(e.response?.statusCode) ||
                    (e.response?.statusCode ?? 0) >= 500);
            if (transient &&
                attempt < options.retries &&
                !cancelled &&
                stopReason == null &&
                account() == owner) {
              item.error = '网络暂时不可用，准备第 ${attempt + 1} 次重试';
              notifyListeners();
              await Future.any([
                Future<void>.delayed(Duration(seconds: 1 << attempt)),
                _cancelled!.future,
              ]);
              if (!cancelled && stopReason == null && account() == owner) {
                continue;
              }
            }
            item.status = cancelled || account() != owner
                ? DownloadStatus.cancelled
                : DownloadStatus.failed;
            item.failure = e;
            item.error = e is MusicError ? e.message : '下载失败，请检查网络或存储空间后重试';
            if (e is DownloadSpaceError) {
              stopReason = e.message;
            }
            break;
          }
        }
        notifyListeners();
      }
    }

    try {
      await Future.wait(
        List.generate(options.concurrent.clamp(1, 5), (_) => worker()),
      );
    } finally {
      for (final item in items) {
        if (item.status == DownloadStatus.queued) {
          item.status = DownloadStatus.cancelled;
        }
      }
      busy = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (!busy) return;
    cancelled = true;
    if (_cancelled?.isCompleted == false) _cancelled!.complete();
    notifyListeners();
  }
}

Future<List<Song>> loadDownloadSongs(
  Future<SongPage> Function(int) loader, {
  required bool Function() active,
}) async {
  final result = <Song>[];
  final seen = <int>{};
  var offset = 0;
  while (active()) {
    final page = await loader(offset);
    if (!active()) throw const MusicError('歌单读取已取消或账号已切换');
    final fresh = page.items.where((s) => seen.add(s.id)).toList();
    result.addAll(fresh);
    if (!page.more) return result;
    if (page.nextOffset <= offset || fresh.isEmpty) {
      throw const MusicError('歌单分页未前进，请重试');
    }
    offset = page.nextOffset;
  }
  throw const MusicError('歌单读取已取消或账号已切换');
}
