import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/core/design_system/components/review_card.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/discover_view.dart';
import 'package:greenmusic/ui/player_page.dart';
import 'package:greenmusic/ui/widgets.dart';

import 'support/fakes.dart';

class SwipeApi extends FakeApi {
  @override
  Future<SongStream> stream(Song song, String quality) async {
    streamRequests.add(song.id);
    return SongStream(
      Uri.https('stream.qqmusic.qq.com', '/${song.id}.mp3'),
      'standard',
      'mp3',
    );
  }
}

void main() {
  for (final variant in [
    (false, 1.0),
    (true, 2.0),
    (false, 2.0),
    (true, 1.0),
  ]) {
    testWidgets('mini swipes, held paint and compact discovery: $variant', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = variant.$2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({'haptics': false});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = SwipeApi();
      final auth = AuthService(api);
      final player = FakePlayer();
      final handler =
          MusicHandler(
              api,
              auth,
              prefs,
              AudioCache(
                Directory('${Directory.current.path}/.local/swipe-test'),
              ),
              audioPlayer: player,
            )
            ..tracks = [fixtureSong(1), fixtureSong(2), fixtureSong(3)]
            ..index = 1;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(handler.disposeHandler);
        api.http.close(force: true);
      });
      final theme = variant.$1 ? AppTheme.darkTheme() : AppTheme.lightTheme();
      for (final overlay in [
        theme.iconButtonTheme.style!.overlayColor!,
        theme.textButtonTheme.style!.overlayColor!,
        theme.filledButtonTheme.style!.overlayColor!,
        theme.radioTheme.overlayColor!,
        theme.switchTheme.overlayColor!,
      ]) {
        expect(overlay.resolve({WidgetState.pressed}), Colors.transparent);
        expect(overlay.resolve({WidgetState.focused}), isNull);
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            apiProvider.overrideWithValue(api),
            authProvider.overrideWith((ref) => auth),
            playerProvider.overrideWithValue(handler),
          ],
          child: MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: DiscoverView(),
              bottomNavigationBar: SafeArea(
                top: false,
                child: RepaintBoundary(
                  key: ValueKey('mini-paint'),
                  child: MiniPlayer(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final item in [
        ('每日推荐', Icons.today_rounded),
        ('个性电台', Icons.radio_rounded),
        ('排行榜', Icons.bar_chart_rounded),
      ]) {
        expect(tester.widget<Icon>(find.byIcon(item.$2)).size, 24);
        final card = find.ancestor(
          of: find.text(item.$1),
          matching: find.byType(ReviewCard),
        );
        final size = tester.getSize(card);
        expect(size.height, inInclusiveRange(48, 140));
        expect(tester.widget<Text>(find.text(item.$1)).style!.fontSize, 12);
      }
      Future<List<int>> paint() async => (await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('mini-paint')),
            )
            .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List().toList();
      }))!;
      final before = await paint();
      final hold = await tester.startGesture(
        tester.getCenter(find.text('歌曲 2')),
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(await paint(), orderedEquals(before));
      await hold.cancel();
      await tester.pumpAndSettle();
      await tester.drag(find.text('歌曲 2'), const Offset(-10, 0));
      await tester.pump();
      expect(find.byType(PlayerPage), findsNothing);
      await tester.pumpAndSettle();

      Future<void> finish() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        for (var i = 0; i < 100 && handler.loading; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump();
        }
        expect(handler.loading, false);
        await tester.pumpAndSettle();
      }

      Future<void> swipe(double x) async {
        final beforeId = handler.current!.id;
        final titleLeft = tester.getTopLeft(find.text('歌曲 $beforeId')).dx;
        final controlBounds = tester.getRect(find.byType(PlayButton));
        final beforeCalls = api.streamRequests.length;
        final swipeArea = find.byKey(
          const ValueKey('mini-player-track-switch'),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('歌曲 $beforeId')),
        );
        await gesture.moveBy(Offset(x / 2, 0));
        await tester.pump();
        if (x.abs() >= 100 && handler.tracks.length > 1) {
          SlideTransition slide(String part) => tester.widget<SlideTransition>(
            find.descendant(
              of: swipeArea,
              matching: find.byKey(ValueKey('swipe-slide-$part')),
            ),
          );
          final progress = slide('target').position.value;
          expect(progress.dx.abs(), inExclusiveRange(0, 1));
          expect(
            tester.getTopLeft(find.text('歌曲 $beforeId')).dx,
            closeTo(titleLeft + x / 2, .001),
          );
          expect(tester.getRect(find.byType(PlayButton)), controlBounds);
          expect(handler.current!.id, beforeId);
          expect(api.streamRequests.length, beforeCalls);
          await tester.pump(const Duration(milliseconds: 400));
          expect(slide('target').position.value, progress);
        }
        await gesture.moveBy(Offset(x / 2, 0));
        await tester.pump();
        await gesture.up();
        await finish();
      }

      player.position = const Duration(seconds: 15);
      await swipe(120);
      expect(
        handler.index,
        0,
      ); // Actual previous track even after three seconds.
      expect(player.loadedUri!.path, '/1.mp3');
      await swipe(120);
      expect(handler.index, 2); // Wrap at queue start.
      await swipe(-120);
      expect(handler.index, 0);
      if (variant == (false, 1.0)) {
        handler.shuffle = true;
        final random = await tester.startGesture(
          tester.getCenter(find.text('歌曲 1')),
        );
        await random.moveBy(const Offset(-120, 0));
        await tester.pump();
        final preview = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('swipe-slide-target')),
                matching: find.byType(Text),
              ),
            )
            .singleWhere((text) => text.data?.startsWith('歌曲 ') == true)
            .data;
        expect(handler.index, 0);
        await random.up();
        await finish();
        expect('歌曲 ${handler.current!.id}', preview);
        handler.shuffle = false;
        await tester.runAsync(() => handler.skipToQueueItem(0));
        await finish();
      }
      final calls = api.streamRequests.length;
      await swipe(35);
      expect(api.streamRequests.length, calls);
      await tester.drag(find.text('歌曲 1'), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(handler.index, 0);
      final canceled = await tester.startGesture(
        tester.getCenter(find.text('歌曲 1')),
      );
      await canceled.moveBy(const Offset(30, 0));
      await canceled.moveBy(const Offset(70, 0));
      await canceled.cancel();
      await tester.pumpAndSettle();
      expect(handler.index, 0);
      // A drag starting over a control must not activate that control on release.
      await tester.drag(find.byTooltip('暂停'), const Offset(-120, 0));
      await finish();
      expect(handler.index, 1);
      expect(find.byType(PlayerPage), findsNothing);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(player.playing, false);
      expect(handler.index, 1);
      await tester.tap(find.text('歌曲 2'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await tester.pumpAndSettle();
      handler.tracks = [fixtureSong(1)];
      handler.index = 0;
      handler.changes.value++;
      await tester.pumpAndSettle();
      final singleCalls = api.streamRequests.length;
      await swipe(-120);
      await swipe(120);
      expect(api.streamRequests.length, singleCalls);
      expect(handler.index, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
