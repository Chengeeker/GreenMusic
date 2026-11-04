// Adapted from Lilt library.go / purchased.go / social.go (AGPL-3.0).
import 'models.dart';
import 'qq_music_api.dart';

import 'package:dio/dio.dart';

class LibraryPage<T> {
  const LibraryPage(this.items, this.more, this.nextOffset);
  final List<T> items;
  final bool more;
  final int nextOffset;
}

class CommentPage {
  const CommentPage(this.items, this.total, this.cursor);
  final List<Json> items;
  final int total;
  final Json? cursor;
}

extension LibraryApi on QqMusicApi {
  Future<List<Json>> ownedEntries() async {
    final s = requireSession();
    final d = await rpc(
      'music.musicasset.PlaylistBaseRead',
      'GetPlaylistByUin',
      {'uin': s.id},
    );
    if (d['v_playlist'] is! List) throw const MusicError('QQ 音乐未返回我的歌单');
    return rows(d['v_playlist']);
  }

  Future<List<MusicList>> ownedLists() async => (await ownedEntries())
      .map((j) => MusicList.library(j, owned: true))
      .where((p) => p.id > 0)
      .toList();
  Future<LibraryPage<MusicList>> savedLists([int offset = 0]) async {
    final s = requireSession();
    if (s.encryptUin.isEmpty) throw const MusicError('登录凭据缺少账号标识，请重新扫码');
    final d = await rpc(
      'music.musicasset.PlaylistFavRead',
      'CgiGetPlaylistFavInfo',
      {'uin': s.encryptUin, 'offset': offset, 'size': 100},
    );
    if (d['v_list'] is! List) throw const MusicError('QQ 音乐未返回收藏歌单');
    final entries = rows(d['v_list']);
    return LibraryPage(
      entries
          .map((j) => MusicList.library(j, saved: true))
          .where((p) => p.id > 0)
          .toList(),
      d['hasmore'] == true || integer(d['hasmore']) == 1,
      offset + entries.length,
    );
  }

  Future<Json> ordinaryPlaylist(int id) async {
    final s = requireSession();
    final entries = (await ownedEntries())
        .where((j) => integer(j['tid']) == id)
        .toList();
    if (entries.length != 1) throw const MusicError('只能编辑自己创建的普通歌单');
    final entry = entries.single, dir = integer(entries.single['dirId']);
    if (dir <= 0 ||
        dir >= 200 ||
        integer(entry['dirType']) != 0 ||
        entry['uin'] != null && '${entry['uin']}' != s.id) {
      throw const MusicError('只能编辑自己创建的普通歌单');
    }
    return entry;
  }

  Future<Json> writeResult(String module, String method, Json param) async {
    requireSession();
    final d = await rpc(module, method, param);
    if ('${d['retCode']}' != '0' || d['result'] is! Map) {
      throw const MusicError('QQ 音乐未确认更改，请刷新检查，避免重复提交');
    }
    return obj(d['result']);
  }

  void validatePlaylistName(String name) {
    if (name.trim().isEmpty ||
        name.runes.length > 20 ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(name)) {
      throw const MusicError('歌单名称应为 1–20 个字符且不含控制字符');
    }
  }

  Future<MusicList> createPlaylist(String name) async {
    validatePlaylistName(name);
    final result = await writeResult(
      'music.musicasset.PlaylistBaseWrite',
      'AddPlaylist',
      {'dirName': name},
    );
    final id = integer(result['tid']), dir = integer(result['dirId']);
    if (id <= 0 || dir <= 0 || dir >= 200) {
      throw const MusicError('QQ 音乐未返回新歌单标识');
    }
    final entry = await ordinaryPlaylist(id);
    if (integer(entry['dirId']) != dir) {
      throw const MusicError('新歌单标识不一致，请刷新检查');
    }
    return MusicList.library(entry, owned: true);
  }

