import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/data/qq_music_api.dart';

Future<void> main() async {
  final api = QqMusicApi();
  final result = <String, dynamic>{
    'time': DateTime.now().toIso8601String(),
    'scope': 'anonymous desktop HTTP; no device playback or account acceptance',
  };
  Future<T?> probe<T>(
    String name,
    Future<T> Function() action,
    dynamic Function(T) describe,
  ) async {
    try {
      final value = await action();
      result[name] = {'ok': true, 'result': describe(value)};
      stdout.writeln('$name: OK');
      return value;
    } catch (e) {
      result[name] = {'ok': false, 'error': errorText(e)};
      stdout.writeln('$name: ${errorText(e)}');
      return null;
    }
  }

  final featured = await probe('featured', api.featured, (v) => v.length);
  final charts = await probe('charts', api.charts, (v) => v.length);
  final found = await probe(
    'search',
    () => api.search('周杰伦'),
    (v) => {'songs': v.songs.length, 'source': v.source, 'total': v.total},
  );
  if (found != null && found.songs.isNotEmpty) {
    final song = found.songs.first;
    await probe(
      'search_page_2',
      () => api.search('周杰伦', source: found.source, offset: found.nextOffset),
      (v) => v.songs.length,
    );
    await probe(
      'song_detail',
      () => api.songDetail(song),
      (v) => {'name': v.name, 'hasMediaMid': v.mediaMid.isNotEmpty},
    );
    await probe('lyrics', () => api.lyrics(song), (v) => v.length);
  }
  if (featured?.isNotEmpty == true) {
    await probe(
      'playlist',
      () => api.playlistSongs(featured!.first),
      (v) => v.length,
    );
  }
  final tracks = charts?.isNotEmpty == true
      ? await probe(
          'chart_songs',
          () => api.playlistSongs(charts!.first),
          (v) => v.length,
        )
      : null;
  SongStream? stream;
  if (tracks != null) {
    for (final song in tracks.take(3)) {
      stream = await probe(
        'stream_${song.id}',
        () => api.stream(song, 'standard'),
        (v) => {
          'format': v.format,
          'quality': v.quality,
          'scheme': v.uri.scheme,
        },
      );
      if (stream != null) break;
    }
  }
  if (stream != null) {
    await probe('audio_range', () async {
      final response = await api.http.get<List<int>>(
        stream!.uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=0-1023'},
        ),
      );
      return {
        'status': response.statusCode,
        'bytes': response.data?.length,
        'contentType': response.headers.value('content-type'),
      };
    }, (v) => v);
  }
  await File('docs/api_probe.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  api.http.close(force: true);
}
