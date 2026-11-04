import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/core/design_system/components/review_preference_tile.dart';
import 'package:greenmusic/core/design_system/components/app_section_card.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/main.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/theme_settings_page.dart';
import 'package:greenmusic/ui/settings_page.dart';
import 'package:greenmusic/ui/webdav_backup_page.dart';
import 'package:greenmusic/ui/library_view.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'Review settings routes, text scaling, supported display modes without custom app icons',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final calls = <MethodCall>[];
      const channel = MethodChannel('com.green.music/settings');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'getFontWeightAdjustment' => 0,
          'getSupportedDisplayModes' => [
            {'width': 1440, 'height': 3200, 'refreshRate': 120.0},
            {'width': 1080, 'height': 2400, 'refreshRate': 60.0},
          ],
          _ => null,
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      SharedPreferences.setMockInitialValues({'haptics': false});
      FlutterSecureStorage.setMockInitialValues({
        'webdav_password': 'private-value',
      });
      final prefs = await SharedPreferences.getInstance(),
          api = FakeApi(),
          auth = AuthService(api);
      final handler = MusicHandler(
        api,
        auth,
        prefs,
        AudioCache(Directory('${Directory.current.path}/.local/ui-test-cache')),
        audioPlayer: FakePlayer(),
      );
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
          child: const GreenMusicApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('设置'), findsNothing);
      await tester.tap(find.text('我的').first);
      await tester.pumpAndSettle();
      final settings = find.byKey(const ValueKey('library-settings'));
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
      Future<void> scrollTo(Finder target, Type page) async {
        final scrolling = find
            .descendant(
              of: find.byType(page),
              matching: find.byType(Scrollable),
            )
            .first;
        tester.state<ScrollableState>(scrolling).position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          target,
          180,
          scrollable: find
              .descendant(
                of: find.byType(page),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(tester.element(target), alignment: .4);
        await tester.pumpAndSettle();
      }

      for (final pair in [
        ('偏好与功能', '个性化'),
        ('存储与备份', '存储设置'),
        ('账号', '登录 QQ 音乐'),
        ('关于', 'GreenMusic'),
      ]) {
        await scrollTo(find.text(pair.$2), SettingsPage);
        final row = find.ancestor(
          of: find.text(pair.$2),
          matching: find.byType(ReviewPreferenceTile),
        );
        final contentStart = find
            .descendant(of: row, matching: find.byType(Icon))
            .first;
        expect(
          tester.getTopLeft(find.text(pair.$1)).dx,
          closeTo(tester.getTopLeft(contentStart).dx, .01),
        );
      }
      await scrollTo(find.text('WebDAV备份'), SettingsPage);
      await tester.tap(find.text('WebDAV备份'));
      await tester.pumpAndSettle();
      expect(find.byType(WebDavBackupPage), findsOneWidget);
      expect(find.text('全量安全备份'), findsOneWidget);
      for (final title in ['WebDAV 服务器配置', '云端备份与还原操作']) {
        await scrollTo(find.text(title), WebDavBackupPage);
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(AppSectionCard),
          ),
          findsNothing,
        );
        expect(tester.getTopLeft(find.text(title)).dx, 32);
      }
      await scrollTo(find.text('应用密码 / Token'), WebDavBackupPage);
      final password = tester
          .widgetList<TextField>(find.byType(TextField))
          .singleWhere((f) => f.obscureText);
      expect(password.controller!.text, 'private-value');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await scrollTo(find.text('个性化'), SettingsPage);
      await tester.tap(find.text('个性化'));
      await tester.pumpAndSettle();
      for (final title in [
        '明暗模式',
        '色彩方案',
        '字体粗细',
        '字体大小',
        '底部导航',
        '显示效果',
        '屏幕显示',
        '触感与震动',
      ]) {
        await scrollTo(find.text(title), ThemeSettingsPage);
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(AppSectionCard),
          ),
          findsNothing,
        );
        expect(tester.getTopLeft(find.text(title)).dx, 32);
      }
      await scrollTo(
        find.byKey(const ValueKey('app-text-scale-slider')),
        ThemeSettingsPage,
      );
      expect(
        tester.getTopLeft(find.text('字体大小')).dx,
        closeTo(
          tester.getTopLeft(find.byIcon(Icons.format_size_rounded)).dx,
          .01,
        ),
      );
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(ThemeSettingsPage)),
      );
      await scope.read(themeProvider.notifier).setAppTextScale(1.4);
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(tester.element(find.byType(ThemeSettingsPage)))
            .scale(16),
        closeTo(44.8, .01),
      );
      expect(tester.takeException(), isNull);
      await scrollTo(find.text('自定义应用字体粗细'), ThemeSettingsPage);
      await tester.tap(find.text('自定义应用字体粗细'));
      await tester.pumpAndSettle();
      expect(find.text('选择字体粗细'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await scrollTo(find.text('屏幕帧率设置'), ThemeSettingsPage);
      expect(find.text('自定义应用图标'), findsNothing);
      expect(
        calls.any(
          (c) => c.method == 'getCurrentAppIcon' || c.method == 'switchAppIcon',
        ),
        isFalse,
      );
      await tester.tap(find.text('屏幕帧率设置'));
      await tester.pumpAndSettle();
      expect(find.text('1440×3200 @ 120 Hz'), findsOneWidget);
      expect(find.textContaining('@ 90 Hz'), findsNothing);
      await tester.tap(find.text('1440×3200 @ 120 Hz'));
      await tester.pumpAndSettle();
      expect(prefs.getInt('screenRefreshRateMode'), 1);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );
}