  Future<void> renamePlaylist(int id, String name) async {
    validatePlaylistName(name);
    final entry = await ordinaryPlaylist(id), dir = integer(entry['dirId']);
    Future<Json> settings() async {
      final d = await rpc(
        'music.srfDissInfo.aiDissInfo',
        'uniform_get_Dissinfo',
        {'dirid': dir, 'optype': 3, 'tag': 1, 'userinfo': 0, 'pic_dpi': 300},
      );
      final info = obj(d['dirinfo']);
      if (integer(info['dirid']) != dir ||
          [
            'title',
            'desc',
            'picurl',
            'picurl2',
          ].any((k) => info[k] is! String) ||
          info['tag'] is! List ||
          (info['tag'] as List).length > 3) {
        throw const MusicError('歌单设置不完整，无法安全保留后更名');
      }
      return info;
    }

    final before = await settings(), show = integer(before['dir_show']);
    if (![1, 2].contains(show) || before['picurl2'] != '') {
      throw const MusicError('此歌单暂不支持保留原设置后更名');
    }
    final tags = rows(before['tag']).map((j) => integer(j['id'])).toList();
    if (tags.any((n) => n <= 0) ||
        tags.length != (before['tag'] as List).length) {
      throw const MusicError('歌单标签无效');
    }
    final result = await writeResult(
      'music.musicasset.PlaylistBaseWrite',
      'EditPlaylist',
      {
        'dirId': dir,
        'mask': 95,
        'dirNewName': name,
        'dirNewDesc': before['desc'],
        'dirNewPicUrl': before['picurl'],
        'dirNewPicUrl2': '',
        'dirNewtaglist': tags.join(','),
        'dirShow': show,
      },
    );
    if (integer(result['tid']) != id || integer(result['dirId']) != dir) {
      throw const MusicError('QQ 音乐未确认歌单更名');
    }
    final after = await settings();
    if (after['title'] != name ||
        after['desc'] != before['desc'] ||
        after['picurl'] != before['picurl'] ||
        integer(after['dir_show']) != show) {
      throw const MusicError('更名后设置未被确认，请刷新检查');
    }
  }

  Future<void> editPlaylistSongs(
    int id,
    List<int> songIds, {
    bool add = true,
  }) async {
    if (songIds.isEmpty || songIds.length > 100 || songIds.any((n) => n <= 0)) {
      throw const MusicError('一次请选择 1–100 首有效歌曲');
    }
    final entry = await ordinaryPlaylist(id), dir = integer(entry['dirId']);
    final result = await writeResult(
      'music.musicasset.PlaylistDetailWrite',
      add ? 'AddSonglist' : 'DelSonglist',
      {
        'dirId': dir,
        'v_songInfo': [
          for (final song in songIds) {'songId': song, 'songType': 0},
        ],
      },
    );
    if (integer(result['tid']) != id || integer(result['dirId']) != dir) {
      throw const MusicError('QQ 音乐未确认歌曲更改，请刷新检查');
    }
  }

  Future<void> deletePlaylist(int id) async {
    final entry = await ordinaryPlaylist(id), dir = integer(entry['dirId']);
    final result = await writeResult(
      'music.musicasset.PlaylistBaseWrite',
      'DelPlaylist',
      {'dirId': dir},
    );
    if (integer(result['tid']) != id ||
        integer(result['dirId']) != dir ||
        integer(result['updateTime']) != 0) {
      throw const MusicError('QQ 音乐未确认删除歌单');
    }
    if ((await ownedEntries()).any(
      (j) => integer(j['tid']) == id || integer(j['dirId']) == dir,
    )) {
      throw const MusicError('删除后仍返回此歌单，请刷新检查');
    }
  }

  Future<bool> songLiked(Song song) async {
    requireSession();
    final d = await rpc('music.musicasset.SongFavRead', 'IsSongFanByMid', {
      'v_songMid': [song.mid],
    });
    final value = obj(d['m_fan'])[song.mid];
    if (value is! bool) throw const MusicError('QQ 音乐未返回喜欢状态');
    return value;
  }

  Future<void> likeSong(Song input, bool liked) async {
    requireSession();
    final song = await songDetail(input);
    if (await songLiked(song) == liked) return;
    await writeResult(
      'music.musicasset.PlaylistDetailWrite',
      liked ? 'AddSonglist' : 'DelSonglist',
      {
        'dirId': 201,
        'v_songInfo': [
          {'songId': song.id, 'songType': 0},
        ],
      },
    );
    if (await songLiked(song) != liked) {
      throw const MusicError('QQ 音乐未确认喜欢状态的更改');
    }
  }

  Future<bool> albumLiked(Album album) async {
    final s = requireSession();
    if (!RegExp(r'^[A-Za-z0-9]{1,64}$').hasMatch(album.mid)) {
      throw const MusicError('专辑标识无效');
    }
    final id = int.parse(s.id);
    final d = await rpc('music.musicasset.AlbumFavRead', 'IsAlbumFan', {
      'uin': id <= 9007199254740991 ? id : s.id,
      'v_albumMid': [album.mid],
    });
    final value = obj(d['m_fan'])[album.mid];
    if (value is! bool) throw const MusicError('QQ 音乐未返回专辑收藏状态');
    return value;
  }

