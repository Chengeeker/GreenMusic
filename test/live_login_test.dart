import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/qq_music_api.dart';

void main() {
  test(
    'live QQ and WeChat QR initialization without account authorization',
    () async {
      final api = QqMusicApi(), auth = AuthService(api);
      try {
        for (final wechat in [false, true]) {
          final q = await auth.startLogin(wechat);
          expect(q.image, isNotNull);
          expect(q.image!.length, greaterThan(100));
          expect(q.active, isTrue);
          if (!wechat) {
            final logged = await auth.poll(q);
            expect(logged, isFalse);
            expect(auth.session, isNull);
          }
          auth.cancelLogin();
          expect(q.active, isFalse);
        }
      } finally {
        auth.cancelLogin();
        auth.http.close(force: true);
        api.http.close(force: true);
      }
    },
    skip: Platform.environment['GREENMUSIC_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
