import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/download_transfer.dart';

class ErrorBodyAdapter extends Fake implements HttpClientAdapter {
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody(const Stream.empty(), 503, onClose: () => closed = true);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late HttpServer server;
  late Dio http;
  late Uri uri;
  final bytes = Uint8List(4 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = i % 251;
  }
  var mode = 'range', active = 0, peak = 0;
  final requests = <String?>[];
  setUp(() async {
    mode = 'range';
    active = 0;
    peak = 0;
    requests.clear();
    directory = await Directory.systemTemp.createTemp('download-transfer');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
      );
    uri = Uri.parse('http://127.0.0.1:${server.port}/audio');
    server.listen((request) async {
      final range = request.headers.value('range');
      requests.add(range);
      expect(request.headers.value('cookie') ?? '', isEmpty);
      final probe = range == 'bytes=0-0';
      var counted = false;
      try {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        if (mode != 'no-validator') {
          request.response.headers.set('etag', '"v1"');
        }
        if (range == null || mode == 'ignore' || mode == 'changed' && !probe) {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final start = int.parse(match[1]!), end = int.parse(match[2]!);
          if (!probe) {
            expect(request.headers.value('if-match'), '"v1"');
            active++;
            counted = true;
            if (active > peak) peak = active;
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            mode == 'invalid-total' && probe
                ? 'bytes 0-0/99999999999999999999999999999999999'
                : mode == 'wrong-range' && !probe
                ? 'bytes 1-2/${bytes.length}'
                : 'bytes $start-$end/${bytes.length}',
          );
          if (mode == 'changed-etag' && !probe) {
            request.response.headers.set('etag', '"v2"');
          }
          if (mode == 'short' && !probe) {
            request.response.add(bytes.sublist(start, end));
          } else {
            request.response.contentLength = end - start + 1;
            request.response.add(Uint8List.sublistView(bytes, start, end + 1));
          }
        }
        await request.response.close();
      } catch (_) {
        /* Client cancellation closes test sockets. */
      } finally {
        if (counted) active--;
      }
    });
  });
  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('server errors close the unread response before retrying', () async {
    final adapter = ErrorBodyAdapter();
    http.httpClientAdapter = adapter;
    await expectLater(
      DownloadTransfer(http, DownloadLimiter(0)).download(
        uri,
        File('${directory.path}/audio.part'),
        CancelToken(),
        onProgress: (_, _, _) {},
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          503,
        ),
      ),
    );
    expect(adapter.closed, true);
    expect(await directory.list().toList(), isEmpty);
  });

  test('four ranges use validators, run concurrently and merge exact original bytes', () async {
    final file = File('${directory.path}/audio.part');
    var received = 0;
    await DownloadTransfer(http, DownloadLimiter(0)).download(
      uri,
      file,
      CancelToken(),
      connections: 4,
      onProgress: (count, total, _) {
        received = count;
        expect(total, bytes.length);
      },
    );
    expect(await file.readAsBytes(), bytes);
    expect(received, bytes.length);
    expect(requests.length, 5);
    expect(peak, greaterThan(1));
    expect(await directory.list().length, 1);
  });

  for (final fallback in [
    'ignore',
    'no-validator',
    'changed',
    'changed-etag',
    'wrong-range',
    'invalid-total',
  ]) {
    test('$fallback safely falls back to a single complete body', () async {
      mode = fallback;
      final file = File('${directory.path}/audio.part');
      await DownloadTransfer(http, DownloadLimiter(0)).download(
        uri,
        file,
        CancelToken(),
        connections: 2,
        onProgress: (_, _, _) {},
      );
      expect(await file.readAsBytes(), bytes);
      expect(await directory.list().length, 1);
      if (fallback == 'ignore') {
        expect(requests, ['bytes=0-0']);
      } else {
        expect(requests.last, isNull);
      }
    });
  }

  test(
    'short range is rejected and every segment handle is closed and cleaned',
    () async {
      mode = 'short';
      final file = File('${directory.path}/audio.part');
      await expectLater(
        DownloadTransfer(http, DownloadLimiter(0)).download(
          uri,
          file,
          CancelToken(),
          connections: 2,
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<MusicError>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('all connections share a rate budget and cancellation interrupts throttling', () async {
    final limiter = DownloadLimiter(128 * 1024);
    final clock = Stopwatch()..start();
    await Future.wait([
      limiter.take(32768, CancelToken()),
      limiter.take(32768, CancelToken()),
    ]);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(490));
    final cancel = CancelToken();
    final waiting = expectLater(
      limiter.take(1024 * 1024, cancel),
      throwsA(isA<DioException>()),
    );
    final cancelling = Stopwatch()..start();
    cancel.cancel();
    await waiting;
    expect(cancelling.elapsedMilliseconds, lessThan(500));
  });

  test('cancel during segmented transfer cleans all pieces', () async {
    final cancel = CancelToken();
    final file = File('${directory.path}/audio.part');
    await expectLater(
      DownloadTransfer(http, DownloadLimiter(128 * 1024)).download(
        uri,
        file,
        cancel,
        connections: 2,
        onProgress: (count, _, _) {
          if (count > 0) cancel.cancel();
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });
}
