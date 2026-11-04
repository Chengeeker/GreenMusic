import 'dart:io';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/main.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/player_page.dart';
import 'package:greenmusic/ui/discover_view.dart';
import 'package:greenmusic/ui/library_view.dart';
import 'package:greenmusic/ui/theme_settings_page.dart';
import 'package:greenmusic/core/design_system/components/review_navigation_bar.dart';
import 'package:greenmusic/core/design_system/components/review_preference_tile.dart';

import 'support/fakes.dart';

void main() {
  for (final variant in [
    (Size(375, 812), 1.0, false, false),
    (Size(375, 812), 2.0, true, false),
    (Size(812, 375), 1.0, true, false),
    (Size(375, 812), 1.0, false, true),
    (Size(375, 812), 1.0, true, true),
  ]) {
    testWidgets(
      'navigation, settings and player layout ${variant.$1} scale ${variant.$2} glass ${variant.$4}',
      (tester) async {
        tester.view.physicalSize = variant.$1;
        tester.view.devicePixelRatio = 1;
        tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPadding);
        tester.platformDispatcher.textScaleFactorTestValue = variant.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues({
          'themeMode': variant.$3 ? 2 : 1,
          'haptics': false,
          'saltUi': true,
          'liquidGlass': variant.$4,
        });
        if (variant.$4) {
          await tester.runAsync(
            () =>
                LiquidGlassWidgets.initialize(enablePerformanceMonitor: false),
          );
        }
        FlutterSecureStorage.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance(),
            api = FakeApi(),
            auth = AuthService(api);
        final directory = Directory(
              '${Directory.current.path}/.local/ui-test-cache',
            ),
            player = FakePlayer();
        final handler = MusicHandler(
          api,
          auth,
          prefs,
          AudioCache(directory),
          audioPlayer: player,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
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
            child: const GreenMusicApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        void expectHeader(String title) => expect(
          find.descendant(of: find.byType(AppBar), matching: find.text(title)),
          findsOneWidget,
        );
        Finder tab(String title) => find
            .descendant(
              of: find.byType(ReviewNavigationBar),
              matching: find.text(title),
            )
            .first;
        expectHeader('发现');
        expect(find.text('今天，听点什么'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('今天，听点什么')).dy -
              tester.getRect(find.byType(AppBar)).bottom,
          closeTo(16, .01),
        );
        final viewport = find
            .descendant(
              of: find.byType(DiscoverView),
              matching: find.byType(Viewport),
            )
            .first;
        expect(
          tester.getRect(viewport).bottom,
          greaterThan(tester.getRect(find.byType(ReviewNavigationBar)).top),
        );
        expect(tester.getRect(viewport).bottom, variant.$1.height);
        expect(find.byTooltip('设置'), findsNothing);

        if (variant.$4) {
          final bar = tester.widget<GlassTabBar>(find.byType(GlassTabBar));
          final colors = Theme.of(
            tester.element(find.byType(ReviewNavigationBar)),
          ).colorScheme;
          expect(
            bar.indicatorColor,
            variant.$3 ? const Color(0x26FFFFFF) : const Color(0x26000000),
          );
          expect(
            bar.indicatorSettings?.glassColor,
            variant.$3 ? const Color(0x26FFFFFF) : const Color(0x18000000),
          );
          expect(bar.indicatorSettings?.bodyMode, GlassBodyMode.clear);
          expect(bar.selectedIconColor, colors.primary);
          expect(bar.selectedLabelColor, colors.primary);
          expect(
            bar.unselectedIconColor,
            variant.$3 ? Colors.white : colors.onSurfaceVariant,
          );
          expect(
            bar.settings?.glassColor,
            variant.$3 ? const Color(0x66000000) : const Color(0xF0FFFFFF),
          );
          expect(
            find.byKey(const ValueKey('liquid-glass-light-rim')),
            variant.$3 ? findsNothing : findsOneWidget,
          );
        }

        await tester.tap(tab('搜索'));
        await tester.pumpAndSettle();
        expectHeader('搜索');
        expect(
          tester.getTopLeft(find.byType(SearchBar)).dy -
              tester.getRect(find.byType(AppBar)).bottom,
          closeTo(16, .01),
        );
        expect(find.text('搜索你想听的音乐'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(tab('我的'));
        await tester.pumpAndSettle();
        expectHeader('我的');
        expect(find.text('我的音乐'), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('library-account'))).dy -
              tester.getRect(find.byType(AppBar)).bottom,
          closeTo(16, .01),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(tab('发现'));
        await tester.pumpAndSettle();
        expectHeader('发现');
        await tester.tap(tab('我的'));
        await tester.pumpAndSettle();
        expectHeader('我的');
        final settings = find.byKey(const ValueKey('library-settings'));
        final libraryActions = tester.widgetList<ReviewPreferenceTile>(
          find.descendant(
            of: find.byType(LibraryView),
            matching: find.byType(ReviewPreferenceTile),
          ),
        );
        expect(libraryActions.last.title, '设置');
        await tester.scrollUntilVisible(
          settings,
          150,
          scrollable: find
              .descendant(
                of: find.byType(LibraryView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(tester.element(settings), alignment: .3);
        await tester.pumpAndSettle();
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(find.text('个性化'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('偏好与功能')).dx,
          closeTo(
            tester.getTopLeft(find.byIcon(Icons.palette_outlined)).dx,
            .01,
          ),
        );
        expect(find.text('播放通知'), findsOneWidget);
        await tester.tap(find.text('个性化'));
        await tester.pumpAndSettle();
        expect(find.text('跟随系统'), findsOneWidget);
        expect(find.text('界面风格'), findsNothing);
        expect(find.text('SaltUI 风格'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Material You (Monet) 动态取色'),
          150,
          scrollable: find
              .descendant(
                of: find.byType(ThemeSettingsPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('Material You (Monet) 动态取色'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(BackButton), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        // Restored metadata can open the player without an actual audio platform.
        expectHeader('我的');
        handler.tracks = [fixtureSong(1)];
        handler.index = 0;
        handler.changes.value++;
        await tester.pumpAndSettle();
        await tester.tap(find.text('歌曲 1'));
        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
