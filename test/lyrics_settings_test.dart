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
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/lyrics_settings.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/lyrics_settings_page.dart';
import 'package:greenmusic/ui/synced_lyrics.dart';

import 'support/fakes.dart';

const capture = bool.fromEnvironment('LYRICS_PREVIEW');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (capture) {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      await (FontLoader(
        'LyricsPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  test('enhanced LRC preserves plain text, word times, offset and export; malformed timing falls back', () {
    final lines = parseLyrics(
      '[offset:-100]\n[00:01.000]<00:01.000>你<00:01.500>好<00:02.000>\n[00:03.000]普通行',
      '[00:00.900]Hello',
    );
    expect(lines.first.text, '你好');
    expect(lines.first.translation, 'Hello');
    expect(lines.first.words.map((w) => w.time.inMilliseconds), [900, 1400]);
    expect(lines.first.words.last.end!.inMilliseconds, 1900);
    expect(encodeLrc(lines), '[00:00.90]你好\n[00:00.90]Hello\n[00:02.90]普通行');
    final malformed = parseLyrics('[00:01.00]<00:02.00>不<00:01.00>倒退', '');
    expect(malformed.single.text, '不倒退');
    expect(malformed.single.words, isEmpty);
  });
  test('four policies distinguish real timing and estimates, preserving graphemes and bounding the last line', () {
    const line = LyricLine(Duration(seconds: 1), '你👨‍👩‍👧‍👦e\u0301');
    final real = parseLyrics(
      '[00:01.000]<00:01.000>你<00:02.000>好<00:03.000>',
      '',
    ).single;
    expect(karaokeWords(real, null, null, KaraokeMode.off, true), isEmpty);
    expect(
      karaokeWords(real, null, null, KaraokeMode.timed, true).last.end,
      const Duration(seconds: 3),
    );
    expect(
      karaokeWords(
        line,
        const Duration(seconds: 4),
        null,
        KaraokeMode.timed,
        true,
      ),
      isEmpty,
    );
    expect(
      karaokeWords(
        line,
        const Duration(seconds: 4),
        null,
        KaraokeMode.song,
        false,
      ),
      isEmpty,
    );
    expect(
      karaokeWords(
        line,
        const Duration(seconds: 4),
        null,
        KaraokeMode.song,
        true,
      ),
      hasLength(3),
    );
    final words = karaokeWords(
      line,
      const Duration(seconds: 4),
      null,
      KaraokeMode.all,
      false,
    );
    expect(words.map((w) => w.text), ['你', '👨‍👩‍👧‍👦', 'e\u0301']);
    expect(words.last.end, const Duration(seconds: 4));
    expect(
      karaokeWords(
        line,
        null,
        const Duration(minutes: 9),
        KaraokeMode.all,
        false,
      ).last.end!.inSeconds,
      lessThan(10),
    );
    expect(
      karaokeWords(
        line,
        null,
        const Duration(milliseconds: 1500),
        KaraokeMode.all,
        false,
      ).last.end,
      const Duration(milliseconds: 1500),
    );
  });

  for (final variant in [
    (const Size(375, 812), 2.0, false),
    (const Size(812, 375), 1.0, true),
  ]) {
    testWidgets('settings save all six controls with scrolling at $variant', (
      tester,
    ) async {
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: previewTheme(variant.$3),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(variant.$2)),
              child: child!,
            ),
            home: const RepaintBoundary(
              key: ValueKey('lyrics-preview'),
              child: LyricsSettingsPage(),
            ),
          ),
        ),
      );
      for (final entry in [('lyricFontSize', 32), ('lyricFontWeight', 800)]) {
        final finder = find.byKey(ValueKey(entry.$1));
        await tester.scrollUntilVisible(finder.hitTestable(), 160);
        final slider = tester.widget<Slider>(finder);
        slider.onChanged!(entry.$2.toDouble());
        await tester.pump();
        slider.onChangeEnd!(entry.$2.toDouble());
        await tester.pumpAndSettle();
        expect(prefs.getInt(entry.$1), entry.$2);
      }
      for (final entry in [
        ('歌词视图文本居中对齐', 'lyricCenter'),
        ('歌词视图模糊', 'lyricBlur'),
        ('交错滚动效果', 'lyricStagger'),
      ]) {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        await tester.scrollUntilVisible(find.text(entry.$1).hitTestable(), 140);
        await tester.tap(find.text(entry.$1));
        await tester.pumpAndSettle();
        expect(prefs.getBool(entry.$2), false);
      }
      await tester.scrollUntilVisible(
        find.text('卡拉 OK（逐字）歌词动画兼容策略').hitTestable(),
        140,
      );
      await tester.tap(find.text('卡拉 OK（逐字）歌词动画兼容策略'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅当前行'));
      await tester.pumpAndSettle();
      expect(prefs.getInt('lyricKaraoke'), 1);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('lyric-settings-preview')).hitTestable(),
        140,
      );
      final preview = tester.widget<Text>(
        find.byKey(const ValueKey('lyric-settings-preview')),
      );
      expect(preview.style!.fontSize, 32);
      expect(preview.style!.fontWeight, FontWeight.w800);
      expect(preview.textAlign, TextAlign.left);
      expect(LyricsSettings.read(prefs).karaoke, KaraokeMode.timed);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'wrapped word masks finish every glyph and preserve matching text layout',
    (tester) async {
      const text =
          'One long line wraps across several rows 你好 e\u0301 👨‍👩‍👧‍👦';
      final position = ValueNotifier(Duration.zero);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                child: KaraokeText(
                  text: text,
                  words: karaokeWords(
                    const LyricLine(Duration.zero, text),
                    const Duration(seconds: 8),
                    null,
                    KaraokeMode.all,
                    false,
                  ),
                  position: position,
                  style: const TextStyle(
                    fontSize: 24,
                    height: 1.35,
                    color: Colors.white,
                  ),
                  dimColor: Colors.grey,
                  align: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      );
      final f = find.byType(ClipPath);
      final size = tester.getSize(f);
      expect(size.height, greaterThan(60));
      final clipper = tester.widget<ClipPath>(f).clipper!;
      position.value = const Duration(seconds: 1);
      final first = clipper.getClip(size).getBounds();
      position.value = const Duration(seconds: 8);
      final full = clipper.getClip(size).getBounds();
      expect(full.bottom, greaterThan(first.bottom));
      final paragraphs = tester
          .renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(KaraokeText),
              matching: find.byType(RichText),
            ),
          )
          .toList();
      final selection = const TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
      expect(
        paragraphs[0].getBoxesForSelection(selection).map((b) => b.toRect()),
        paragraphs[1].getBoxesForSelection(selection).map((b) => b.toRect()),
      );
      for (final box in paragraphs[1].getBoxesForSelection(selection)) {
        if (box.right > box.left) {
          expect(clipper.getClip(size).contains(box.toRect().center), true);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'word fill pauses, seeks, freezes offscreen and restores current position',
    (tester) async {
      final h = await LyricsHarness.create();
      addTearDown(() => h.dispose(tester));
      final lines = List.generate(
        100,
        (i) => LyricLine(
          Duration(seconds: i * 10),
          '歌词 $i 唱出每一份热爱',
          translation: 'Every line follows the music',
        ),
      );
      await tester.pumpWidget(h.app(lines));
      await tester.pump();
      expect(find.byType(KaraokeText), findsOneWidget);
      expect(find.byType(Text).evaluate().length, lessThan(40));
      final word = find.byType(KaraokeText);
      Path clip() {
        final f = find.descendant(of: word, matching: find.byType(ClipPath));
        return tester.widget<ClipPath>(f).clipper!.getClip(tester.getSize(f));
      }

      expect(clip().getBounds(), Rect.zero);
      await h.player.seek(const Duration(seconds: 4));
      await tester.pump();
      final half = clip().getBounds();
      expect(half.width, greaterThan(0));
      await tester.pump(const Duration(seconds: 2));
      expect(clip().getBounds(), half);
      await h.player.seek(const Duration(seconds: 8));
      await tester.pump();
      expect(clip().getBounds().width, greaterThanOrEqualTo(half.width));
      await h.player.seek(const Duration(seconds: 1));
      await tester.pump();
      expect(clip().getBounds().width, lessThan(half.width));
      await tester.pumpWidget(h.app(lines, enabled: false));
      final frozen = tester.widget<KaraokeText>(word).position.value;
      await h.player.seek(const Duration(seconds: 500));
      await tester.pump();
      expect(tester.widget<KaraokeText>(word).position.value, frozen);
      await tester.pumpWidget(h.app(lines));
      expect(find.text('歌词 50 唱出每一份热爱'), findsOneWidget);
      expect(find.text('歌词 0 唱出每一份热爱'), findsNothing);
      await h.player.play();
      await tester.pump(const Duration(milliseconds: 50));
      h.player.position = const Duration(seconds: 501);
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester.widget<KaraokeText>(word).position.value,
        h.player.position,
      );
      h.player.playbackSpeed = 2;
      h.player.position = const Duration(seconds: 503);
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester.widget<KaraokeText>(word).position.value,
        h.player.position,
      );
      await h.player.pause();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      await h.container
          .read(lyricsSettingsProvider.notifier)
          .setInt('lyricKaraoke', 0);
      await tester.pump();
      expect(find.byType(KaraokeText), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'staggered motion differs by row; reduced motion and high contrast remove effects; long text scales without truncation',
    (tester) async {
      final h = await LyricsHarness.create();
      addTearDown(() => h.dispose(tester));
      final lines = List.generate(
        30,
        (i) => LyricLine(
          Duration(seconds: i * 5),
          '第 $i 行，歌词跟随音乐流动',
          translation: 'Translation for line $i',
        ),
      );
      await h.player.seek(const Duration(seconds: 50));
      await tester.pumpWidget(h.app(lines));
      await h.player.seek(const Duration(seconds: 55));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      double offset(int i) => tester
          .widget<Transform>(find.byKey(ValueKey('lyric-motion-$i')))
          .transform
          .storage[13];
      expect(offset(11), isNot(closeTo(offset(12), .01)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(offset(11), 0);
      expect(
        tester.widget<Text>(find.text(lines[11].text)).textAlign,
        TextAlign.center,
      );
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      await tester.drag(find.byType(SyncedLyrics), const Offset(0, -150));
      await tester.pump(const Duration(seconds: 1));
      final manualOffset = scroll.pixels;
      await h.player.seek(const Duration(seconds: 60));
      await tester.pump();
      expect(scroll.pixels, manualOffset);
      final notifier = h.container.read(lyricsSettingsProvider.notifier);
      await notifier.setInt('lyricFontSize', 40);
      await notifier.setInt('lyricFontWeight', 900);
      await notifier.setBool('lyricCenter', false);
      await tester.pumpWidget(h.app(lines, reduced: true, scale: 2.8));
      final text = tester.widget<Text>(find.text(lines[11].text));
      expect(text.style!.fontSize, 40);
      expect(text.style!.fontWeight, FontWeight.w900);
      expect(text.textAlign, TextAlign.left);
      expect(text.maxLines, isNull);
      expect(find.byType(KaraokeText), findsNothing);
      expect(
        tester
            .widgetList<ImageFiltered>(find.byType(ImageFiltered))
            .every((f) => !f.enabled),
        true,
      );
      await h.player.seek(const Duration(seconds: 60));
      await tester.pump();
      expect(find.text(lines[12].text), findsOneWidget);
      expect(offset(12), 0);
      expect(tester.takeException(), isNull);
    },
  );

  if (capture) {
    testWidgets('capture settings and lyric layouts', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await LyricsHarness.create();
      addTearDown(() => h.dispose(tester));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: previewTheme(true),
            home: const RepaintBoundary(
              key: ValueKey('lyrics-preview'),
              child: LyricsSettingsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await savePreview(tester, 'settings-dark');
      final lines = List.generate(
        14,
        (i) => LyricLine(
          Duration(seconds: i * 6),
          ['风吹过远方的街角', '每一句歌词都值得看清', '跟随音乐慢慢流动', '把故事唱给你听'][i % 4],
          translation: i % 2 == 0 ? 'Let every word follow the music' : '',
        ),
      );
      await h.player.seek(const Duration(seconds: 32));
      await tester.pumpWidget(h.app(lines, dark: true));
      await tester.pump();
      await savePreview(tester, 'lyrics-dark');
      await h.container
          .read(lyricsSettingsProvider.notifier)
          .setBool('lyricCenter', false);
      await tester.pumpWidget(h.app(lines, dark: false));
      await tester.pump(const Duration(milliseconds: 300));
      await savePreview(tester, 'lyrics-light-left');
    });
  }
}

ThemeData previewTheme(bool dark) {
  final theme = dark ? AppTheme.darkTheme() : AppTheme.lightTheme();
  return capture
      ? theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'LyricsPreview'),
          appBarTheme: theme.appBarTheme.copyWith(
            titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: 'LyricsPreview',
            ),
          ),
          listTileTheme: theme.listTileTheme.copyWith(
            titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
              fontFamily: 'LyricsPreview',
            ),
            subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
              fontFamily: 'LyricsPreview',
            ),
          ),
        )
      : theme;
}

