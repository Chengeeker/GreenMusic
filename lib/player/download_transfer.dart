import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/models.dart';

// One clock is shared by all songs and connections in a batch.
class DownloadLimiter {
  DownloadLimiter(this.bytesPerSecond);
  final int bytesPerSecond;
  final _clock = Stopwatch()..start();
  int _next = 0;
  Future<void> take(int bytes, CancelToken cancel) async {
    if (bytesPerSecond <= 0) return;
    final due =
        max(_clock.elapsedMicroseconds, _next) +
        (bytes * 1000000 / bytesPerSecond).ceil();
    _next = due;
    while (_clock.elapsedMicroseconds < due) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      await Future<void>.delayed(
        Duration(microseconds: min(100000, due - _clock.elapsedMicroseconds)),
      );
    }
    if (cancel.isCancelled) throw cancel.cancelError!;
  }
}

class _RangeFallback implements Exception {}

class DownloadTransfer {
  DownloadTransfer(this.http, this.limiter);
  final Dio http;
  final DownloadLimiter limiter;
  static const _headers = {
    'Cookie': '',
    'User-Agent': 'QQMusic 14090008(android 10)',
    'Accept-Encoding': 'identity',
  };

  Future<Response<ResponseBody>> _get(
    Uri uri,
    CancelToken cancel, [
    Map<String, String> headers = const {},
  ]) => http.getUri<ResponseBody>(
    uri,
    cancelToken: cancel,
    options: Options(
      responseType: ResponseType.stream,
      receiveDataWhenStatusError: false,
      headers: {..._headers, ...headers},
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  Future<void> _close(Response<ResponseBody> response) async {
    await response.data?.stream.listen((_) {}).cancel();
  }

  void _checkResponse(Response<ResponseBody> response) {
    final type = response.headers.value('content-type')?.toLowerCase() ?? '';
    final encoding = response.headers.value('content-encoding');
    if (type.contains('text/') ||
        type.contains('json') ||
        encoding != null && encoding != 'identity') {
      throw const MusicError('音源未返回完整音频，未保存下载');
    }
  }

  Future<void> _consume(
    Response<ResponseBody> response,
    File file,
    CancelToken cancel,
    int expected,
    void Function(int) progress,
  ) async {
    RandomAccessFile? sink;
    var received = 0;
    try {
      _checkResponse(response);
      sink = await file.open(mode: FileMode.write);
      await for (final chunk in response.data!.stream) {
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          if (cancel.isCancelled) throw cancel.cancelError!;
          final bytes = Uint8List.sublistView(
            chunk,
            offset,
            min(offset + 65536, chunk.length),
          );
          if (expected >= 0 && received + bytes.length > expected) {
            throw const MusicError('音源长度不符，请重试');
          }
          await limiter.take(bytes.length, cancel);
          if (cancel.isCancelled) throw cancel.cancelError!;
          await sink.writeFrom(bytes);
          received += bytes.length;
          progress(received);
        }
      }
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (received == 0 || expected >= 0 && received != expected) {
        throw const MusicError('歌曲未完整下载，请重试');
      }
      await sink.flush();
    } finally {
      await sink?.close();
      // Also closes a body rejected before its first byte is consumed.
      if (sink == null) await _close(response);
    }
  }

  Future<void> download(
    Uri uri,
    File target,
    CancelToken cancel, {
    int connections = 1,
    required void Function(int, int, double) onProgress,
    void Function(String)? onStage,
  }) async {
    final clock = Stopwatch()..start();
    void report(int received, int total) => onProgress(
      received,
      total,
      clock.elapsedMilliseconds > 0
          ? received * 1000 / clock.elapsedMilliseconds
          : 0,
    );
    Future<void> single([Response<ResponseBody>? supplied]) async {
      onStage?.call('单连接下载');
      final response = supplied ?? await _get(uri, cancel);
      if (response.statusCode != 200) {
        await _close(response);
        if (response.statusCode == 206) {
          throw const MusicError('音源只返回了部分音频，未保存下载');
        }
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
        );
      }
      final length =
          int.tryParse(response.headers.value('content-length') ?? '') ?? -1;
      try {
        report(0, length);
      } catch (_) {
        await _close(response);
        rethrow;
      }
      await _consume(
        response,
        target,
        cancel,
        length,
        (count) => report(count, length),
      );
    }

    if (connections <= 1) {
      await single();
      return;
    }
    final probe = await _get(uri, cancel, {'Range': 'bytes=0-0'});
    if (probe.statusCode == 200) {
      await single(probe);
      return;
    }
    final match = RegExp(r'^bytes 0-0/(\d+)$')
        .firstMatch(probe.headers.value('content-range') ?? '');
    final length = int.tryParse(match?[1] ?? '') ?? 0;
    final etag = probe.headers.value('etag');
    await _close(probe);
    if (cancel.isCancelled) throw cancel.cancelError!;
    // Without a strong validator, equal-sized ranges may belong to different revisions.
    if (probe.statusCode != 206 ||
        length < connections * 1024 * 1024 ||
        etag == null ||
        !etag.startsWith('"') ||
        !etag.endsWith('"')) {
      await single();
      return;
    }
    final group = CancelToken();
    unawaited(cancel.whenCancel.then((error) => group.cancel(error)));
    final parts = [
      for (var i = 0; i < connections; i++) File('${target.path}.segment$i'),
    ];
    final counts = List.filled(connections, 0);
    Object? failure;
    StackTrace? trace;
    onStage?.call('$connections 连接分段下载');
    report(0, length);
    try {
      try {
        await Future.wait([
          for (var i = 0; i < connections; i++)
            () async {
              final start = length ~/ connections * i;
              final end = i == connections - 1
                  ? length - 1
                  : length ~/ connections * (i + 1) - 1;
              try {
                final response = await _get(uri, group, {
                  'Range': 'bytes=$start-$end',
                  'If-Match': etag,
                });
                if (response.statusCode != 206 ||
                    response.headers.value('content-range') !=
                        'bytes $start-$end/$length' ||
                    response.headers.value('etag') != etag) {
                  await _close(response);
                  throw _RangeFallback();
                }
                await _consume(response, parts[i], group, end - start + 1, (
                  count,
                ) {
                  counts[i] = count;
                  report(counts.fold(0, (a, b) => a + b), length);
                });
              } catch (e, stack) {
                failure ??= e;
                trace ??= stack;
                group.cancel('segment failed');
                rethrow;
              }
            }(),
        ], eagerError: false);
      } catch (_) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        if (failure is! _RangeFallback) {
          Error.throwWithStackTrace(failure!, trace!);
        }
      }
      if (failure == null) {
        onStage?.call('正在合并分段');
        final sink = await target.open(mode: FileMode.write);
        try {
          for (final part in parts) {
            await for (final chunk in part.openRead()) {
              if (cancel.isCancelled) throw cancel.cancelError!;
              await sink.writeFrom(chunk);
            }
            await part.delete();
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }
    } finally {
      for (final part in parts) {
        if (await part.exists()) await part.delete();
      }
    }
    if (failure is _RangeFallback) {
      clock.reset();
      await single();
    }
  }
}
