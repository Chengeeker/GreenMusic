import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'download_storage.dart';

class DownloadedSong {
  const DownloadedSong(
    this.song,
    this.file,
    this.quality,
    this.format,
    this.bytes,
    this.date, {
    this.documentUri,
  });
  final Song song;
  final File file;
  final String quality, format;
  final int bytes;
  final DateTime date;
  final String? documentUri;
  SongStream get stream => SongStream(
    documentUri == null ? Uri.file(file.path) : Uri.parse(documentUri!),
    quality,
    format,
  );
}

class SongDownloadProgress {
  const SongDownloadProgress(
    this.account,
    this.song,
    this.received,
    this.total,
  );
  final String account;
  final Song song;
  final int received, total;
  double? get fraction => total > 0 ? (received / total).clamp(0, 1) : null;
}

class AudioCache {
  AudioCache(
    this.directory, {
    this.legacyDirectory,
    this.maxBytes = 256 * 1024 * 1024,
    this.storage,
  });
  final Directory directory;
  final Directory? legacyDirectory;
  final DownloadStorage? storage;
  final changes = ValueNotifier<int>(0);
  final progress = ValueNotifier<SongDownloadProgress?>(null);
  CancelToken? _download;
  Future<void>? _pending;
  int maxBytes;
  static final _audioName = RegExp(
    r'^[a-f0-9]{16}-([1-9]\d*)-(standard|exhigh|lossless)\.(mp3|flac)$',
  );

  String _scope(String account) =>
      sha256.convert(utf8.encode(account)).toString().substring(0, 16);
  String _name(String account, Song song, SongStream stream) =>
      '${_scope(account)}-${song.id}-${stream.quality}.${stream.format}';
  File file(String account, Song song, SongStream stream) =>
      File('${directory.path}/${_name(account, song, stream)}');
  Iterable<Directory> get _directories => [directory, ?legacyDirectory];
  File _lyricsFile(File audio) =>
      File(audio.path.replaceFirst(RegExp(r'\.(mp3|flac)$'), '.lrc'));

