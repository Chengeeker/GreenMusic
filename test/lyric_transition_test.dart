import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/player_page.dart';

import 'support/fakes.dart';

final lines = List.generate(
  60,
  (i) => LyricLine(Duration(seconds: i * 5), '歌词第$i句'),
);

class LongLyricsApi extends FakeApi {
  @override
  Future<List<LyricLine>> lyrics(Song song) async => lines;
}

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  bool reduced = false,
  int cue = 20,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = LongLyricsApi();
  final auth = AuthService(api);
  final player = FakePlayer()..position = Duration(seconds: cue * 5);
  final handler =
      MusicHandler(
          api,
          auth,
          prefs,
          AudioCache(
            Directory('${Directory.current.path}/.local/lyric-transition-test'),
          ),
          audioPlayer: player,
        )
        ..tracks = [fixtureSong(1)]
        ..index = 0;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(handler.disposeHandler);
    api.http.close(force: true);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        authProvider.overrideWith((ref) => auth),
        playerProvider.overrideWithValue(handler),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
}

void main() {
  for (final reduced in [false, true]) {
    for (final index in [20, 59]) {
      testWidgets(
        'lyrics show current cue on the first painted frame, cue=$index reduced=$reduced',
        (tester) async {
          await mount(
            tester,
            Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 260,
                  child: SyncedLyrics(lines: lines, onSeek: (_) {}),
                ),
              ),
            ),
            reduced: reduced,
            cue: index,
          );
          expect(find.text('歌词第0句'), findsNothing);
          final cue = find.text('歌词第$index句');
          expect(cue, findsOneWidget);
          expect(tester.widget<Text>(cue).style!.fontWeight, FontWeight.bold);
          final before = tester.getRect(cue);
          expect(before.center.dy, inExclusiveRange(170, 430));
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(cue), before);
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.getRect(cue), before);
        },
      );
    }
  }

  testWidgets(
    'swipe preview and committed lyrics never paint a loader or restart at the first cue',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, const PlayerPage());
      await tester.pumpAndSettle();
      for (var round = 0; round < 2; round++) {
        final enter = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('player-artwork'))),
        );
        await enter.moveBy(const Offset(-200, 0));
        await tester.pump();
        final lyrics = find.byType(SyncedLyrics);
        expect(lyrics, findsOneWidget);
        expect(
          find.descendant(
            of: lyrics,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        final cue = find.descendant(of: lyrics, matching: find.text('歌词第20句'));
        expect(cue, findsOneWidget);
        expect(
          find.descendant(of: lyrics, matching: find.text('歌词第0句')),
          findsNothing,
        );
        final y = tester.getTopLeft(cue).dy;
        await enter.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(lyrics, findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.getTopLeft(cue).dy, closeTo(y, .001));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(cue).dy, closeTo(y, .001));
        await tester.pumpAndSettle();
        await tester.drag(lyrics, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(find.byType(SyncedLyrics), findsNothing);
      }
    },
  );
}