class LyricsPlayer extends FakePlayer {
  double playbackSpeed = 1;
  @override
  double get speed => playbackSpeed;
}

class LyricsHarness {
  LyricsHarness(this.prefs, this.player, this.handler, this.container);
  final SharedPreferences prefs;
  final LyricsPlayer player;
  final MusicHandler handler;
  final ProviderContainer container;
  static Future<LyricsHarness> create() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final player = LyricsPlayer(), api = FakeApi();
    final handler = MusicHandler(
      api,
      AuthService(api),
      prefs,
      AudioCache(Directory('.local/lyrics-settings-cache')),
      audioPlayer: player,
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        playerProvider.overrideWithValue(handler),
      ],
    );
    return LyricsHarness(prefs, player, handler, container);
  }

  Widget app(
    List<LyricLine> lines, {
    bool enabled = true,
    bool reduced = false,
    double scale = 1,
    bool dark = true,
  }) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: previewTheme(dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          highContrast: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: const ValueKey('lyrics-preview'),
        child: Scaffold(
          appBar: AppBar(title: const Text('同步歌词')),
          body: TickerMode(
            enabled: enabled,
            child: SyncedLyrics(lines: lines, onSeek: (p) => player.seek(p)),
          ),
        ),
      ),
    ),
  );
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(handler.disposeHandler);
    handler.api.http.close(force: true);
    container.dispose();
  }
}

Future<void> savePreview(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('lyrics-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.local/lyrics-preview');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