  // Run before the player starts: a killed process cannot execute download finally blocks.
  Future<void> cleanupInterrupted() async {
    if (_pending != null) return;
    for (final dir in _directories) {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final base = name.endsWith('.lrc.part')
            ? name.substring(0, name.length - 9)
            : name.endsWith('.part')
            ? name.substring(0, name.length - 5)
            : name.endsWith('.json.tmp')
            ? name.substring(0, name.length - 9)
            : '';
        if (_audioName.hasMatch(base)) {
          await entry.delete();
        }
      }
    }
  }

  Future<List<File>> _audioFiles() async {
    final result = <String, File>{};
    for (final dir in _directories) {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && _audioName.hasMatch(name)) {
          result.putIfAbsent(name, () => entry);
        }
      }
    }
    return result.values.toList();
  }

  Future<int> size() async {
    var total = 0;
    for (final file in await _audioFiles()) {
      total += await file.length();
    }
    for (final entry in await _externalEntries(checkExists: false)) {
      try {
        if (storage != null && !await storage!.exists(entry.documentUri!)) {
          continue;
        }
      } on MusicError {
        // Count inaccessible files conservatively until their folder is authorized again.
      }
      total += entry.bytes;
    }
    return total;
  }

  Future<DownloadedSong?> _external(
    File local, {
    bool checkExists = true,
  }) async {
    if (await local.exists()) return null;
    final metadata = File('${local.path}.json');
    if (!await metadata.exists() || await metadata.length() > 32768) {
      return null;
    }
    try {
      final data = obj(jsonDecode(await metadata.readAsString()));
      final saved = obj(data['download']);
      final uri = saved['uri'];
      final match = _audioName.firstMatch(local.uri.pathSegments.last);
      if (match == null ||
          uri is! String ||
          Uri.tryParse(uri)?.scheme != 'content' ||
          saved['bytes'] is! int ||
          (saved['bytes'] as int) <= 0) {
        return null;
      }
      if (checkExists && (storage == null || !await storage!.exists(uri))) {
        return null;
      }
      final song = Song.fromJson(data);
      if (song.id != int.parse(match[1]!)) return null;
      return DownloadedSong(
        song,
        local,
        match[2]!,
        match[3]!,
        saved['bytes'] as int,
        DateTime.tryParse('${saved['date']}') ?? DateTime(2000),
        documentUri: uri,
      );
    } on FormatException {
      return null;
    }
  }

  Future<List<DownloadedSong>> _externalEntries({
    bool checkExists = true,
    String? scope,
  }) async {
    final result = <DownloadedSong>[];
    if (!await directory.exists()) return result;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final local = File(entry.path.substring(0, entry.path.length - 5));
      if (!_audioName.hasMatch(local.uri.pathSegments.last)) continue;
      if (scope != null && !local.uri.pathSegments.last.startsWith('$scope-')) {
        continue;
      }
      final external = await _external(local, checkExists: checkExists);
      if (external != null) result.add(external);
    }
    return result;
  }

  Future<DownloadedSong?> find(
    String account,
    Song song,
    String preferred, {
    bool exact = false,
  }) async {
    for (final quality
        in exact
            ? {preferred}
            : {preferred, 'lossless', 'exhigh', 'standard'}) {
      final format = quality == 'lossless' ? 'flac' : 'mp3';
      final stream = SongStream(Uri(), quality, format);
      for (final dir in _directories) {
        final local = File('${dir.path}/${_name(account, song, stream)}');
        final external = await _external(local);
        if (external != null) return external;
        if (await local.exists() && await local.length() > 0) {
          final stat = await local.stat();
          return DownloadedSong(
            song,
            local,
            quality,
            format,
            stat.size,
            stat.modified,
          );
        }
      }
    }
    return null;
  }

  Future<List<DownloadedSong>> entries(
    String account, {
    List<Song> knownSongs = const [],
  }) async {
    final known = {for (final song in knownSongs) song.id: song};
    final result = await _externalEntries(scope: _scope(account));
    for (var local in await _audioFiles()) {
      final name = local.uri.pathSegments.last;
      if (!name.startsWith('${_scope(account)}-')) continue;
      final match = _audioName.firstMatch(name)!;
      final id = int.parse(match[1]!);
      var song = known[id] ?? Song.fromJson({'id': id, 'title': '歌曲 $id'});
      final metadata = File('${local.path}.json');
      if (await metadata.exists() && await metadata.length() <= 32768) {
        try {
          final saved = Song.fromJson(
            obj(jsonDecode(await metadata.readAsString())),
          );
          if (saved.id == id && saved.name.isNotEmpty) song = saved;
        } on FormatException {
          /* Older files remain playable without metadata. */
        }
      }
      // Preserve old manually saved files when moving them to persistent storage.
      if (local.parent.absolute.uri != directory.absolute.uri) {
        await directory.create(recursive: true);
        try {
          local = await local.rename('${directory.path}/$name');
          if (song.mid.isNotEmpty) await _metadata(local, song);
        } on FileSystemException {
          /* Keep the original usable if migration fails. */
        }
      }
      final stat = await local.stat();
      if (stat.size > 0) {
        result.add(
          DownloadedSong(
            song,
            local,
            match[2]!,
            match[3]!,
            stat.size,
            stat.modified,
          ),
        );
      }
    }
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  Future<void> save(
    Dio http,
    String account,
    Song song,
    SongStream stream, {
    String? lyrics,
  }) async {
    if (_pending != null) throw const MusicError('已有歌曲正在下载，请稍候');
    final cancel = CancelToken();
    _download = cancel;
    progress.value = SongDownloadProgress(account, song, 0, 0);
    final work = _save(http, account, song, stream, cancel, lyrics);
    _pending = work;
    try {
      await work;
      changes.value++;
    } finally {
      _download = null;
      _pending = null;
      progress.value = null;
    }
  }

  Future<void> _metadata(
    File audio,
    Song song, {
    Map<String, Object?>? download,
  }) async {
    // Store song metadata only, without signed audio URLs or credentials.
    final temp = File('${audio.path}.json.tmp');
    try {
      await temp.writeAsString(
        jsonEncode({
          'download': ?download,
          'id': song.id,
          'mid': song.mid,
          'title': song.name,
          'interval': song.duration.inSeconds,
          'singer': [
            for (final artist in song.artists)
              {'id': artist.id, 'mid': artist.mid, 'name': artist.name},
          ],
          'album': {
            'id': song.album.id,
            'mid': song.album.mid,
            'name': song.album.name,
          },
          'file': {'media_mid': song.mediaMid},
        }),
      );
      await temp.rename('${audio.path}.json');
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _save(
    Dio http,
    String account,
    Song song,
    SongStream stream,
    CancelToken cancel,
    String? lyrics,
  ) async {
    await directory.create(recursive: true);
    final target = file(account, song, stream);
    final destination = storage?.tree;
    if (await _external(target) != null) return;
    if (await target.exists() && await target.length() > 0) {
      await _metadata(target, song);
      return;
    }
    final used = await size();
    if (used >= maxBytes) throw const MusicError('下载空间已满，请在“下载歌曲”中删除歌曲或提高空间上限');
    final temp = File('${target.path}.part');
    try {
      final response = await http.download(
        stream.uri.toString(),
        temp.path,
        cancelToken: cancel,
        options: Options(
          headers: {'Cookie': '', 'User-Agent': 'QQMusic 14090008(android 10)'},
        ),
        onReceiveProgress: (count, total) {
          progress.value = SongDownloadProgress(account, song, count, total);
          if (used + count > maxBytes || total > 0 && used + total > maxBytes) {
            cancel.cancel('download quota');
          }
        },
      );
      final contentType = response.headers.value('content-type') ?? '';
      final length = await temp.length();
      if (response.statusCode != 200 ||
          length == 0 ||
          contentType.contains('text/') ||
          contentType.contains('json')) {
        throw const MusicError('音源未返回完整音频，未保存下载');
      }
      final expected = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (expected != null && expected != length) {
        throw const MusicError('歌曲未完整下载，请重试');
      }
      if (used + length > maxBytes) {
        throw const MusicError('下载空间不足，请删除部分已下载歌曲后重试');
      }
      if (cancel.isCancelled) {
        throw cancel.cancelError!;
      }
      final lrc = File('${target.path}.lrc.part');
      String? document, lyricsDocument;
      try {
        if (lyrics != null && lyrics.isNotEmpty) {
          await lrc.writeAsString(lyrics, flush: true);
        }
        if (destination != null) {
          final name =
              '${song.name} - ${song.artistNames} [${song.id}-${stream.quality}]'
                  .replaceAll(RegExp(r'[\x00-\x1f/\\]'), '_');
          final base = name.runes.take(110).map(String.fromCharCode).join();
          document = await storage!.write(
            destination,
            '$base.${stream.format}',
            temp.path,
            stream.format == 'flac' ? 'audio/flac' : 'audio/mpeg',
          );
          if (cancel.isCancelled) throw cancel.cancelError!;
          if (await lrc.exists()) {
            lyricsDocument = await storage!.write(
              destination,
              '$base.lrc',
              lrc.path,
              'text/plain',
            );
          }
          if (cancel.isCancelled) throw cancel.cancelError!;
          await _metadata(
            target,
            song,
            download: {
              'uri': document,
              'lyricsUri': lyricsDocument,
              'bytes': length,
              'date': DateTime.now().toIso8601String(),
            },
          );
        } else {
          await temp.rename(target.path);
          if (await lrc.exists()) await lrc.rename(_lyricsFile(target).path);
          await _metadata(target, song);
        }
      } catch (_) {
        if (lyricsDocument != null) await storage!.delete(lyricsDocument);
        if (document != null) await storage!.delete(document);
        if (await target.exists()) await target.delete();
        final localLyrics = _lyricsFile(target);
        if (await localLyrics.exists()) await localLyrics.delete();
        rethrow;
      } finally {
        if (await lrc.exists()) await lrc.delete();
      }
    } on DioException {
      if (cancel.cancelError?.error == 'download quota') {
        throw const MusicError('下载空间不足，请删除歌曲或提高空间上限');
      }
      rethrow;
    } finally {
      // Dio can report cancellation before its writer closes on platforms that lock open files.
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          if (await temp.exists()) await temp.delete();
          break;
        } on FileSystemException {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 10 * (attempt + 1)),
          );
        }
      }
    }
  }

  Future<void> cancel() async {
    _download?.cancel('download cancelled');
    try {
      await _pending;
    } catch (_) {
      /* The owner reports the error and removes partial files. */
    }
  }

  Future<void> remove(String account, DownloadedSong entry) async {
    if (_pending != null) throw const MusicError('请先等待下载结束或取消下载');
    final expected = _name(account, entry.song, entry.stream);
    if (!_directories.any(
      (dir) =>
          File('${dir.path}/$expected').absolute.uri == entry.file.absolute.uri,
    )) {
      throw const MusicError('下载文件不属于当前账号');
    }
    await _removeFiles(entry);
    changes.value++;
  }

  Future<void> _removeFiles(DownloadedSong entry) async {
    if (await entry.file.exists()) await entry.file.delete();
    final metadata = File('${entry.file.path}.json');
    if (entry.documentUri != null && await metadata.exists()) {
      final saved = obj(
        obj(jsonDecode(await metadata.readAsString()))['download'],
      );
      final lyrics = saved['lyricsUri'];
      if (lyrics is String && await storage!.exists(lyrics)) {
        await storage!.delete(lyrics);
      }
      if (await storage!.exists(entry.documentUri!)) {
        await storage!.delete(entry.documentUri!);
      }
    }
    final lyrics = _lyricsFile(entry.file);
    if (await lyrics.exists()) await lyrics.delete();
    if (await metadata.exists()) await metadata.delete();
  }

  Future<void> clear({String? account}) async {
    await cancel();
    for (final entry in await _externalEntries()) {
      if (account == null ||
          entry.file.uri.pathSegments.last.startsWith('${_scope(account)}-')) {
        await _removeFiles(entry);
      }
    }
    for (final dir in _directories) {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File &&
            (account == null ||
                entry.uri.pathSegments.last.startsWith(
                  '${_scope(account)}-',
                ))) {
          await entry.delete();
        }
      }
    }
    changes.value++;
  }

  void dispose() {
    changes.dispose();
    progress.dispose();
  }
}
