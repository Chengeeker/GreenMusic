import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/data/qq_music_api.dart';
import 'package:greenmusic/data/web_login.dart';
import 'package:greenmusic/providers.dart';
import 'package:greenmusic/ui/web_login_page.dart';

import 'support/fakes.dart';

const cookie =
    'uin=o000123; qqmusic_key=fixture=key; login_type=1; p_skey=global-secret; unrelated=discard';

void main() {
  test('QQ and WeChat cookie types preserve IDs and equals signs, dropping global cookies', () {
    final qq = musicSessionFromWebCookies('Cookie: $cookie');
    expect(qq.id, '123');
    expect(qq.key, 'fixture=key');
    expect(qq.loginType, 2);
    expect(qq.encode(), isNot(contains('global-secret')));
    final wx = musicSessionFromWebCookies(
      'login_type=2; wxuin=9007199254740993; wxqqmusic_key=wx-secret',
    );
    expect(wx.id, '9007199254740993');
    expect(wx.loginType, 1);
    for (final invalid in [
      'uin=123',
      'uin=123; qqmusic_key=fixture; login_type=0',
      '$cookie\r\nInjected: value',
      '$cookie; qqmusic_key=conflict',
      'uin=123; qqmusic_key=bad%3Bvalue',
      'x' * 65537,
    ]) {
      expect(
        () => musicSessionFromWebCookies(invalid),
        throwsA(isA<MusicError>()),
      );
    }
  });
  test(
    'music website entry and QQ app authorization schemes are constrained',
    () {
      expect(musicWebHome.toString(), 'https://y.qq.com/');
      expect(isMusicWebUrl('https://y.qq.com/n/ryqq_v2/'), isTrue);
      expect(isMusicWebUrl('https://graph.qq.com/oauth2.0/show'), isFalse);
      const destination =
          'https://ssl.ptlogin2.qq.com/check_sig?ticket=fixture%3D';
      expect(
        qqWebCallbackUrl(
          '$qqWebCallbackPrefix${Uri.encodeComponent(destination)}',
        )?.toString(),
        destination,
      );
      expect(
        qqWebCallbackUrl('$qqWebCallbackPrefix$destination')?.toString(),
        destination,
      );
      for (final callback in [
        '${qqWebCallbackPrefix}https%253A%252F%252Fy.qq.com',
        '${qqWebCallbackPrefix}https://qq.com.attacker.test/',
        '${qqWebCallbackPrefix}https://user@qq.com/',
        '${qqWebCallbackPrefix}javascript:alert(1)',
        '${qqWebCallbackPrefix}https://y.qq.com/%0A',
        '$qqWebCallbackPrefix%',
        'com.green.music.login://other/https://y.qq.com/',
      ]) {
        expect(qqWebCallbackUrl(callback), isNull);
      }
      expect(
        isQqAppLoginUrl('wtloginmqq://ptlogin/qlogin?client_id=100497308'),
        isTrue,
      );
      expect(
        isQqAppLoginUrl('mqqapi://ptlogin/qlogin?client_id=100497308'),
        isTrue,
      );
      expect(isQqAppLoginUrl('mqqapi://share/to_fri?data=unexpected'), isFalse);
      expect(
        isQqAppLoginUrl('wtloginmqq://ptlogin.attacker.test/qlogin'),
        isFalse,
      );
      for (final raw in [
        'http://y.qq.com',
        'https://y.qq.com.attacker.test',
        'https://attacker@qq.com/',
        'https://y.qq.com:444/',
        'javascript:alert(1)',
      ]) {
        expect(isTrustedWebLoginUrl(raw), isFalse);
      }
    },
  );

  late QqMusicApi api;
  late AuthService auth;
  var configured = false, providerOwned = false;
  setUp(() {
    configured = false;
    providerOwned = false;
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    if (!configured) return;
    auth.cancelLogin();
    if (!providerOwned) auth.dispose();
    auth.http.close(force: true);
    api.http.close(force: true);
  });
  void configure(JsonAdapter adapter) {
    api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter);
    auth = AuthService(api);
    configured = true;
  }

  test('web credentials are verified before encrypted save and old attempt cleanup cannot cancel a new one', () async {
    final adapter = JsonAdapter((o, body) {
      expect(o.headers['Cookie'], contains('qqmusic_key=fixture=key'));
      expect(o.headers['Cookie'], isNot(contains('global-secret')));
      return envelope({
        'info': {'musicid': '123', 'nick': '网页账号'},
      });
    });
    configure(adapter);
    final previous = auth.beginWebLogin(), epoch = auth.beginWebLogin();
    auth.cancelLogin(expectedEpoch: previous);
    expect(await auth.importWebLoginCookies(cookie, epoch: epoch), isTrue);
    expect(auth.session?.nickname, '网页账号');
    expect(
      await auth.storage.read(key: 'qqmusic_session'),
      contains('fixture=key'),
    );
    expect(
      await auth.storage.read(key: 'qqmusic_session'),
      isNot(contains('global-secret')),
    );
  });
  test(
    'a rejected or mismatched cookie does not replace the current account',
    () async {
      var reject = true;
      configure(
        JsonAdapter(
          (o, body) => reject
              ? {
                  'code': 0,
                  'req_0': {'code': 1000},
                }
              : envelope({
                  'info': {'musicid': '456', 'nick': 'wrong'},
                }),
        ),
      );
      api.session = MusicSession(credential(id: '789'));
      final epoch = auth.beginWebLogin();
      await expectLater(
        auth.importWebLoginCookies(cookie, epoch: epoch),
        throwsA(isA<MusicError>()),
      );
      reject = false;
      await expectLater(
        auth.importWebLoginCookies(cookie, epoch: epoch),
        throwsA(isA<MusicError>()),
      );
      expect(auth.session?.id, '789');
      expect(await auth.storage.read(key: 'qqmusic_session'), isNull);
    },
  );
  test('cancelled web verification cannot commit a late account', () async {
    final reached = Completer<void>(), reply = Completer<void>();
    configure(
      JsonAdapter((o, body) async {
        reached.complete();
        await reply.future;
        return envelope({
          'info': {'nick': 'late'},
        });
      }),
    );
    final epoch = auth.beginWebLogin();
    final outcome = expectLater(
      auth.importWebLoginCookies(cookie, epoch: epoch),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
      ),
    );
    await reached.future;
    auth.cancelLogin(expectedEpoch: epoch);
    reply.complete();
    await outcome;
    expect(auth.session, isNull);
    expect(await auth.storage.read(key: 'qqmusic_session'), isNull);
  });
  testWidgets(
    'top-right Cookie import works without a WebView and keeps the field private',
    (tester) async {
      configure(
        JsonAdapter(
          (o, body) => envelope({
            'info': {'nick': '手动导入'},
          }),
        ),
      );
      expect(WebViewPlatform.instance, isNull);
      const channel = MethodChannel('com.green.music/settings');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'cancelQqWebLogin');
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      providerOwned = true;
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith((ref) => auth)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => const WebLoginPage()),
                    );
                  },
                  child: const Text('打开网页登录'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开网页登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('导入 Cookie'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      await tester.enterText(find.byType(TextField), cookie);
      await tester.tap(find.text('验证并导入'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(auth.session?.id, '123');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