  Future<void> likeAlbum(Album album, bool liked) async {
    final s = requireSession();
    if (await albumLiked(album) == liked) return;
    final d = await rpc(
      'music.musicasset.AlbumFavWrite',
      liked ? 'FavAlbum' : 'CancelFavAlbum',
      {
        'uin': s.id,
        'v_albumMid': [album.mid],
      },
    );
    if ('${d['result']}' != '0' ||
        d['v_failedAlbumId'] is! List ||
        d['v_failedAlbumMid'] is! List ||
        (d['v_failedAlbumId'] as List).isNotEmpty ||
        (d['v_failedAlbumMid'] as List).isNotEmpty) {
      throw const MusicError('QQ 音乐未确认专辑收藏更改');
    }
    if (await albumLiked(album) != liked) {
      throw const MusicError('QQ 音乐未确认专辑收藏状态');
    }
  }

  Future<void> unfavoritePlaylist(int id) async {
    final s = requireSession();
    final d = await rpc(
      'music.musicasset.PlaylistFavWrite',
      'CancelFavPlaylist',
      {
        'uin': s.id,
        'v_playlistId': [id],
      },
    );
    if ('${d['result']}' != '0' ||
        d['v_failedPlaylistId'] is! List ||
        (d['v_failedPlaylistId'] as List).isNotEmpty) {
      throw const MusicError('QQ 音乐未确认取消收藏歌单');
    }
  }

  Future<LibraryPage<Album>> likedAlbums([int offset = 0]) async {
    final s = requireSession();
    final d = obj(
      (await cgi('/fav/fcgi-bin/fcg_get_profile_order_asset.fcg', {
        'ct': 20,
        'cid': 205360956,
        'userid': s.id,
        'reqtype': 2,
        'sin': offset,
        'ein': offset + 29,
      }))['data'],
    );
    if (d['totalalbum'] == null ||
        d['albumlist'] is! List && integer(d['totalalbum']) > 0) {
      throw const MusicError('QQ 音乐未返回收藏专辑列表');
    }
    final entries = rows(d['albumlist']);
    if (entries.isEmpty && offset < integer(d['totalalbum'])) {
      throw const MusicError('QQ 音乐收藏专辑列表不完整');
    }
    return LibraryPage(
      entries.map(Album.fromJson).toList(),
      offset + entries.length < integer(d['totalalbum']),
      offset + entries.length,
    );
  }

  Future<LibraryPage<Json>> purchasedPage(bool albums, int offset) async {
    final s = requireSession(), token = hash33(s.key);
    final body = await cgi('/shop/fcgi-bin/fcg_get_order', {
      'from': 1,
      'cmd': 'sales_album',
      'type': albums ? 1 : 2,
      'uin': s.id,
      'start': offset,
      'num': 30,
      'platform': 'yqq',
      'ct': 24,
      'cv': 4747474,
      'inCharset': 'utf-8',
      'notice': 0,
      'needNewCode': 1,
      'g_tk': token,
      'g_tk_new_20200303': token,
    });
    final d = obj(body['data']);
    QqMusicApi.checkStatus(d);
    final key = albums ? 'albumlist' : 'songlist',
        count = int.tryParse('${d['total']}');
    if (count == null || count < 0 || d[key] is! List && count > 0) {
      throw const MusicError('QQ 音乐未返回有效已购列表');
    }
    final entries = rows(d[key]);
    if (entries.isEmpty && offset < count) {
      throw const MusicError('QQ 音乐已购列表不完整');
    }
    return LibraryPage(
      entries,
      offset + entries.length < count,
      offset + entries.length,
    );
  }

