import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/theme/theme_provider.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/download_queue.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/batch_download_page.dart';
import 'package:greenmusic/ui/collection_pages.dart';
import 'package:greenmusic/ui/download_settings_page.dart';
import 'package:greenmusic/ui/downloads_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'downloads_ui_test.dart' show MemoryDownloads;

void main() {
  for (final variant in [
    (const Size(375, 812), 2.0),
    (const Size(812, 375), 1.0),
  ]) {
    testWidgets(
      'batch entry, complete selection, settings and cancel at $variant',
      (tester) async {
        tester.view.physicalSize = variant.$1;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = variant.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues({
          'downloadConcurrent': 1,
          'downloadRetries': 0,
        });
        FlutterSecureStorage.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final api = FakeApi();
        final auth = AuthService(api);
        final handler = MusicHandler(
          api,
          auth,
          prefs,
          MemoryDownloads([]),
          audioPlayer: FakePlayer(),
        );
        addTearDown(() async {
          await handler.cancelDownload();
          for (final pending in api.streamResults.values) {
            if (!pending.isCompleted) {
              pending.completeError(const MusicError('取消'));
            }
          }
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await handler.disposeHandler();
          });
        });
        final offsets = <int>[];
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
              home: SongCollectionPage(
                title: '测试歌单',
                loader: (offset) async {
                  offsets.add(offset);
                  return offset == 0
                      ? SongPage([fixtureSong(1), fixtureSong(2)], 100, true)
                      : SongPage([fixtureSong(2), fixtureSong(3)], 103, false);
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('批量下载'));
        await tester.tap(find.text('批量下载'));
        await tester.pumpAndSettle();
        expect(find.byType(BatchDownloadPage), findsOneWidget);
        expect(find.text('下载所选 3 首'), findsOneWidget);
        expect(offsets, contains(100));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('select-download-3')),
          250,
        );
        await tester.tap(find.byKey(const ValueKey('select-download-3')));
        await tester.pump();
        expect(find.text('下载所选 2 首'), findsOneWidget);
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        await tester.tap(find.text('下载设置'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('写入歌曲标签').hitTestable(), 180);
        await tester.tap(find.text('写入歌曲标签'));
        await tester.pumpAndSettle();
        expect(prefs.getBool('downloadTags'), true);
        expect(prefs.getBool('downloadLyrics') ?? false, false);
        await tester.tap(find.text('写入歌曲标签'));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(DownloadSettingsPage))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载所选 2 首'));
        await tester.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 100 && api.streamRequests.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(DownloadsPage), findsOneWidget);
        expect(handler.downloadQueue.items.map((i) => i.song.id), [1, 2]);
        expect(api.streamRequests, [1]);
        await tester.scrollUntilVisible(find.text('取消全部').hitTestable(), 200);
        await tester.tap(find.text('取消全部'));
        await tester.pump();
        await tester.runAsync(() async {
          api.streamResults[1]!.completeError(const MusicError('取消'));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(handler.downloadQueue.count(DownloadStatus.cancelled), 2);
        expect(find.text('重试未完成'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
