import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:greenmusic/data/auth_service.dart';
import 'package:greenmusic/data/library_api.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/data/qq_music_api.dart';

import 'support/fakes.dart';

void main() {
  test(
    'sparse album preserves supplied artwork and title without an album MID',
    () {
      final song = Song.fromJson({
        'id': 1,
        'mid': 'song1',
        'album': {
          'id': 2,
          'name': '专辑',
          'albumPic': 'https://y.gtimg.cn/cover.png',
        },
      });
      expect(song.album.id, 2);
      expect(song.album.name, '专辑');
      expect(song.cover, 'https://y.gtimg.cn/cover.png');
    },
  );
  test('personal song shelves retain a valid first batch after continuation failure', () async {
    final adapter = JsonAdapter((o, b) {
      final request = obj(b['req_0']), p = obj(request['param']);
      if (request['method'] == 'CgiGetTrackInfo') {
        return envelope({
          'tracks': [fixtureSong(1).raw],
        });
      }
      if (p['page'] == 2) {
        return {
          'code': 0,
          'req_0': {'code': 2001},
        };
      }
      return envelope({
        'retcode': 0,
        'load_mark': 0,
        'v_shelf': [
          {
            'id': 207,
            'title_template': '推荐',
            'miscellany': {'songList': '1'},
            'v_niche': [],
          },
        ],
      });
    });
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
      ..session = MusicSession(credential());
    final shelves = await api.songShelves();
    expect(shelves.single.tracks.single.id, 1);
    expect(adapter.requests.length, 3);
  });
  test('cancelled restore cannot replace a newer login attempt', () async {
    FlutterSecureStorage.setMockInitialValues({
      'qqmusic_session': jsonEncode(credential()),
    });
    final adapter = JsonAdapter(
      (o, b) => envelope({
        'info': {'nick': '旧账号'},
      }),
    );
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter);
    final actualAuth = AuthService(api);
    final restoring = actualAuth.restore();
    actualAuth.cancelLogin();
    await restoring;
    expect(api.session, isNull);
    expect(adapter.requests, isEmpty);
    actualAuth.http.close(force: true);
    api.http.close(force: true);
    actualAuth.dispose();
  });
  test(
    'LRC handles multiple timestamps, fractions, offset and translation',
    () {
      final lines = parseLyrics(
        '[offset:-100]\n[00:01.2][00:02.234]歌词\n[ar:作者]',
        '[00:01.100]译文',
      );
      expect(lines.map((l) => l.time.inMilliseconds), [1100, 2134]);
      expect(lines.first.translation, '译文');
      expect(lines.last.text, '歌词');
    },
  );
  test('nested sparse song survives queue JSON round trip', () {
    final input = {
      'musicData': {
        'songid': '42',
        'songmid': 'mid',
        'songname': '歌名',
        'interval': 120,
        'singer': [
          {'singerid': 1, 'singermid': 'artist', 'singername': '歌手'},
        ],
        'albummid': 'album',
      },
    };
    final song = Song.fromJson(input),
        restored = Song.fromJson(
          obj(jsonDecode(jsonEncode(Song.fromJson(input).raw))),
        );
    expect(song.valid, isTrue);
    expect(restored.id, 42);
    expect(restored.artistNames, '歌手');
    expect(restored.mediaMid, isEmpty);
  });
  test(
    'login JSONP is data and rejects code, trailing args and malformed escapes',
    () {
      expect(
        parsePtui("ptuiCB('67','0','','0','请确认\\n登录','昵称');")[4],
        '请确认\n登录',
      );
      for (final invalid in [
        "ptuiCB('0',alert(1),'','','','')",
        "ptuiCB('0','','','','','',)",
        "ptuiCB('0','','','','','');alert(1)",
        r"ptuiCB('0','','','','','\q')",
      ]) {
        expect(() => parsePtui(invalid), throwsA(isA<MusicError>()));
      }
    },
  );
  test('OAuth redirect boundaries reject host, scheme, port and fragments', () {
    expect(
      trustedLoginUrl(
        '$loginJump#',
        'graph.qq.com',
        '/oauth2.0/login_jump',
      ).toString(),
      loginJump,
    );
    expect(
      trustedLoginUrl(
        'https://graph.qq.com/oauth2.0/login_jump',
        'graph.qq.com',
        '/oauth2.0/login_jump',
      ).host,
      'graph.qq.com',
    );
    for (final raw in [
      'http://graph.qq.com/oauth2.0/login_jump',
      'https://graph.qq.com.attacker.test/oauth2.0/login_jump',
      'https://user@graph.qq.com/oauth2.0/login_jump',
      'https://graph.qq.com:444/oauth2.0/login_jump',
      'https://graph.qq.com/oauth2.0/login_jump#x',
    ]) {
      expect(
        () => trustedLoginUrl(raw, 'graph.qq.com', '/oauth2.0/login_jump'),
        throwsA(isA<MusicError>()),
      );
    }
  });
  test('session preserves large IDs and validates type, expiry and header injection', () {
    final session = AuthService.decodeSession({
      'code': 0,
      'req': {'code': 0, 'data': credential(type: 1, id: '9007199254740993')},
    }, 1);
    expect(session.id, '9007199254740993');
    expect(session.comm['qq'], isA<String>());
    for (final data in [
      {...credential(), 'musickey': 'secret\r\nInjected: x'},
      {...credential(), 'loginType': 9},
      {...credential(), 'musickeyCreateTime': '1', 'keyExpiresIn': '1'},
    ]) {
      expect(
        () => AuthService.decodeSession({
          'code': 0,
          'req': {'code': 0, 'data': data},
        }, 2),
        throwsA(isA<MusicError>()),
      );
    }
    expect(
      () => AuthService.decodeSession({
        'req': {'data': credential()},
      }, 2),
      throwsA(isA<MusicError>()),
    );
  });
  test('QIMEI envelope uses ciphertext blocks and reproducible protocol signature', () {
    final now = DateTime.utc(2026, 11, 3, 10),
        d = {
          'androidId': 'fixture',
          'openUdid': 'fixture',
          'imei': '123456789012347',
        };
    final (body, headers) = qimeiEnvelope(d, now);
    final params = obj(
      obj(jsonDecode(qimeiEnvelope(d, now).$1))['qimeiParams'],
    );
    final actual = obj(obj(jsonDecode(body))['qimeiParams']);
    expect(base64Decode(actual['key'] as String).length, 128);
    expect(base64Decode(actual['params'] as String).length % 16, 0);
    expect(actual['time'], '${now.millisecondsSinceEpoch ~/ 1000}');
    final sign = md5
        .convert(
          utf8.encode(
            '${actual['key']}${actual['params']}${now.millisecondsSinceEpoch}${actual['nonce']}ZdJqM15EeO2zWc08${actual['extra']}',
          ),
        )
        .toString();
    expect(actual['sign'], sign);
    expect(headers['Method'], 'GetQimei');
    expect(params['nonce'], isNot(actual['nonce']));
    expect(body, isNot(contains('123456789012347')));
  });
  test(
    'RPC requires explicit status and rejects nested business errors',
    () async {
      for (final response in [
        <String, dynamic>{
          'req_0': {'code': 0, 'data': {}},
        },
        envelope({'code': 1000}),
        {
          'code': 'malformed',
          'req_0': {'code': 0, 'data': {}},
        },
      ]) {
        final api = QqMusicApi(
          dio: Dio()..httpClientAdapter = JsonAdapter((_, _) => response),
        );
        await expectLater(
          api.rpc('module', 'method', {}),
          throwsA(isA<MusicError>()),
        );
      }
    },
  );
  test(
    'search fallback is pinned and later-page rejection keeps the source',
    () async {
      final adapter = JsonAdapter((options, body) {
        if (options.uri.host == 'c.y.qq.com') {
          return {
            'code': 0,
            'data': {
              'song': {
                'totalnum': 80,
                'list': [fixtureSong(1).raw],
              },
            },
          };
        }
        return {
          'code': 0,
          'req_0': {'code': 2001},
        };
      });
      final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter);
      final first = await api.search('测试');
      expect(first.source, 'legacy');
      expect(first.nextOffset, 20);
      final next = await api.search(
        '测试',
        source: first.source,
        offset: first.nextOffset,
      );
      expect(next.source, 'legacy');
      expect(adapter.requests.last.options.queryParameters['p'], 2);
      expect(
        adapter.requests
            .where((r) => r.options.uri.host == 'u.y.qq.com')
            .length,
        1,
      );
    },
  );
  test(
    'comments carry server cursor/version without leaking account credentials',
    () async {
      final adapter = JsonAdapter(
        (o, b) => envelope({
          'TotalVer': 'version-2',
          'CommentList': {
            'Total': 60,
            'HasMore': true,
            'Comments': [
              {'CmId': 'id', 'SeqNo': 'seq-1', 'Content': '内容'},
            ],
          },
        }),
      );
      final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
        ..session = MusicSession(credential());
      final first = await api.comments(fixtureSong(1));
      await api.comments(fixtureSong(1), cursor: first.cursor);
      final last = adapter.requests.last;
      expect(last.options.headers['Cookie'], '');
      expect(obj(last.body['comm']), webComm);
      final param = obj(obj(last.body['req_0'])['param']);
      expect(param['LastCommentSeqNo'], 'seq-1');
      expect(param['LastTotalVer'], 'version-2');
      expect(param['PageNum'], 1);
    },
  );
  test('sparse playback fetches details and high quality downgrades only on empty vkey', () async {
    final adapter = JsonAdapter((o, b) {
      final req = obj(b['req_0']);
      if (req['method'] == 'get_song_detail_yqq') {
        return envelope({'track_info': fixtureSong(42).raw});
      }
      final filename = (obj(req['param'])['filename'] as List).first as String;
      return envelope({
        'sip': ['https://dl.stream.qqmusic.qq.com/'],
        'midurlinfo': [
          {
            'songmid': 'song42',
            'purl': filename.startsWith('M500') ? 'file.mp3' : '',
          },
        ],
      });
    });
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
      ..session = MusicSession(credential());
    final stream = await api.stream(
      Song.fromJson({'id': 42, 'mid': 'song42', 'title': '歌'}),
      'lossless',
    );
    expect(stream.quality, 'standard');
    expect(adapter.requests.length, 4);
    final request = obj(obj(adapter.requests[1].body['req_0'])['param']);
    expect((request['filename'] as List).single, 'F000song42media42.flac');
    expect(request['uin'], '123');
  });
  test(
    'absolute malicious purl cannot escape the trusted audio domain',
    () async {
      final adapter = JsonAdapter(
        (o, b) => envelope({
          'sip': ['https://dl.stream.qqmusic.qq.com/'],
          'midurlinfo': [
            {'purl': 'https://evil.test/file.mp3'},
          ],
        }),
      );
      final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter);
      await expectLater(
        api.stream(fixtureSong(1), 'standard'),
        throwsA(isA<MusicError>()),
      );
      expect(QqMusicApi.validStreamUrl('https://qq.com.evil.test/x'), isFalse);
    },
  );
  test('missing translation cannot discard original timed lyrics', () async {
    final adapter = JsonAdapter(
      (o, b) => o.uri.host == 'c.y.qq.com'
          ? {'code': 0, 'lyric': base64Encode(utf8.encode('[00:01.0]歌词'))}
          : {
              'code': 0,
              'req_0': {'code': 2001},
            },
    );
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter);
    final lyrics = await api.lyrics(fixtureSong(1));
    expect(lyrics.single.text, '歌词');
  });
  test('private playlists advance by raw rows even when invalid songs are filtered', () async {
    final adapter = JsonAdapter(
      (o, b) => envelope({
        'songlist': [
          fixtureSong(1).raw,
          {'id': 0},
        ],
        'hasmore': true,
        'total_song_num': 10,
      }),
    );
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
      ..session = MusicSession(credential());
    final page = await api.playlistPage(
      const MusicList(id: 1, name: '私密', owned: true),
    );
    expect(page.items.length, 1);
    expect(page.nextOffset, 2);
    expect(page.more, isTrue);
  });
  test('rename preserves description, tags, artwork and visibility then reads back', () async {
    var renamed = false;
    final adapter = JsonAdapter((o, b) {
      final r = obj(b['req_0']), method = r['method'];
      if (method == 'GetPlaylistByUin') {
        return envelope({
          'v_playlist': [
            {'tid': 1, 'dirId': 2, 'dirType': 0, 'uin': '123'},
          ],
        });
      }
      if (method == 'uniform_get_Dissinfo') {
        return envelope({
          'dirinfo': {
            'dirid': 2,
            'title': renamed ? '新名字' : '原名字',
            'desc': '保留描述',
            'picurl': '保留封面',
            'picurl2': '',
            'dir_show': 2,
            'tag': [
              {'id': 6},
            ],
          },
        });
      }
      renamed = true;
      return envelope({
        'retCode': 0,
        'result': {'tid': 1, 'dirId': 2},
      });
    });
    final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
      ..session = MusicSession(credential());
    await api.renamePlaylist(1, '新名字');
    final write = adapter.requests.singleWhere(
      (r) => obj(r.body['req_0'])['method'] == 'EditPlaylist',
    );
    final p = obj(obj(write.body['req_0'])['param']);
    expect(p['dirNewDesc'], '保留描述');
    expect(p['dirNewPicUrl'], '保留封面');
    expect(p['dirNewtaglist'], '6');
    expect(p['dirShow'], 2);
    expect(
      adapter.requests.last.body['req_0']['method'],
      'uniform_get_Dissinfo',
    );
  });
  test(
    'invalid names and non-owned playlists never reach write endpoints',
    () async {
      final adapter = JsonAdapter((o, b) => envelope({'v_playlist': <Json>[]}));
      final api = QqMusicApi(dio: Dio()..httpClientAdapter = adapter)
        ..session = MusicSession(credential());
      await expectLater(api.createPlaylist('\n'), throwsA(isA<MusicError>()));
      expect(adapter.requests, isEmpty);
      await expectLater(api.deletePlaylist(999), throwsA(isA<MusicError>()));
      expect(adapter.requests.length, 1);
      expect(
        obj(adapter.requests.single.body['req_0'])['method'],
        'GetPlaylistByUin',
      );
    },
  );
}