  Future<CommentPage> comments(
    Song song, {
    Json? cursor,
    bool hot = false,
  }) async {
    final page = cursor ?? <String, dynamic>{};
    final d = await rpc(
      'music.globalComment.CommentRead',
      hot ? 'GetHotCommentList' : 'GetNewCommentList',
      {
        'BizType': 1,
        'BizId': '${song.id}',
        'PageSize': 25,
        'PageNum': page['page'] ?? 0,
        'LastCommentSeqNo': page['sequence'] ?? '',
        'PicEnable': 1,
        if (hot) ...{
          'HotType': 1,
          'WithAirborne': 0,
        } else ...{
          'FromCommentId': '',
          'WithHot': 0,
          'LastTotal': page['total'] ?? 0,
          'LastTotalVer': page['version'] ?? '0',
        },
      },
      comm: Map.of(webComm),
      headers: {'Cookie': ''},
    );
    final list = obj(d['CommentList']);
    if (list['Comments'] is! List) throw const MusicError('QQ 音乐未返回评论列表');
    final entries = rows(list['Comments']);
    final sequence = entries.isEmpty ? '' : text(entries.last, ['SeqNo']);
    final more =
        sequence.isNotEmpty &&
        (list['HasMore'] == true || integer(list['HasMore']) == 1);
    return CommentPage(
      entries,
      integer(list['Total']),
      more
          ? {
              'sequence': sequence,
              'page': integer(page['page']) + 1,
              'total': integer(list['Total']),
              'version': d['TotalVer'] ?? '0',
            }
          : null,
    );
  }

  Future<List<({String title, List<Song> tracks})>> songShelves() async {
    final s = requireSession();
    final comm = {
      'format': 'json',
      'ct': 20,
      'cv': 2276,
      'platform': 'wk_v17',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'needNewCode': 1,
      'uin': s.id,
      'qq': s.id,
      'authst': s.key,
      'tmeLoginType': s.loginType,
      'g_tk': 0,
      'g_tk_new_20200303': 0,
    };
    final shelves = <({String title, List<int> ids})>[];
    var received = 0;
    for (var page = 1; page <= 10; page++) {
      Json d;
      try {
        d = await rpc('music.recommend.RecommendFeed', 'get_recommend_feed', {
          'direction': page == 1 ? 0 : 1,
          'page': page,
          's_num': received,
          'v_cache': <String>[],
          'v_uniq': <String>[],
        }, comm: comm);
        if (!d.containsKey('retcode') || d['v_shelf'] is! List) {
          throw const MusicError('QQ 音乐未返回推荐歌曲状态或列表');
        }
      } catch (e) {
        if (shelves.isEmpty || !(e is MusicError || e is DioException)) rethrow;
        break;
      }
      final batch = rows(d['v_shelf']);
      received += batch.length;
      for (final shelf in batch.where((j) => integer(j['id']) == 207)) {
        final cards = [
          for (final niche in rows(shelf['v_niche'])) ...rows(niche['v_card']),
        ];
        final songIds = {
          for (final c in cards.where((j) => integer(j['type']) == 200))
            integer(c['id']),
        };
        final others = {
          for (final c in cards.where((j) => integer(j['type']) != 200))
            integer(c['id']),
        };
        final raw = text(obj(shelf['miscellany']), [
          'songList',
        ]).split(',').map((x) => integer(x.trim()));
        var ids = raw
            .where(
              (id) => id > 0 && (!others.contains(id) || songIds.contains(id)),
            )
            .toSet()
            .toList();
        if (ids.isEmpty) ids = songIds.where((id) => id > 0).toList();
        if (ids.isEmpty) continue;
        var title = text(shelf, ['title_template', 'title_content'])
            .replaceAll('{String}', text(shelf, ['title_content']))
            .replaceAll('\u2062', '')
            .trim();
        if (title.isEmpty) title = '为你推荐的歌曲';
        shelves.add((title: title, ids: ids));
      }
      if (shelves.length >= 3 ||
          batch.isEmpty ||
          d['load_mark'] == null ||
          integer(d['load_mark']) != 0) {
        break;
      }
    }
    final ids = shelves.expand((s) => s.ids).toSet().toList();
    if (ids.isEmpty) return [];
    final tracks = <int, Song>{};
    for (var start = 0; start < ids.length; start += 100) {
      final batch = ids.skip(start).take(100).toList();
      final d = await rpc(
        'music.trackInfo.UniformRuleCtrl',
        'CgiGetTrackInfo',
        {'ids': batch, 'types': List.filled(batch.length, 0)},
        comm: comm,
      );
      if (d['tracks'] is! List) throw const MusicError('QQ 音乐未返回推荐歌曲详情');
      for (final song in songs(d['tracks'])) {
        tracks[song.id] = song;
      }
    }
    return [
      for (final shelf in shelves)
        (
          title: shelf.title,
          tracks: [
            for (final id in shelf.ids)
              if (tracks[id] != null) tracks[id]!,
          ],
        ),
    ];
  }
}
