import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/player_page.dart';
import 'package:greenmusic/ui/widgets.dart';
import 'package:greenmusic/ui/wavy_slider_track.dart';
import 'package:greenmusic/ui/mini_lyrics.dart';

import 'support/fakes.dart';

const capture = bool.fromEnvironment('PLAYER_CAPTURE');

class PlayerApi extends FakeApi {
  final lyricsRequests = <int>[];
  final pendingLyrics = <int, Completer<List<LyricLine>>>{};
  @override
  Future<Song> songDetail(Song song) async => Song.fromJson({
    ...song.raw,
    'file': {
      ...obj(song.raw['file']),
      'size_128mp3': 5 * 1024 * 1024,
      'size_320mp3': 12 * 1024 * 1024,
      'size_flac': 40 * 1024 * 1024,
    },
  });
  @override
  Future<List<LyricLine>> lyrics(Song song) {
    lyricsRequests.add(song.id);
    return pendingLyrics[song.id]?.future ??
        (capture
            ? Future.value(const [
                LyricLine(Duration.zero, '旋律从此刻开始'),
                LyricLine(Duration(seconds: 10), '上一句，仍然清晰可见'),
                LyricLine(
                  Duration(seconds: 40),
                  '这一刻，听见喜欢的旋律',
                  translation: 'A melody for this moment',
                ),
                LyricLine(Duration(seconds: 60), '下一句，等待继续唱响'),
              ])
            : super.lyrics(song));
  }
}

class ImageClient extends Fake implements HttpClient {
  ImageClient(this.bytes, this.redBytes);
  final Uint8List bytes, redBytes;
  final requests = <Uri>[];
  Completer<void>? redGate;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return ImageRequest(
      url.path.contains('red') ? redBytes : bytes,
      url.path.contains('red') ? redGate?.future : null,
    );
  }
}

class ImageRequest extends Fake implements HttpClientRequest {
  ImageRequest(this.bytes, this.gate);
  final Uint8List bytes;
  final Future<void>? gate;
  @override
  Future<HttpClientResponse> close() async {
    await gate;
    return ImageResponse(bytes);
  }
}

