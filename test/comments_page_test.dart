import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_cache.dart';
import 'package:greenmusic/player/music_handler.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/collection_pages.dart';

import 'support/fakes.dart';

Json commentResult(String id, int total) => {
  'CommentList': {
    'Total': total,
    'HasMore': false,
    'Comments': [
      {'CmId': id, 'Content': id, 'Nick': '评论用户'},
    ],
  },
};

class CommentApi extends FakeApi {
  final requests = <String>[];
  Completer<Json>? pendingHot;
  int latestTotal = 284;
  @override
  Future<Json> rpc(
    String module,
    String method,
    Json param, {
    Json? comm,
    Map<String, String>? headers,
    CancelToken? cancel,
  }) {
    requests.add(method);
    return method == 'GetHotCommentList'
        ? pendingHot?.future ?? Future.value(commentResult('热门内容', 37))
        : Future.value(commentResult('最新内容', latestTotal));
  }
}

void main() {
  testWidgets(
    'latest is default and hot totals or stale results cannot replace it',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = CommentApi();
      final handler = MusicHandler(
        api,
        AuthService(api),
        prefs,
        AudioCache(
          Directory('${Directory.current.path}/.local/comment-test-cache'),
        ),
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
            apiProvider.overrideWithValue(api),
            playerProvider.overrideWithValue(handler),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme(colorIndex: 3),
            home: CommentsPage(fixtureSong(1)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.requests.first, 'GetNewCommentList');
      expect(find.text('最新内容'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '最新评论 · 284'))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('热门评论'));
      await tester.pumpAndSettle();
      expect(find.text('热门内容'), findsOneWidget);
      expect(find.text('最新评论 · 284'), findsOneWidget);
      expect(find.text('最新评论 · 37'), findsNothing);
      await tester.tap(find.text('最新评论 · 284'));
      await tester.pumpAndSettle();
      expect(find.text('最新内容'), findsOneWidget);

      api.pendingHot = Completer<Json>();
      await tester.tap(find.text('热门评论'));
      await tester.pump();
      expect(api.requests.length, 4);
      api.latestTotal = 285;
      await tester.tap(find.text('最新评论 · 284'));
      await tester.pumpAndSettle();
      api.pendingHot!.complete(commentResult('迟到的热门内容', 37));
      await tester.pumpAndSettle();
      expect(find.text('最新内容'), findsOneWidget);
      expect(find.text('最新评论 · 285'), findsOneWidget);
      expect(find.text('迟到的热门内容'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
