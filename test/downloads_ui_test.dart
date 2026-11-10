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
import 'package:greenmusic/ui/downloads_page.dart';
import 'package:greenmusic/ui/download_settings_page.dart';
import 'package:greenmusic/ui/storage_settings_page.dart';
import 'package:greenmusic/core/design_system/components/app_section_card.dart';

import 'support/fakes.dart';

class MemoryDownloads extends AudioCache {
  MemoryDownloads(this.items)
    : super(Directory('${Directory.current.path}/.local/downloads-ui'));
  final List<DownloadedSong> items;
  @override
  Future<List<DownloadedSong>> entries(
    String account, {
    List<Song> knownSongs = const [],
  }) async => List.of(items);
  @override
  Future<DownloadedSong?> find(
    String account,
    Song song,
    String preferred, {
    bool exact = false,
  }) async => items.where((e) => e.song.id == song.id).firstOrNull;
  @override
  Future<void> remove(String account, DownloadedSong entry) async {
    items.remove(entry);
    changes.value++;
  }

  @override
  Future<void> cancel() async {
    clearProgress();
  }
}

void main() {
  for (final variant in [
    (const Size(375, 812), 2.0),
    (const Size(812, 375), 1.0),
  ]) {
    testWidgets(
      'downloads list, local playback, cancel, delete and settings at $variant',
      (tester) async {
        tester.view.physicalSize = variant.$1;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = variant.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final api = FakeApi(), player = FakePlayer();
        final auth = AuthService(api),
            prefs = await SharedPreferences.getInstance();
        final entry = DownloadedSong(
          fixtureSong(1),
          File('D:/music/one.mp3'),
          'standard',
          'mp3',
          1048576,
          DateTime(2026),
        );
        final cache = MemoryDownloads([entry]);
        final handler = MusicHandler(
          api,
          auth,
          prefs,
          cache,
          audioPlayer: player,
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
            child: MaterialApp(
              theme: AppTheme.lightTheme(colorIndex: 3),
              home: const DownloadsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('歌曲 1'));
        await tester.tap(find.text('歌曲 1'));
        await tester.pumpAndSettle();
        expect(player.loadedUri!.scheme, 'file');
        expect(api.streamRequests, isEmpty);
        expect(tester.takeException(), isNull);
        cache.report(
          SongDownloadProgress('anonymous', fixtureSong(2), 512, 1024),
        );
        cache.report(
          SongDownloadProgress('anonymous', fixtureSong(3), 256, 1024),
        );
        await tester.pump();
        expect(find.byTooltip('取消下载'), findsNWidgets(2));
        await tester.ensureVisible(find.byTooltip('取消下载').first);
        await tester.tap(find.byTooltip('取消下载').first);
        await tester.pumpAndSettle();
        expect(cache.progress.value, isNull);
        await tester.ensureVisible(find.byTooltip('删除歌曲 1的下载'));
        await tester.tap(find.byTooltip('删除歌曲 1的下载'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(cache.items, isEmpty);
        expect(find.textContaining('还没有下载歌曲'), findsOneWidget);
        await tester.ensureVisible(find.text('下载设置'));
        await tester.tap(find.text('下载设置'));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadSettingsPage), findsOneWidget);
        for (final selection in [
          ('同时下载歌曲数', '5 首', 'downloadConcurrent', 5),
          ('每首下载连接数', '4 个连接', 'downloadConnections', 4),
          ('下载总限速', '512 KB/s', 'downloadSpeedKiB', 512),
          ('网络失败自动重试', '3 次', 'downloadRetries', 3),
        ]) {
          await tester.scrollUntilVisible(
            find.text(selection.$1).hitTestable(),
            160,
          );
          await tester.tap(find.text(selection.$1));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(selection.$2).hitTestable(),
            120,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.tap(find.text(selection.$2));
          await tester.pumpAndSettle();
          expect(prefs.getInt(selection.$3), selection.$4);
        }

        await tester.scrollUntilVisible(
          find.text('高品质 MP3').hitTestable(),
          200,
        );
        expect(find.text('下载音质'), findsOneWidget);
        await tester.tap(find.text('高品质 MP3'));
        await tester.pumpAndSettle();
        expect(prefs.getString('downloadQuality'), 'exhigh');
        for (final title in ['保存位置', '歌词']) {
          await tester.scrollUntilVisible(
            find.text(title),
            180,
            scrollable: find
                .descendant(
                  of: find.byType(DownloadSettingsPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.ancestor(
              of: find.text(title),
              matching: find.byType(AppSectionCard),
            ),
            findsNothing,
          );
        }
        await tester.scrollUntilVisible(
          find.text('同时下载 LRC 歌词').hitTestable(),
          160,
        );
        await tester.tap(find.text('同时下载 LRC 歌词'));
        await tester.pumpAndSettle();
        expect(prefs.getBool('downloadLyrics'), true);
        Navigator.of(tester.element(find.byType(DownloadSettingsPage))).push(
          MaterialPageRoute<void>(builder: (_) => const StorageSettingsPage()),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(StorageSettingsPage),
            matching: find.text('下载歌曲'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(StorageSettingsPage),
            matching: find.text('缓存管理'),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: find.text('私有存储空间上限'),
            matching: find.byType(AppSectionCard),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      },
    );
  }
}
