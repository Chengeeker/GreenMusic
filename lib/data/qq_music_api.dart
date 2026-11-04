// Dart adaptation of Lilt internal/qqmusic (AGPL-3.0).
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'models.dart';

const musicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const qqUserAgent = 'QQMusic 14090008(android 10)';
const webComm = {'ct': 24, 'cv': 0};
String randomDigits(int length) =>
    List.generate(length, (_) => Random.secure().nextInt(10)).join();
int hash33(String value, [int initial = 5381]) {
  var h = initial;
  for (final c in value.codeUnits) {
    h = (h * 33 + c) & 0x7fffffff;
  }
  return h;
}

class QqMusicApi {
  QqMusicApi({Dio? dio})
    : http =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              sendTimeout: const Duration(seconds: 20),
              headers: {
                'User-Agent': qqUserAgent,
                'Referer': 'https://y.qq.com/',
              },
            ),
          );
  final Dio http;
  MusicSession? session;
  DateTime _lastSearch = DateTime.fromMillisecondsSinceEpoch(0);
  Future<Json> rpc(
    String module,
    String method,
    Json param, {
    Json? comm,
    Map<String, String>? headers,
    CancelToken? cancel,
  }) async {
    final result = await http.post<dynamic>(
      musicuUrl,
      data: {
        'comm': comm ?? session?.comm ?? webComm,
        'req_0': {'module': module, 'method': method, 'param': param},
      },
      cancelToken: cancel,
      options: Options(
        headers: {if (session != null) 'Cookie': session!.cookie, ...?headers},
      ),
    );
    final body = decode(result.data), req = obj(body['req_0']);
    if (!body.containsKey('code') || !req.containsKey('code')) {
      throw const MusicError('QQ 音乐未返回接口状态');
    }
    final gateway = statusCode(body['code']),
        business = statusCode(req['code']);
    final subcode = req.containsKey('subcode') ? statusCode(req['subcode']) : 0;
    final code = gateway != 0
        ? gateway
        : business != 0
        ? business
        : subcode;
    if (code != 0) throw MusicError('QQ 音乐请求失败（$method，服务码 $code）', code: code);
    if (req['data'] is! Map) throw MusicError('QQ 音乐未返回 $method 数据');
    final data = obj(req['data']);
    checkStatus(data);
    return data;
  }

  static Json decode(dynamic value) {
    if (value is String) {
      var str = value.trim();
      final jsonp = RegExp(r'^\w+\(([\s\S]*)\);?$').firstMatch(str);
      if (jsonp != null) str = jsonp[1]!;
      try {
        value = jsonDecode(str);
      } on FormatException {
        throw const MusicError('QQ 音乐响应格式无法解析');
      }
    }
    if (value is! Map) throw const MusicError('QQ 音乐返回了无效数据');
    return obj(value);
  }

  static void checkStatus(Json data) {
    for (final key in ['code', 'subcode', 'retcode']) {
      if (data.containsKey(key) && statusCode(data[key]) != 0) {
        throw MusicError(
          'QQ 音乐业务请求失败（服务码 ${data[key]}）',
          code: integer(data[key]),
        );
      }
    }
  }

  static int statusCode(dynamic value) {
    final code = int.tryParse('$value');
    if (code == null) throw const MusicError('QQ 音乐返回了无效的接口状态');
    return code;
  }

  Future<Json> cgi(
    String path,
    Json query, {
    bool anonymous = false,
    CancelToken? cancel,
  }) async {
    final response = await http.get<dynamic>(
      'https://c.y.qq.com$path',
      queryParameters: {'format': 'json', 'outCharset': 'utf-8', ...query},
      cancelToken: cancel,
      options: Options(
        headers: {'Cookie': anonymous ? '' : session?.cookie ?? ''},
      ),
    );
    final data = decode(response.data);
    if (!data.containsKey('code')) throw const MusicError('QQ 音乐未返回接口状态');
    checkStatus(data);
    return data;
  }

  MusicSession requireSession() {
    final s = session;
    if (s == null || !s.validIdentity || s.expired) {
      throw const MusicError('请先登录 QQ 音乐，或重新扫码恢复登录');
    }
    return s;
  }

  Future<List<String>> suggestions(String query, {CancelToken? cancel}) async {
    query = query.trim();
    if (query.isEmpty || query.runes.length > 60) return [];
    final d = obj(
      (await cgi(
        '/splcloud/fcgi-bin/smartbox_new.fcg',
        {
          'key': query,
          'inCharset': 'utf-8',
          'platform': 'yqq',
          'needNewCode': 0,
        },
        anonymous: true,
        cancel: cancel,
      ))['data'],
    );
    return [
      for (final type in ['song', 'singer', 'album'])
        for (final j in rows(obj(d[type])['itemlist'])) text(j, ['name']),
    ].where((s) => s.isNotEmpty).toSet().take(8).toList();
  }

  Future<SearchPage> search(
    String query, {
    int kind = 0,
    int offset = 0,
    String source = '',
    CancelToken? cancel,
  }) async {
    query = query.trim();
    if (query.isEmpty || query.runes.length > 60) {
      throw const MusicError('请输入 1–60 个字符');
    }
    final elapsed = DateTime.now().difference(_lastSearch);
    if (elapsed.inMilliseconds < 1000) {
      await Future<void>.delayed(
        Duration(milliseconds: 1000 - elapsed.inMilliseconds),
      );
    }
    if (cancel?.isCancelled == true) throw cancel!.cancelError!;
    _lastSearch = DateTime.now();
    Future<SearchPage> fetch(String backend) async {
      Json data, section;
      List<Json> entries;
      int total;
      final key = ['song', 'singer', 'album'][kind];
      if (backend == 'legacy') {
        data = await cgi('/soso/fcgi-bin/client_search_cp', {
          'p': offset ~/ 20 + 1,
          'n': 20,
          'w': query,
          't': [0, 9, 8][kind],
          'cr': 1,
          'new_json': 1,
        }, cancel: cancel);
        section = obj(obj(data['data'])[key]);
        if (section['list'] is! List) throw const MusicError('QQ 音乐搜索列表格式异常');
        entries = rows(section['list']);
        total = integer(section['totalnum']);
        if (offset > 0 && total == 0 && entries.isEmpty) {
          throw const MusicError('QQ 音乐搜索分页暂不可用，请稍后重试');
        }
      } else {
        final s = session;
        data = await rpc(
          'music.search.SearchCgiService',
          'DoSearchForQQMusicDesktop',
          {
            'query': query,
            'search_type': [0, 1, 2][kind],
            'num_per_page': 20,
            'page_num': offset ~/ 20 + 1,
          },
          comm: {
            'ct': 11,
            'cv': 0,
            'uin': s?.id ?? '0',
            'format': 'json',
            if (s != null) ...{
              'qq': s.id,
              'authst': s.key,
              'tmeLoginType': s.loginType,
            },
          },
          headers: {
            'User-Agent': 'Mozilla/5.0',
            'Cookie': s?.cookie ?? 'tmeLoginType=-1',
          },
          cancel: cancel,
        );
        section = obj(obj(data['body'])[key]);
        final meta = obj(data['meta']);
        if (section['list'] is! List || meta.isEmpty) {
          throw const MusicError('QQ 音乐搜索列表格式异常');
        }
        entries = rows(section['list']);
        total = integer(meta['sum']);
        if (entries.isEmpty && integer(meta['is_filter']) < 0) {
          throw const MusicError('QQ 音乐暂时限制此搜索，请登录或稍后重试');
        }
      }
      return SearchPage(
        source: backend,
        nextOffset: entries.isEmpty ? 0 : offset + 20,
        total: total,
        songs: kind == 0 ? songs(entries) : [],
        artists: kind == 1
            ? entries
                  .map(Artist.fromJson)
                  .where((x) => x.id > 0 && x.mid.isNotEmpty)
                  .toList()
            : [],
        albums: kind == 2
            ? entries
                  .map(Album.fromJson)
                  .where((x) => x.id > 0 && x.mid.isNotEmpty)
                  .toList()
            : [],
      );
    }

    if (source.isNotEmpty) return fetch(source);
    try {
      return await fetch('desktop');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      return fetch('legacy');
    } on MusicError {
      return fetch('legacy');
    }
  }

  Future<List<MusicList>> featured() async {
    final data = await rpc(
      'music.playlist.PlaylistSquare',
      'GetRecommendFeed',
      {'From': 0, 'Size': 24},
    );
    if (data['List'] is! List) throw const MusicError('QQ 音乐未返回推荐歌单');
    return rows(data['List'])
        .map((x) {
          final b = obj(obj(x['Playlist'])['basic']);
          return MusicList(
            id: integer(b['tid']),
            name: text(b, ['title']),
            cover: text(obj(b['cover']), [
              'default_url',
              'big_url',
              'medium_url',
              'small_url',
            ]),
            description: text(b, ['desc']),
            count: integer(b['song_cnt']),
          );
        })
        .where((x) => x.id > 0)
        .toList();
  }

  Future<List<MusicList>> recommended() async {
    final s = requireSession();
    final data = await rpc(
      'music.recommend.RecommendFeed',
      'get_recommend_feed',
      {'direction': 0, 'page': 1, 's_num': 0, 'v_cache': <String>[]},
      comm: {
        'ct': 20,
        'cv': 13020008,
        'qq': s.id,
        'authst': s.key,
        'tmeLoginType': s.loginType,
      },
    );
    if (!data.containsKey('retcode') || data['v_shelf'] is! List) {
      throw const MusicError('QQ 音乐未返回个性化歌单状态或列表');
    }
    final out = <MusicList>[];
    final seen = <int>{};
    for (final shelf in rows(data['v_shelf'])) {
      for (final niche in rows(shelf['v_niche'])) {
        for (final card in rows(niche['v_card'])) {
          final id = integer(card['id']);
          if (integer(card['type']) == 500 &&
              integer(card['subtype']) == 0 &&
              integer(card['jumptype']) == 10014 &&
              id > 0 &&
              seen.add(id)) {
            out.add(
              MusicList(
                id: id,
                name: text(card, ['title']),
                cover: text(card, ['cover']),
              ),
            );
          }
        }
      }
    }
    return out;
  }

  Future<List<MusicList>> charts() async {
    final data = await rpc(
      'musicToplist.ToplistInfoServer',
      'GetAll',
      {},
      comm: Map.of(webComm),
    );
    if (data['group'] is! List) throw const MusicError('QQ 音乐未返回排行榜');
    return [
      for (final group in rows(data['group']))
        for (final j in rows(group['toplist']))
          if (integer(j['recType']) == 10005 && integer(j['topId']) > 0)
            MusicList(
              id: integer(j['topId']),
              name: text(j, ['title']),
              cover: text(j, ['headPicUrl', 'frontPicUrl']),
              chart: true,
              description: text(j, ['intro']),
              count: integer(j['totalNum']),
            ),
    ];
  }

  Future<List<Song>> daily() async {
    requireSession();
    final d = await rpc(
      'music.srfDissInfo.aiDissInfo',
      'uniform_get_Dissinfo',
      {'dirid': 202, 'optype': 3, 'tag': 1, 'userinfo': 0, 'pic_dpi': 300},
    );
    if (d['songlist'] is! List) throw const MusicError('QQ 音乐未返回每日推荐');
    return songs(d['songlist']);
  }

  Future<List<Song>> radio() async {
    requireSession();
    final d = await rpc('music.radioProxy.MbTrackRadioSvr', 'get_radio_track', {
      'id': 99,
      'firstplay': 1,
      'num': 15,
    });
    if (d['tracks'] is! List) throw const MusicError('QQ 音乐未返回个性电台');
    return songs(d['tracks']);
  }

  Future<Song> songDetail(Song song) async {
    final d = await rpc('music.pf_song_detail_svr', 'get_song_detail_yqq', {
      'song_type': 0,
      'song_mid': song.mid,
      'song_id': '${song.id}',
    });
    final result = Song.fromJson(obj(d['track_info']));
    if (!result.valid || result.id != song.id) {
      throw const MusicError('QQ 音乐未返回有效歌曲详情');
    }
    return result;
  }

  Future<List<Song>> playlistSongs(
    MusicList playlist, {
    int offset = 0,
  }) async => (await playlistPage(playlist, offset: offset)).items;
  Future<SongPage> playlistPage(MusicList playlist, {int offset = 0}) async {
    if (playlist.chart) {
      final d = await rpc('musicToplist.ToplistInfoServer', 'GetDetail', {
        'topid': playlist.id,
        'offset': offset,
        'num': 100,
        'period': '',
      }, comm: Map.of(webComm));
      if (integer(obj(d['data'])['recType']) != 10005 ||
          d['songInfoList'] is! List) {
        throw const MusicError('此榜单暂不支持歌曲播放');
      }
      final entries = rows(d['songInfoList']);
      return SongPage(
        songs(entries),
        offset + entries.length,
        offset + entries.length < integer(obj(d['data'])['totalNum']),
      );
    }
    if (playlist.owned && session?.encryptUin.isNotEmpty == true) {
      return _privateSongs(playlist, offset);
    }
    if (offset > 0) return const SongPage([], 0, false);
    try {
      final d = await cgi('/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg', {
        'disstid': playlist.id,
        'type': 1,
        'json': 1,
        'utf8': 1,
        'onlysong': 0,
        'new_format': 1,
      });
      final lists = rows(d['cdlist']);
      if (lists.isEmpty) throw const MusicError('QQ 音乐未返回歌单详情');
      if (lists.first['songlist'] is! List) {
        throw const MusicError('QQ 音乐未返回歌单歌曲');
      }
      final result = songs(lists.first['songlist']);
      final count = number(lists.first, ['total_song_num', 'songnum']);
      if (result.isEmpty &&
          (playlist.count > 0 || count > 0) &&
          session != null) {
        return await _privateSongs(playlist, 0);
      }
      return SongPage(result, rows(lists.first['songlist']).length, false);
    } on MusicError catch (e) {
      if (session != null && (e.code == 10 || playlist.owned)) {
        return await _privateSongs(playlist, 0);
      }
      rethrow;
    }
  }

  Future<SongPage> _privateSongs(MusicList p, int offset) async {
    final s = requireSession();
    final d = await rpc('music.srfDissInfo.DissInfo', 'CgiGetDiss', {
      'disstid': p.id,
      'dirid': 0,
      'tag': true,
      'song_begin': offset,
      'song_num': 100,
      'userinfo': true,
      'orderlist': true,
      'enc_host_uin': s.encryptUin,
    });
    if (d['songlist'] is! List) throw const MusicError('QQ 音乐未返回登录歌单歌曲');
    final entries = rows(d['songlist']);
    final next = offset + entries.length, total = integer(d['total_song_num']);
    return SongPage(
      songs(entries),
      next,
      (d['hasmore'] == true || integer(d['hasmore']) == 1 || total > next) &&
          entries.isNotEmpty,
    );
  }

  Future<List<Song>> artistSongs(Artist artist, {int offset = 0}) async {
    final d = await rpc('music.web_singer_info_svr', 'get_singer_detail_info', {
      'sort': 5,
      'singermid': artist.mid,
      'sin': offset,
      'num': 50,
    });
    if (d['songlist'] is! List) throw const MusicError('QQ 音乐未返回歌手歌曲');
    return songs(d['songlist']);
  }

  Future<List<Album>> artistAlbums(Artist artist, {int offset = 0}) async {
    final d = await rpc(
      'music.musichallAlbum.AlbumListServer',
      'GetAlbumList',
      {'sort': 5, 'singermid': artist.mid, 'begin': offset, 'num': 30},
      comm: Map.of(webComm),
    );
    return rows(d['albumList'] ?? d['albumlist']).map(Album.fromJson).toList();
  }

  Future<List<Song>> albumSongs(Album album) async {
    final d = obj(
      (await cgi('/v8/fcg-bin/fcg_v8_album_info_cp.fcg', {
        'albummid': album.mid,
      }))['data'],
    );
    if (d['list'] is! List && d['songlist'] is! List) {
      throw const MusicError('QQ 音乐未返回专辑歌曲');
    }
    return songs(d['list'] ?? d['songlist']);
  }

  Future<SongStream> stream(Song input, String quality) async {
    final song = input.mediaMid.isEmpty ? await songDetail(input) : input;
    final formats = <({String prefix, String ext, String quality})>[
      if (session != null && quality == 'lossless')
        (prefix: 'F000', ext: 'flac', quality: 'lossless'),
      if (session != null && quality != 'standard')
        (prefix: 'M800', ext: 'mp3', quality: 'exhigh'),
      (prefix: 'M500', ext: 'mp3', quality: 'standard'),
    ];
    final guid = randomDigits(18);
    for (final format in formats) {
      final logged = session != null;
      final d = await rpc(
        logged ? 'music.vkey.GetVkey' : 'vkey.GetVkeyServer',
        logged ? 'UrlGetVkey' : 'CgiGetVkey',
        {
          'filename': [
            '${format.prefix}${song.mid}${song.mediaMid.isEmpty ? song.mid : song.mediaMid}.${format.ext}',
          ],
          'guid': guid,
          'songmid': [song.mid],
          'songtype': [0],
          'uin': session?.id ?? '0',
          if (logged) 'ctx': 0 else ...{'loginflag': 1, 'platform': '20'},
        },
      );
      for (final entry in rows(d['midurlinfo'])) {
        final mid = text(entry, ['songmid']), purl = text(entry, ['purl']);
        if (purl.isEmpty || mid.isNotEmpty && mid != song.mid) continue;
        final hosts = d['sip'] is List
            ? (d['sip'] as List)
                  .whereType<String>()
                  .where(validStreamUrl)
                  .toList()
            : <String>[];
        if (hosts.isEmpty) {
          final dispatch = await rpc(
            'music.audioCdnDispatch.cdnDispatch',
            'GetCdnDispatch',
            {'guid': guid, 'uid': '0', 'use_new_domain': 1, 'use_ipv6': 1},
          );
          hosts.addAll(
            (dispatch['sip'] as List? ?? []).whereType<String>().where(
              validStreamUrl,
            ),
          );
        }
        if (hosts.isEmpty) hosts.add('http://dl.stream.qqmusic.qq.com/');
        final uri = Uri.parse(hosts.first).resolve(purl);
        if (!validStreamUrl(uri.toString())) {
          throw const MusicError('QQ 音乐返回了不可信的播放地址');
        }
        return SongStream(uri, format.quality, format.ext);
      }
    }
    throw const MusicError('QQ 音乐未提供播放链接，可能需要登录、会员或相应地区版权权限');
  }

  static bool validStreamUrl(String value) {
    final u = Uri.tryParse(value);
    return u != null &&
        ['http', 'https'].contains(u.scheme) &&
        u.userInfo.isEmpty &&
        (u.host == 'qqmusic.qq.com' ||
            u.host.endsWith('.qqmusic.qq.com') ||
            u.host.endsWith('.qq.com'));
  }

  Future<List<LyricLine>> lyrics(Song song) async {
    final d = await cgi('/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
      'songmid': song.mid,
      'pcachetime': song.id,
    });
    String decodeLyric(dynamic value) {
      if (value == null || value == '') return '';
      try {
        return utf8.decode(base64Decode('$value'));
      } on FormatException {
        throw const MusicError('QQ 音乐歌词编码异常');
      }
    }

    final original = decodeLyric(d['lyric']);
    var translation = decodeLyric(d['trans']);
    if (translation.isEmpty) {
      try {
        final translated = await rpc(
          'music.musichallSong.PlayLyricInfo',
          'GetPlayLyricInfo',
          {
            'songMID': song.mid,
            'songName': '',
            'singerName': '',
            'albumName': '',
            'interval': 0,
            'crypt': 0,
            'ct': 19,
            'cv': 2111,
            'lrc_t': 0,
            'qrc': 0,
            'qrc_t': 0,
            'roma': 0,
            'roma_t': 0,
            'trans': 1,
            'trans_t': 0,
            'type': 0,
          },
          comm: {
            'ct': 11,
            'cv': '1003006',
            'v': '1003006',
            'tmeAppID': 'qqmusiclight',
            'nettype': 'NETWORK_WIFI',
            'udid': '0',
            'uid': '0',
          },
          headers: {'Cookie': 'tmeLoginType=-1', 'User-Agent': 'okhttp/3.14.9'},
        );
        translation = decodeLyric(translated['trans']);
      } on MusicError {
        /* Translation is optional; retain original lyrics. */
      } on DioException {
        /* Translation failure does not discard the original. */
      }
    }
    return parseLyrics(original, translation);
  }
}

String errorText(Object error) {
  if (error is MusicError) return error.message;
  if (error is DioException) {
    if (CancelToken.isCancel(error)) return '请求已取消';
    if (error.response?.statusCode != null) {
      return '网络请求失败（HTTP ${error.response!.statusCode}），请重试';
    }
    return '连接 QQ 音乐失败，请检查网络后重试';
  }
  return '操作未完成，请重试';
}
