import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/mini_lyrics.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('mini lyrics retain adjacent lines and roll continuously', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final api = FakeApi();
    final player = FakePlayer()..position = const Duration(seconds: 15);
    final handler = MusicHandler(
      api,
      AuthService(api),
      await SharedPreferences.getInstance(),
      AudioCache(
        Directory('${Directory.current.path}/.local/mini-lyrics-test-cache'),
      ),
      audioPlayer: player,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(handler.disposeHandler);
      api.http.close(force: true);
    });
    const lines = [
      LyricLine(Duration.zero, '第一句'),
      LyricLine(Duration(seconds: 5), '  '),
      LyricLine(Duration(seconds: 10), '第二句', translation: '当前翻译'),
      LyricLine(Duration(seconds: 12), ''),
      LyricLine(Duration(seconds: 20), '第三句'),
      LyricLine(Duration(seconds: 30), '第四句'),
    ];
    Widget app(
      List<LyricLine> lyrics, {
      bool accessible = false,
      double scale = 1,
      bool singleLine = false,
      bool enabled = true,
    }) => ProviderScope(
      overrides: [playerProvider.overrideWithValue(handler)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            highContrast: accessible,
            disableAnimations: accessible,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: (singleLine ? 16.8 : 96) * scale,
              child: TickerMode(
                enabled: enabled,
                child: MiniLyrics(lines: lyrics, singleLine: singleLine),
              ),
            ),
          ),
        ),
      ),
    );
    String? textAt(String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data;
    await tester.pumpWidget(app(lines));
    await tester.pumpAndSettle();
    expect(textAt('mini-lyric-previous'), '第一句');
    expect(textAt('mini-lyric-current'), '第二句');
    expect(textAt('mini-lyric-next'), '第三句');
    expect(find.text('当前翻译'), findsOneWidget);
    expect(
      tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .every((f) => f.enabled),
      isTrue,
    );
    expect(
      tester
          .getBottomLeft(find.byKey(const ValueKey('mini-lyric-previous')))
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('mini-lyric-current'))).dy,
      ),
    );
    FixedExtentScrollController wheel() =>
        tester
                .widget<ListWheelScrollView>(find.byType(ListWheelScrollView))
                .controller!
            as FixedExtentScrollController;
    final originalElement = tester.element(find.byKey(const ValueKey(2)));
    final originalY = tester.getTopLeft(find.text('第二句')).dy;
    final nextY = tester.getTopLeft(find.text('第三句')).dy;
    final start = wheel().offset;
    await player.seek(const Duration(seconds: 25));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wheel().offset, inExclusiveRange(start, start + 32));
    expect(
      tester.element(find.byKey(const ValueKey(2))),
      same(originalElement),
    );
    expect(tester.getTopLeft(find.text('第二句')).dy, lessThan(originalY));
    expect(tester.getTopLeft(find.text('第三句')).dy, lessThan(nextY));
    await tester.pumpAndSettle();
    expect(textAt('mini-lyric-current'), '第三句');
    expect(wheel().offset, start + 32);
    await player.seek(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wheel().offset, inExclusiveRange(start, start + 32));
    await tester.pumpAndSettle();
    expect(wheel().offset, start);
    await player.seek(const Duration(seconds: 25));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final interrupted = wheel().offset;
    await player.seek(const Duration(seconds: 35));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(wheel().offset, inExclusiveRange(interrupted, start + 64));
    await tester.pumpAndSettle();
    expect(wheel().offset, start + 64);
    await player.seek(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(textAt('mini-lyric-current'), '第一句');
    expect(textAt('mini-lyric-next'), '第二句');
    final held = tester.widget(
      find.byKey(const ValueKey('mini-lyric-current')),
    );
    await player.seek(const Duration(seconds: 6));
    await tester.pump();
    expect(
      identical(
        tester.widget(find.byKey(const ValueKey('mini-lyric-current'))),
        held,
      ),
      isTrue,
    );
    await player.seek(const Duration(seconds: 35));
    await tester.pumpAndSettle();
    expect(textAt('mini-lyric-previous'), '第三句');
    expect(textAt('mini-lyric-current'), '第四句');
    expect(textAt('mini-lyric-next'), '');
    await tester.pumpWidget(app(lines, scale: .8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app(lines, accessible: true));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .every((f) => !f.enabled),
      isTrue,
    );
    expect(
      tester
          .widgetList<TweenAnimationBuilder<double>>(
            find.byType(TweenAnimationBuilder<double>),
          )
          .every((row) => row.duration == Duration.zero),
      isTrue,
    );
    await tester.pumpWidget(app(const [LyricLine(Duration.zero, ' ')]));
    await tester.pumpAndSettle();
    expect(find.text('暂无同步歌词'), findsOneWidget);
    player.position = Duration.zero;
    await tester.pumpWidget(
      app(const [LyricLine(Duration(seconds: 10), '新的首句')]),
    );
    await tester.pumpAndSettle();
    expect(textAt('mini-lyric-current'), '前奏');
    expect(textAt('mini-lyric-next'), '新的首句');
    player.position = const Duration(seconds: 15);
    await tester.pumpWidget(app(lines, singleLine: true));
    await tester.pumpAndSettle();
    expect(find.text('第二句'), findsOneWidget);
    expect(find.text('第一句').hitTestable(), findsNothing);
    expect(find.text('第三句').hitTestable(), findsNothing);
    expect(find.text('当前翻译'), findsNothing);
    final singleStart = wheel().offset;
    final singleY = tester.getTopLeft(find.text('第二句')).dy;
    await player.seek(const Duration(seconds: 25));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('第二句'), findsOneWidget);
    expect(find.text('第三句'), findsOneWidget);
    expect(wheel().offset, inExclusiveRange(singleStart, singleStart + 16.8));
    expect(tester.getTopLeft(find.text('第二句')).dy, lessThan(singleY));
    expect(tester.getTopLeft(find.text('第三句')).dy, greaterThan(singleY));
    await tester.pumpAndSettle();
    expect(find.text('第二句').hitTestable(), findsNothing);
    expect(find.text('第三句').hitTestable(), findsOneWidget);
    await tester.pumpWidget(app(lines, singleLine: true, enabled: false));
    await tester.pumpAndSettle();
    await player.seek(const Duration(seconds: 35));
    await tester.pump();
    expect(find.text('第三句'), findsOneWidget);
    await tester.pumpWidget(app(lines, singleLine: true, accessible: true));
    await tester.pumpAndSettle();
    expect(find.text('第四句'), findsOneWidget);
    expect(find.text('第三句').hitTestable(), findsNothing);
    expect(find.text('第四句').hitTestable(), findsOneWidget);
    await player.seek(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();
    expect(wheel().offset, closeTo(33.6, .001));
    expect(find.text('第二句').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
