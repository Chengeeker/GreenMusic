import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/player_page.dart';
import 'package:greenmusic/ui/widgets.dart';

import 'support/fakes.dart';

void main() {
  for (final variant in [
    (const Size(375, 812), 1.0, false),
    (const Size(375, 812), 2.4, false),
    (const Size(812, 375), 1.0, false),
    (const Size(375, 812), 1.0, true),
  ]) {
    testWidgets('continuous player round trip $variant', (tester) async {
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = FakeApi(), player = FakePlayer();
      final auth = AuthService(api);
      final handler =
          MusicHandler(
              api,
              auth,
              prefs,
              AudioCache(
                Directory(
                  '${Directory.current.path}/.local/transition-test-cache',
                ),
              ),
              audioPlayer: player,
            )
            ..tracks = [fixtureSong(1)]
            ..index = 0;
      final navigator = GlobalKey<NavigatorState>();
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
            navigatorKey: navigator,
            theme: AppTheme.darkTheme(colorIndex: 3),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(variant.$2),
                disableAnimations: variant.$3,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => openPage(
                      context,
                      const MusicScaffold(
                        title: '歌曲列表',
                        body: Center(child: Text('列表内容')),
                      ),
                    ),
                    child: const Text('打开歌曲列表'),
                  ),
                ),
                bottomNavigationBar: const SafeArea(
                  top: false,
                  child: MiniPlayer(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final miniArt = tester.getRect(find.byType(Cover));
      final miniTitle = tester.getRect(find.text('歌曲 1'));
      final miniLyric = tester.getRect(find.text('第一句'));
      expect(find.text('歌手'), findsNothing);

      await tester.tap(find.byType(Cover));
      await tester.pump();
      Rect? midwayArt, midwayTitle;
      if (!variant.$3) {
        await tester.pump(const Duration(milliseconds: 200));
        midwayArt = tester.getRect(
          find.byKey(const ValueKey('player-artwork-flight')),
        );
        expect(midwayArt.width, closeTo(midwayArt.height, .01));
        midwayTitle = tester.getRect(find.text('歌曲 1'));
        // The original page is revealed throughout the transition.
        expect(find.text('打开歌曲列表'), findsOneWidget);
        final surface = find.ancestor(
          of: find.byType(PlayerPage),
          matching: find.byType(OverflowBox),
        );
        expect(tester.getRect(surface).top, greaterThan(0));
      }
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      final fullArt = tester.getRect(find.byType(Cover));
      if (midwayArt != null) {
        expect(midwayArt.width, greaterThan(miniArt.width));
        expect(midwayArt.width, lessThan(fullArt.width));
        expect(midwayArt.top, greaterThan(fullArt.top));
        expect(midwayArt.top, lessThan(miniArt.top));
        final fullTitle = tester.getRect(find.text('歌曲 1'));
        expect(
          midwayTitle!.top,
          inInclusiveRange(fullTitle.top, miniTitle.top),
        );
      }
      navigator.currentState!.pop();
      await tester.pump();
      if (!variant.$3) {
        await tester.pump(const Duration(milliseconds: 180));
        final art = tester.getRect(
          find.byKey(const ValueKey('player-artwork-flight')),
        );
        expect(art.width, closeTo(art.height, .01));
        expect(art.width, greaterThan(miniArt.width));
        expect(art.width, lessThan(fullArt.width));
        expect(art.top, greaterThan(fullArt.top));
        expect(art.top, lessThan(miniArt.top));
        expect(find.text('打开歌曲列表'), findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsNothing);
      expect(tester.getRect(find.byType(Cover)), miniArt);
      expect(tester.getRect(find.text('歌曲 1')), miniTitle);
      expect(tester.getRect(find.text('第一句')), miniLyric);

      // System back during expansion reverses the same flight.
      await tester.tap(find.text('歌曲 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Cover)), miniArt);

      // Cover swipes and local back history leave the shared return flight intact.
      await tester.tap(find.text('打开歌曲列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Cover));
      await tester.pumpAndSettle();
      final artwork = find.byKey(const ValueKey('player-artwork'));
      await tester.drag(artwork, const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      await tester.drag(artwork, const Offset(-10, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      if (variant.$1.width == 375 && variant.$2 == 1) {
        await tester.drag(
          find.byKey(const ValueKey('mini-lyric-current')),
          const Offset(-10, 0),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SyncedLyrics), findsNothing);
      }
      await tester.drag(artwork, const Offset(24, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      final cancelled = await tester.startGesture(tester.getCenter(artwork));
      await cancelled.moveBy(const Offset(-30, 0));
      await cancelled.moveBy(const Offset(-110, 0));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      final reversed = await tester.startGesture(tester.getCenter(artwork));
      await reversed.moveBy(
        const Offset(-20, 0),
        timeStamp: const Duration(milliseconds: 20),
      );
      await reversed.moveBy(
        const Offset(-120, 0),
        timeStamp: const Duration(milliseconds: 80),
      );
      await reversed.moveBy(
        const Offset(20, 0),
        timeStamp: const Duration(milliseconds: 100),
      );
      await reversed.moveBy(
        const Offset(20, 0),
        timeStamp: const Duration(milliseconds: 110),
      );
      await reversed.up(timeStamp: const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      final viewSwipe = find.byKey(const ValueKey('player-view-swipe'));
      double viewProgress() =>
          1 -
          tester
              .widget<SlideTransition>(
                find.descendant(
                  of: viewSwipe,
                  matching: find.byKey(const ValueKey('swipe-slide-target')),
                ),
              )
              .position
              .value
              .dx
              .abs();
      final albumBounds = tester.getRect(artwork);
      const controlKeys = [
        'player-fixed-controls',
        'player-seek',
        'player-transport',
        'player-utilities',
      ];
      final controlBounds = {
        for (final key in controlKeys)
          key: tester.getRect(find.byKey(ValueKey(key))),
      };
      final controlElement = tester.element(
        find.byKey(const ValueKey('player-fixed-controls')),
      );
      void expectFixedControls() {
        for (final key in controlKeys) {
          expect(tester.getRect(find.byKey(ValueKey(key))), controlBounds[key]);
        }
        expect(
          tester.element(find.byKey(const ValueKey('player-fixed-controls'))),
          same(controlElement),
        );
        expect(find.byType(PlayButton), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('swipe-slide-current')),
            matching: find.byKey(const ValueKey('player-fixed-controls')),
          ),
          findsNothing,
        );
      }

      final enter = await tester.startGesture(tester.getCenter(artwork));
      await enter.moveBy(const Offset(-100, 0));
      await tester.pump();
      expectFixedControls();
      if (!variant.$3) {
        final progress = viewProgress();
        expect(
          tester.getRect(artwork).left,
          closeTo(albumBounds.left - 100, .001),
        );
        expect(progress, inExclusiveRange(0, 1));
        expect(
          ModalRoute.of(tester.element(artwork))!.willHandlePopInternally,
          isFalse,
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(viewProgress(), progress);
        expectFixedControls();
        await enter.moveBy(const Offset(40, 0));
        await tester.pump();
        expect(viewProgress(), lessThan(progress));
      }
      await enter.up();
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      expect(find.byType(Cover), findsNothing);
      expectFixedControls();
      await tester.drag(find.byType(SyncedLyrics), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      await tester.drag(find.byType(SyncedLyrics), const Offset(24, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      final cancelledExit = await tester.startGesture(
        tester.getCenter(find.byType(SyncedLyrics)),
      );
      await cancelledExit.moveBy(const Offset(140, 0));
      await cancelledExit.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      expectFixedControls();
      final exit = await tester.startGesture(
        tester.getCenter(find.byType(SyncedLyrics)),
      );
      await exit.moveBy(const Offset(100, 0));
      await tester.pump();
      expectFixedControls();
      if (!variant.$3) {
        expect(viewProgress(), inExclusiveRange(0, 1));
        expect(
          ModalRoute.of(tester.element(find.byType(SyncedLyrics)))!
              .willHandlePopInternally,
          isTrue,
        );
      }
      await exit.up();
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      expectFixedControls();
      expect(navigator.currentState!.canPop(), isTrue);
      expect(
        ModalRoute.of(tester.element(artwork))!.willHandlePopInternally,
        isFalse,
      );
      await tester.drag(artwork, const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SyncedLyrics), findsOneWidget);
      handler.tracks = [fixtureSong(2)];
      handler.changes.value++;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.byType(SyncedLyrics), findsNothing);
      final changedArt = tester.getRect(artwork);
      if (variant.$1.width == 375 && variant.$2 == 1 && !variant.$3) {
        await tester.tap(artwork);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
      }
      navigator.currentState!.pop();
      await tester.pump();
      if (!variant.$3) {
        await tester.pump(const Duration(milliseconds: 180));
        expect(find.text('歌曲 2'), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('player-artwork-flight')))
              .width,
          inInclusiveRange(42, changedArt.width),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('列表内容'), findsOneWidget);
      expect(find.text('歌曲 2'), findsOneWidget);
      if (variant.$1.width == 375 && variant.$2 == 1 && !variant.$3) {
        await tester.tap(find.byType(Cover));
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(812, 375);
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final rotatedArt = tester.getRect(find.byType(Cover));
        expect(rotatedArt.bottom, lessThan(375));
        expect(rotatedArt.width, 42);
        expect(find.text('列表内容'), findsOneWidget);
        handler.tracks = [fixtureSong(3)];
        handler.changes.value++;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('swipe-slide-current'))),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('歌曲 3'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
