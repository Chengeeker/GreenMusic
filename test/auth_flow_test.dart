import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/data/qq_music_api.dart';

import 'support/fakes.dart';

class QqLoginAdapter implements HttpClientAdapter {
  bool emptyFragments = false, wrongState = false;
  String? confirmationUrl;
  String? authorizeLocation;
  int polls = 0;
  final requests = <RequestOptions>[];
  final exchangeStarted = Completer<void>();
  Completer<void>? holdExchange;
  String suffix(String url) => emptyFragments ? '$url#' : url;

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(o);
    expect(o.followRedirects, isFalse);
    final bytes =
        await stream?.fold<List<int>>([], (a, b) => a..addAll(b)) ?? [];
    switch ('${o.uri.host}${o.uri.path}') {
      case 'xui.ptlogin2.qq.com/ssl/ptqrshow':
        return ResponseBody.fromBytes(
          [137, 80, 78, 71, 13, 10, 26, 10],
          200,
          headers: {
            'set-cookie': ['qrsig=fixture-qr; Domain=.ptlogin2.qq.com; Path=/'],
          },
        );
      case 'xui.ptlogin2.qq.com/ssl/ptqrlogin':
        expect(o.headers['Cookie'], 'qrsig=fixture-qr');
        polls++;
        final status = polls == 1
            ? '66'
            : polls == 2
            ? '67'
            : '0';
        final url =
            confirmationUrl ??
            suffix(
              'https://ssl.ptlogin2.graph.qq.com/check_sig?ptsigx=fixture-signature',
            );
        return ResponseBody.fromString(
          "ptuiCB('$status','0','${status == '0' ? url : ''}','0','ok','fixture')",
          200,
        );
      case 'ssl.ptlogin2.graph.qq.com/check_sig':
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [suffix(loginJump)],
            'set-cookie': [
              for (final name in ['p_uin', 'p_skey', 'pt_oauth_token'])
                '$name=fixture-$name; Domain=.graph.qq.com; Path=/',
            ],
          },
        );
      case 'graph.qq.com/oauth2.0/login_jump':
        return ResponseBody.fromString('', 200);
      case 'graph.qq.com/oauth2.0/authorize':
        expect(o.method, 'POST');
        expect(o.headers['Cookie'], contains('p_skey=fixture-p_skey'));
        final form = Uri.splitQueryString(utf8.decode(bytes));
        final state = wrongState ? 'wrong' : form['state']!;
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [
              authorizeLocation ??
                  suffix(
                    'https://y.qq.com/portal/wx_redirect.html?code=ABCDEF0123456789ABCDEF0123456789&state=$state',
                  ),
            ],
          },
        );
      case 'u.y.qq.com/cgi-bin/musicu.fcg':
        expect(o.headers['Cookie'], isNull);
        final body = obj(jsonDecode(utf8.decode(bytes)));
        expect(obj(body['req'])['method'], 'QQLogin');
        exchangeStarted.complete();
        if (holdExchange != null) await holdExchange!.future;
        return ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'req': {'code': 0, 'data': credential()},
          }),
          200,
        );
      default:
        fail('Unexpected request host or path');
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late QqMusicApi api;
  late AuthService auth;
  late QqLoginAdapter adapter;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api = QqMusicApi();
    auth = AuthService(api);
    adapter = QqLoginAdapter();
    auth.http.httpClientAdapter = adapter;
  });
  tearDown(() {
    auth.cancelLogin();
    auth.http.close(force: true);
    api.http.close(force: true);
    auth.dispose();
  });
  Future<QrLogin> confirmQr() async {
    final qr = await auth.startLogin(false);
    expect(await auth.poll(qr), isFalse);
    expect(await auth.poll(qr), isFalse);
    expect(qr.scanned, isTrue);
    return qr;
  }

  for (final emptyFragments in [false, true]) {
    test(
      'QQ exchange and secure save, empty fragment: $emptyFragments',
      () async {
        adapter.emptyFragments = emptyFragments;
        final qr = await confirmQr();
        expect(await auth.poll(qr), isTrue);
        expect(auth.session?.id, '123');
        expect(
          await auth.storage.read(key: 'qqmusic_session'),
          contains('fixture-secret'),
        );
        expect(qr.active, isFalse);
        expect(adapter.requests.every((r) => !r.uri.hasFragment), isTrue);
      },
    );
  }
  test('wrong state never exchanges or persists a credential', () async {
    adapter.wrongState = true;
    final qr = await confirmQr();
    await expectLater(
      auth.poll(qr),
      throwsA(
        isA<MusicError>().having(
          (e) => e.message,
          'message',
          contains('授权状态或授权码不匹配'),
        ),
      ),
    );
    expect(adapter.exchangeStarted.isCompleted, isFalse);
    expect(auth.session, isNull);
    expect(await auth.storage.read(key: 'qqmusic_session'), isNull);
  });
  test(
    'interactive QQ authorization is offered as web login without following it',
    () async {
      adapter.authorizeLocation =
          'https://graph.qq.com/oauth2.0/show?state=fixture';
      final qr = await confirmQr();
      await expectLater(
        auth.poll(qr),
        throwsA(
          isA<MusicError>().having(
            (e) => e.message,
            'message',
            contains('网页登录'),
          ),
        ),
      );
      expect(
        adapter.requests.any((r) => r.uri.path == '/oauth2.0/show'),
        isFalse,
      );
      expect(adapter.exchangeStarted.isCompleted, isFalse);
      expect(auth.session, isNull);
      expect(qr.active, isFalse);
      final count = adapter.requests.length;
      expect(await auth.poll(qr), isFalse);
      expect(adapter.requests.length, count);
    },
  );
  test(
    'untrusted confirmation is blocked before sending its signature',
    () async {
      adapter.confirmationUrl = 'https://ssl.ptlogin2.graph.qq.com.attacker.test/check_sig?ptsigx=private-signature';
      final qr = await confirmQr();
      await expectLater(
        auth.poll(qr),
        throwsA(
          isA<MusicError>().having(
            (e) => e.message,
            'message',
            isNot(contains('private-signature')),
          ),
        ),
      );
      expect(adapter.requests.length, 4);
      expect(auth.session, isNull);
    },
  );
  test('cancelled QR exchange cannot save a late session', () async {
    adapter.holdExchange = Completer<void>();
    final qr = await confirmQr();
    final outcome = expectLater(
      auth.poll(qr),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
      ),
    );
    await adapter.exchangeStarted.future;
    auth.cancelLogin();
    adapter.holdExchange!.complete();
    await outcome;
    expect(auth.session, isNull);
    expect(await auth.storage.read(key: 'qqmusic_session'), isNull);
  });
}