class ImageResponse extends Fake implements HttpClientResponse {
  ImageResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

Future<Uint8List> artwork({bool red = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        const Offset(256, 256),
        red
            ? [const Color(0xff7f2337), const Color(0xffec9f82)]
            : [const Color(0xff07564d), const Color(0xff83c9a8)],
      ),
  );
  canvas.drawCircle(
    const Offset(166, 108),
    116,
    Paint()..color = red ? const Color(0xff5d1d35) : const Color(0xff103a37),
  );
  canvas.drawCircle(
    const Offset(166, 108),
    76,
    Paint()..color = red ? const Color(0xffc66b7f) : const Color(0xff518c7a),
  );
  canvas.drawCircle(
    const Offset(166, 108),
    29,
    Paint()..color = const Color(0xffe2efcb),
  );
  canvas.drawLine(
    const Offset(28, 38),
    const Offset(28, 226),
    Paint()
      ..color = const Color(0xffd7ebd1)
      ..strokeWidth = 2,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (capture) {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      await (FontLoader(
        'PlayerPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  testWidgets(
    'cached mini artwork stays visible until large cover is decoded',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = await tester.runAsync(() => artwork());
      final client = ImageClient(bytes!, bytes);
      debugNetworkImageHttpClientProvider = () => client;
      const url = 'https://fixtures.test/red-flight.png';
      Widget app(Widget cover) => MaterialApp(home: Center(child: cover));
      Future<void> decoded(int width) async {
        bool ready() => find
            .byType(RawImage)
            .evaluate()
            .any(
              (element) => (element.widget as RawImage).image?.width == width,
            );
        for (var i = 0; i < 100 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      try {
        await tester.pumpWidget(app(const Cover(url, size: 42)));
        await decoded(42);
        client.redGate = Completer<void>();
        await tester.pumpWidget(
          app(
            const Cover(
              url,
              size: 200,
              placeholder: FittedBox(child: Cover(url, size: 42)),
            ),
          ),
        );
        await tester.pump();
        await decoded(42);
        expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 42);
        client.redGate!.complete();
        await decoded(200);
        expect(client.requests.length, 2);
        expect(tester.takeException(), isNull);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    },
  );
  for (final variant in [
    (const Size(375, 812), 1.0, false),
    (const Size(375, 812), 2.8, true),
    (const Size(812, 375), 1.0, true),
    (const Size(320, 568), 1.0, false),
    (const Size(599, 800), 1.0, false),
    (const Size(600, 800), 1.0, true),
    (const Size(1024, 768), 2.0, true),
  ]) {
    testWidgets('M3 player controls and lyrics at $variant', (tester) async {
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = variant.$2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance(),
          api = PlayerApi(),
          auth = AuthService(api);
      final player = FakePlayer()..processingState = ProcessingState.ready;
      final handler = MusicHandler(
        api,
        auth,
        prefs,
        AudioCache(
          Directory('${Directory.current.path}/.local/player-ui-cache'),
        ),
        audioPlayer: player,
      );
      final song = Song.fromJson({
        ...fixtureSong(1).raw,
        'title': '听见微光 · 今夜让旋律慢慢靠近',
        'album': {'id': 1, 'name': '晚风电台'},
      });
      handler.tracks = [song];
      handler.index = 0;
      handler.currentStream = SongStream(
        Uri.https('dl.stream.qqmusic.qq.com', '/fixture.mp3'),
        'standard',
        'mp3',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(handler.disposeHandler);
        api.http.close(force: true);
        auth.api.http.close(force: true);
      });
      var theme = variant.$3
          ? AppTheme.darkTheme(colorIndex: 3)
          : AppTheme.lightTheme(colorIndex: 3);
      if (capture) {
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'PlayerPreview'),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            apiProvider.overrideWithValue(api),
            authProvider.overrideWith((ref) => auth),
            playerProvider.overrideWithValue(handler),
          ],
          child: RepaintBoundary(
            key: const ValueKey('player-capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: const PlayerPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.lyricsRequests, [1]);
      expect(find.byKey(const ValueKey('player-artwork')), findsOneWidget);
      expect(find.text('正在播放'), findsNothing);
      expect(find.byTooltip('收起播放器'), findsNothing);
      final header = tester.getRect(
        find.byKey(const ValueKey('player-header')),
      );
      final art = tester.getRect(find.byKey(const ValueKey('player-artwork')));
      final mini = tester.getRect(
        find.byKey(const ValueKey('player-mini-lyrics')),
      );
      expect(header.left, 24);
      expect(header.top, 72);
      expect(header.bottom, lessThanOrEqualTo(art.top));
      expect(art.bottom, lessThan(mini.top));
      if (variant.$1 == const Size(375, 812) && variant.$2 == 1) {
        expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('player-artwork'))).width,
          greaterThan(240),
        );
      }
      Future<void> reveal(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      await reveal(find.byKey(const ValueKey('player-utilities')));
      final utilities = tester.widget<Row>(
        find.byKey(const ValueKey('player-utilities')),
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('player-utilities')),
      );
      expect(utilities.children.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(
          tester.getSize(find.byWidget(utilities.children[i])).width,
          closeTo(rect.width / 5, .01),
        );
        expect(
          tester.getCenter(find.byWidget(utilities.children[i])).dx,
          closeTo(rect.left + rect.width * (i + .5) / 5, .01),
        );
      }
      expect(
        tester.getCenter(find.byTooltip('歌曲操作')).dy,
        tester.getCenter(find.byKey(const ValueKey('player-utilities'))).dy,
      );

      if (variant.$1 == const Size(375, 812) && variant.$2 == 1) {
        for (final target in [find.byTooltip('播放')]) {
          await reveal(target);
          final ink = tester.widget<InkWell>(
            find.descendant(of: target, matching: find.byType(InkWell)),
          );
          expect(
            ink.overlayColor!.resolve({WidgetState.pressed}),
            Colors.transparent,
          );
          final before = await controlPixels(tester, target);
          final press = await tester.startGesture(tester.getCenter(target));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(await controlPixels(tester, target), orderedEquals(before));
          await tester.pump(const Duration(milliseconds: 650));
          expect(await controlPixels(tester, target), orderedEquals(before));
          await press.cancel();
          Tooltip.dismissAllToolTips();
          await tester.pumpAndSettle();
        }
      }

      await reveal(find.byTooltip('播放'));
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(player.playing, isTrue);
      double wavePhase() =>
          (tester
                      .widget<SliderTheme>(
                        find
                            .ancestor(
                              of: find.byKey(const ValueKey('player-seek')),
                              matching: find.byType(SliderTheme),
                            )
                            .first,
                      )
                      .data
                      .trackShape!
                  as WavySliderTrackShape)
              .phase;
      final movingPhase = wavePhase();
      await tester.pump(const Duration(milliseconds: 200));
      expect(wavePhase(), isNot(movingPhase));
      if (variant.$1 == const Size(375, 812) && variant.$2 == 1) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        await tester.pump();
        final reducedPhase = wavePhase();
        await tester.pump(const Duration(milliseconds: 400));
        expect(wavePhase(), reducedPhase);
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
        await tester.pump();
      }
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      final pausedPhase = wavePhase();
      await tester.pump(const Duration(milliseconds: 300));
      expect(wavePhase(), pausedPhase);
      if (variant.$1 == const Size(375, 812) && variant.$2 == 1) {
        await player.seek(const Duration(seconds: 15));
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('mini-lyric-current')))
              .data,
          '第二句',
        );
        expect(find.text('翻译'), findsOneWidget);
        await player.seek(const Duration(seconds: 1));
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('mini-lyric-current')))
              .data,
          '第一句',
        );
      }
      await reveal(find.byTooltip('随机播放'));
      await tester.tap(find.byTooltip('随机播放'));
      await tester.pumpAndSettle();
      expect(handler.shuffle, isTrue);
      await tester.tap(find.byTooltip('顺序播放'));
      await tester.pumpAndSettle();
      expect(handler.repeat, AudioServiceRepeatMode.all);
      handler.cache.report(SongDownloadProgress('anonymous', song, 20, 100));
      await tester.pump();
      await reveal(find.byTooltip('取消下载'));
      await tester.tap(find.byTooltip('取消下载'));
      await tester.pumpAndSettle();
      expect(handler.cache.progress.value, isNull);
      await reveal(find.byTooltip('下载歌曲'));
      await tester.tap(find.byTooltip('下载歌曲'));
      await tester.pumpAndSettle();
      expect(find.text('下载音质'), findsOneWidget);
      expect(find.text('5.0 MB'), findsOneWidget);
      Navigator.of(tester.element(find.text('下载音质'))).pop();
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('player-seek'));
      await reveal(slider);
      await tester.drag(slider, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(player.position, greaterThan(Duration.zero));
      await reveal(find.byTooltip('歌曲操作'));
      await tester.tap(find.byTooltip('歌曲操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放音质'));
      await tester.pumpAndSettle();
      await reveal(find.text('无损 FLAC'));
      await tester.tap(find.text('无损 FLAC'));
      await tester.pumpAndSettle();
      expect(handler.quality, 'lossless');
      expect(handler.currentStream!.quality, 'standard');
      await reveal(find.byTooltip('同步歌词'));
      await tester.tap(find.byTooltip('同步歌词'));
      await tester.pumpAndSettle();
      expect(api.lyricsRequests, [1]);
      expect(find.byType(SyncedLyrics), findsOneWidget);
      expect(find.byType(MiniLyrics), findsNothing);
      expect(find.byIcon(Icons.lyrics), findsOneWidget);
      expect(find.byType(Cover), findsNothing);
      final selected = find
          .ancestor(
            of: find.text('第二句'),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.selected != null,
            ),
          )
          .first;
      expect(tester.widget<Semantics>(selected).properties.selected, isTrue);
      await tester.tap(find.text('第一句'));
      await tester.pumpAndSettle();
      expect(player.position, Duration.zero);
      await reveal(find.byTooltip('显示封面'));
      await tester.tap(find.byTooltip('显示封面'));
      await tester.pumpAndSettle();
      expect(find.byType(MiniLyrics), findsOneWidget);
      await reveal(find.byKey(const ValueKey('mini-lyric-current')));
      await tester.tap(find.byKey(const ValueKey('mini-lyric-current')));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      await reveal(find.byTooltip('显示封面'));
      await tester.tap(find.byTooltip('显示封面'));
      await tester.pumpAndSettle();
      expect(api.lyricsRequests, [1]);
      expect(
        ModalRoute.of(tester.element(find.byType(PlayerPage)))!
            .willHandlePopInternally,
        isFalse,
      );
      handler.errors.value = '音源连接失败，请重试';
      await tester.pumpAndSettle();
      await reveal(find.text('重试'));
      expect(find.text('重试'), findsOneWidget);
      handler.errors.value = null;
      await tester.pumpAndSettle();
      if (variant.$1 == const Size(375, 812) && variant.$2 == 1) {
        late Future<void> loading;
        player.position = const Duration(seconds: 40);
        await tester.runAsync(() async {
          loading = handler.playSongs([fixtureSong(2)]);
          for (var i = 0; i < 100 && api.streamRequests.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        expect(api.streamRequests, [2]);
        await tester.pump();
        expect(find.text('0:00'), findsOneWidget);
        final progress = find.descendant(
          of: find.byType(PlayButton),
          matching: find.byType(CircularProgressIndicator),
        );
        expect(
          tester.widget<CircularProgressIndicator>(progress).color,
          Theme.of(tester.element(find.byType(PlayButton)))
              .colorScheme
              .onPrimary,
        );
        await tester.ensureVisible(find.byTooltip('暂停'));
        await tester.tap(find.byTooltip('暂停'));
        await tester.pump();
        await tester.runAsync(() async {
          api.streamResults[2]!.complete(
            SongStream(
              Uri.https('dl.stream.qqmusic.qq.com', '/fixture.mp3'),
              'standard',
              'mp3',
            ),
          );
          await loading;
        });
        await tester.pumpAndSettle();
        expect(player.playing, isFalse);
        final lyrics = api.pendingLyrics[3] = Completer<List<LyricLine>>();
        handler.tracks = [fixtureSong(3)];
        handler.index = 0;
        handler.changes.value++;
        await tester.pump();
        expect(find.byKey(const ValueKey('mini-lyric-current')), findsNothing);
        lyrics.complete(const [LyricLine(Duration.zero, '第三首的新歌词')]);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('mini-lyric-current')))
              .data,
          '第三首的新歌词',
        );
        expect(api.lyricsRequests, [1, 2, 3]);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'cover palette shares image loading, ignores stale results and respects pure black',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance(),
          api = PlayerApi(),
          auth = AuthService(api);
      final player = FakePlayer()..processingState = ProcessingState.ready;
      if (capture) player.position = const Duration(seconds: 45);
      final handler = MusicHandler(
        api,
        auth,
        prefs,
        AudioCache(
          Directory('${Directory.current.path}/.local/player-ui-cache'),
        ),
        audioPlayer: player,
      );
      final client = ImageClient(
        (await tester.runAsync(() => artwork()))!,
        (await tester.runAsync(() => artwork(red: true)))!,
      );
      debugNetworkImageHttpClientProvider = () => client;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(handler.disposeHandler);
        debugNetworkImageHttpClientProvider = null;
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        api.http.close(force: true);
        auth.api.http.close(force: true);
      });
      Song imageSong(String color) => Song.fromJson({
        ...fixtureSong(1).raw,
        'title': '听见微光',
        'album': {
          'name': '晚风电台',
          'albumPic': 'https://fixtures.test/$color.png',
        },
      });
      handler.tracks = [imageSong('green')];
      handler.index = 0;
      handler.currentStream = SongStream(Uri(), 'standard', 'mp3');
      final dark = ValueNotifier(false);
      var pureBlack = false;
      addTearDown(dark.dispose);
      Widget app() => ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          apiProvider.overrideWithValue(api),
          authProvider.overrideWith((ref) => auth),
          playerProvider.overrideWithValue(handler),
        ],
        child: RepaintBoundary(
          key: const ValueKey('player-capture'),
          child: ValueListenableBuilder(
            valueListenable: dark,
            builder: (_, isDark, child) {
              var theme = isDark
                  ? AppTheme.darkTheme(colorIndex: 3, isPureBlack: pureBlack)
                  : AppTheme.lightTheme(colorIndex: 3);
              if (capture) {
                theme = theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'PlayerPreview'),
                );
              }
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                home: const PlayerPage(),
              );
            },
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      Future<ColorScheme> finishPalette(
        Brightness brightness, {
        ImageProvider? provider,
      }) async {
        provider ??= tester.widget<Image>(find.byType(Image).first).image;
        ColorScheme? result;
        Object? failure;
        await tester.runAsync(() async {
          unawaited(
            ColorScheme.fromImageProvider(
              provider: provider!,
              brightness: brightness,
            ).then(
              (value) {
                result = value;
              },
              onError: (Object e) {
                failure = e;
              },
            ),
          );
        });
        // Native decoding and frame delivery need both real async work and test frames.
        for (var i = 0; i < 100 && result == null && failure == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(failure, isNull);
        expect(result, isNotNull);
        await tester.pumpAndSettle();
        return result!;
      }

      final expected = await finishPalette(Brightness.light);
      ColorScheme current() =>
          Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      expect(current().primary, expected.primary);
      expect(client.requests.length, 1);
      if (capture) await savePreview(tester, 'm3-player-light');
      client.redGate = Completer<void>();
      handler.tracks = [imageSong('red')];
      handler.changes.value++;
      await tester.pump();
      final redProvider = tester.widget<Image>(find.byType(Image).first).image;
      expect(
        current().primary,
        AppTheme.lightTheme(colorIndex: 3).colorScheme.primary,
      );
      handler.tracks = [imageSong('green')];
      handler.changes.value++;
      await tester.pump();
      client.redGate!.complete();
      final redScheme = await finishPalette(
        Brightness.light,
        provider: redProvider,
      );
      expect(redScheme.primary, isNot(expected.primary));
      await finishPalette(Brightness.light);
      expect(current().primary, expected.primary);
      dark.value = true;
      await tester.pumpAndSettle();
      final expectedDark = await finishPalette(Brightness.dark);
      expect(current().primary, expectedDark.primary);
      expect(current().surface, expectedDark.surface);
      if (capture) await savePreview(tester, 'm3-player-dark');
      pureBlack = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(current().surface, Colors.black);
      expect(prefs.getInt('themeColorIndex'), isNull);
      expect(tester.takeException(), isNull);
      debugNetworkImageHttpClientProvider = null;
    },
  );
}

Future<void> savePreview(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('player-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.local/player-preview');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<List<int>> controlPixels(WidgetTester tester, Finder target) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('player-capture')),
  );
  final rect = tester
      .getRect(target)
      .shift(-boundary.localToGlobal(Offset.zero));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final result = <int>[];
    for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
      result.addAll(
        bytes.sublist(
          (y * image.width + rect.left.ceil()) * 4,
          (y * image.width + rect.right.floor()) * 4,
        ),
      );
    }
    image.dispose();
    return result;
  }))!;
}
