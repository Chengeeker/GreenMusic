import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/song_actions.dart';

import 'support/fakes.dart';

const captureDownload = bool.fromEnvironment('DOWNLOAD_CAPTURE');

Song sizedSong() => Song.fromJson({
  ...fixtureSong(1).raw,
  'file': {
    'media_mid': 'resolved-media',
    'size_128mp3': 5 * 1024 * 1024,
    'size_320mp3': 12 * 1024 * 1024,
    'size_flac': 40 * 1024 * 1024,
  },
});

class SizeApi extends FakeApi {
  Completer<Song>? pending;
  int detailRequests = 0;
  @override
  Future<Song> songDetail(Song song) {
    detailRequests++;
    return pending?.future ?? Future.value(sizedSong());
  }
}

class ChoiceHandler extends MusicHandler {
  ChoiceHandler(SizeApi api, SharedPreferences prefs)
    : super(
        api,
        AuthService(api),
        prefs,
        AudioCache(
          Directory(
            '${Directory.current.path}/.local/download-choice-test-cache',
          ),
        ),
        audioPlayer: FakePlayer(),
      );
  final downloads = <({Song song, String quality})>[];
  @override
  Future<void> downloadSong(Song song, {String? quality}) async {
    downloads.add((song: song, quality: quality!));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (captureDownload) {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      await (FontLoader(
        'DownloadPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  late SharedPreferences prefs;
  late SizeApi api;
  late ChoiceHandler handler;
  final navigator = GlobalKey<NavigatorState>();
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'downloadQuality': 'lossless',
      'quality': 'standard',
    });
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = SizeApi();
    handler = ChoiceHandler(api, prefs);
  });
  Widget app(Song song, {double scale = 1}) => ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      playerProvider.overrideWithValue(handler),
    ],
    child: RepaintBoundary(
      key: const ValueKey('download-preview'),
      child: MaterialApp(
        navigatorKey: navigator,
        debugShowCheckedModeBanner: false,
        theme: captureDownload
            ? AppTheme.lightTheme(colorIndex: 3).copyWith(
                textTheme: AppTheme.lightTheme(colorIndex: 3).textTheme
                    .apply(fontFamily: 'DownloadPreview'),
              )
            : AppTheme.lightTheme(colorIndex: 3),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(
                  onPressed: () => downloadSongWithChoice(context, ref, song),
                  child: const Text('选择下载'),
                ),
                TextButton(
                  onPressed: () => showSongActions(context, ref, song),
                  child: const Text('歌曲菜单'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(handler.disposeHandler);
    api.http.close(force: true);
  }

  for (final scale in [1.0, 2.5]) {
    testWidgets(
      'download choices show sizes on the right and allow the default at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => dispose(tester));
        await tester.pumpWidget(app(sizedSong(), scale: scale));
        await tester.tap(find.text('选择下载'));
        await tester.pumpAndSettle();
        expect(find.text('下载音质'), findsOneWidget);
        expect(find.text('5.0 MB'), findsOneWidget);
        expect(find.text('12.0 MB'), findsOneWidget);
        expect(find.text('40.0 MB'), findsOneWidget);
        expect(api.detailRequests, 0);
        expect(handler.downloads, isEmpty);
        if (captureDownload && scale == 1) {
          final layer = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('download-preview')),
          );
          await tester.runAsync(() async {
            final screenshot = await layer.toImage(pixelRatio: 2);
            final png = await screenshot.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('${Directory.current.path}/.local/player-preview')
                .create(recursive: true);
            await File(
              '${Directory.current.path}/.local/player-preview/download-quality.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            screenshot.dispose();
          });
        }
        if (scale == 1) {
          expect(
            tester.getTopLeft(find.text('12.0 MB')).dx,
            greaterThan(tester.getTopRight(find.text('高品质 MP3')).dx),
          );
        }
        await tester.ensureVisible(find.text('无损 FLAC'));
        await tester.tap(find.text('无损 FLAC'));
        await tester.pumpAndSettle();
        expect(handler.downloads.single.quality, 'lossless');
        expect(prefs.getString('downloadQuality'), 'lossless');
        expect(handler.quality, 'standard');
        await tester.tap(find.text('歌曲菜单'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('下载歌曲'));
        await tester.tap(find.text('下载歌曲'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('标准 MP3'));
        await tester.tap(find.text('标准 MP3'));
        await tester.pumpAndSettle();
        expect(handler.downloads.last.quality, 'standard');
        expect(prefs.getString('downloadQuality'), 'lossless');
        await tester.tap(find.text('选择下载'));
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(handler.downloads.length, 2);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'sparse sizes hydrate once, tolerate failure and ignore a closed sheet',
    (tester) async {
      addTearDown(() => dispose(tester));
      final sparse = Song.fromJson({
        ...fixtureSong(1).raw,
        'title': '保留的原始标题',
        'file': <String, dynamic>{},
      });
      api.pending = Completer<Song>();
      await tester.pumpWidget(app(sparse));
      await tester.tap(find.text('选择下载'));
      await tester.pumpAndSettle();
      expect(find.text('读取中…'), findsNWidgets(3));
      expect(api.detailRequests, 1);
      api.pending!.complete(sizedSong());
      await tester.pumpAndSettle();
      expect(find.text('12.0 MB'), findsOneWidget);
      await tester.tap(find.text('高品质 MP3'));
      await tester.pumpAndSettle();
      expect(handler.downloads.single.quality, 'exhigh');
      expect(handler.downloads.single.song.mediaMid, 'resolved-media');
      expect(handler.downloads.single.song.name, '保留的原始标题');

      api.pending = Completer<Song>();
      await tester.tap(find.text('选择下载'));
      await tester.pumpAndSettle();
      api.pending!.completeError(const MusicError('详情暂不可用'));
      await tester.pumpAndSettle();
      expect(find.text('大小未知'), findsNWidgets(3));
      await tester.tap(find.text('标准 MP3'));
      await tester.pumpAndSettle();
      expect(handler.downloads.length, 2);
      api.pending = Completer<Song>();
      await tester.tap(find.text('选择下载'));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      api.pending!.complete(sizedSong());
      await tester.pumpAndSettle();
      expect(handler.downloads.length, 2);
      expect(find.text('下载音质'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('file sizes use server bytes and legacy fields without estimates', () {
    final song = Song.fromJson({
      ...fixtureSong(1).raw,
      'size128': '1234',
      'size320': 5678,
      'sizeflac': -100,
      'file': {'size_128mp3': 0, 'size_320mp3': 9999, 'size_flac': 0},
    });
    expect(song.downloadBytes('standard'), 1234);
    expect(song.downloadBytes('exhigh'), 9999);
    expect(song.downloadBytes('lossless'), 0);
    expect(fixtureSong(1).downloadBytes('standard'), 0);
  });
}
