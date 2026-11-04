// Adapted from Lilt internal/qqmusic (AGPL-3.0); see THIRD_PARTY_NOTICES.md.
import 'dart:convert';

typedef Json = Map<String, dynamic>;
Json obj(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> rows(dynamic value) =>
    value is List ? value.whereType<Map>().map(obj).toList() : [];
int integer(dynamic value) => int.tryParse('$value') ?? 0;
String text(Json value, List<String> keys) {
  for (final key in keys) {
    final v = value[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return '';
}

int number(Json value, List<String> keys) {
  for (final key in keys) {
    final v = int.tryParse('${value[key]}');
    if (v != null) return v;
  }
  return 0;
}

String albumCover(String mid) => mid.isEmpty
    ? ''
    : 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$mid.jpg';
String artistCover(String mid) => mid.isEmpty
    ? ''
    : 'https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg';

class Artist {
  const Artist(this.id, this.mid, this.name);
  factory Artist.fromJson(Json j) => Artist(
    number(j, ['id', 'singerid', 'singer_id', 'singerID']),
    text(j, ['mid', 'singermid', 'singer_mid', 'singerMid', 'singerMID']),
    text(j, ['name', 'singername', 'singer_name', 'singerName']),
  );
  final int id;
  final String mid, name;
  String get cover => artistCover(mid);
}

class Album {
  const Album(this.id, this.mid, this.name, {this.picture = ''});
  factory Album.fromJson(Json j) => Album(
    number(j, ['id', 'albumid', 'albumID', 'album_id']),
    text(j, ['mid', 'albummid', 'albumMID', 'albumMid', 'album_mid', 'pmid']),
    text(j, ['name', 'title', 'albumname', 'albumName', 'album_name']),
    picture: text(j, ['albumPic', 'picUrl']),
  );
  final int id;
  final String mid, name, picture;
  String get cover => picture.isNotEmpty ? picture : albumCover(mid);
}

class Song {
  Song.fromJson(Json input) {
    raw = input;
    for (final key in ['musicData', 'songInfo', 'track_info']) {
      if (raw[key] is Map) raw = obj(raw[key]);
    }
    id = number(raw, ['id', 'songid', 'songId']);
    mid = text(raw, ['mid', 'songmid', 'songMid']);
    name = text(raw, ['title', 'name', 'songname', 'songName']);
    duration = Duration(seconds: integer(raw['interval']));
    artists = rows(raw['singer'] ?? raw['singers'])
        .map(Artist.fromJson)
        .toList();
    album = Album.fromJson(obj(raw['album']));
    if (album.mid.isEmpty) {
      album = Album(
        album.id > 0 ? album.id : number(raw, ['albumid', 'album_id']),
        text(raw, ['albummid', 'album_mid']),
        album.name.isNotEmpty
            ? album.name
            : text(raw, ['albumname', 'album_name']),
        picture: album.picture,
      );
    }
    final fileMid = text(obj(raw['file']), ['media_mid']);
    mediaMid = fileMid.isEmpty
        ? text(raw, ['strMediaMid', 'media_mid'])
        : fileMid;
  }
  late Json raw;
  late final int id;
  late final String mid, name, mediaMid;
  late final Duration duration;
  late final List<Artist> artists;
  late Album album;
  String get artistNames => artists.map((a) => a.name).join(' / ');
  String get cover => album.cover;
  int downloadBytes(String quality) {
    final (fileKey, legacyKey) = switch (quality) {
      'exhigh' => ('size_320mp3', 'size320'),
      'lossless' => ('size_flac', 'sizeflac'),
      _ => ('size_128mp3', 'size128'),
    };
    final size = number(obj(raw['file']), [fileKey]);
    final result = size > 0 ? size : number(raw, [legacyKey]);
    return result > 0 ? result : 0;
  }

  bool get valid => id > 0 && mid.isNotEmpty;
}

List<Song> songs(dynamic value) =>
    rows(value).map(Song.fromJson).where((s) => s.valid).toList();

class MusicList {
  const MusicList({
    required this.id,
    required this.name,
    this.cover = '',
    this.description = '',
    this.count = 0,
    this.chart = false,
    this.owned = false,
    this.dirId = 0,
    this.saved = false,
  });
  factory MusicList.library(Json j, {bool owned = false, bool saved = false}) =>
      MusicList(
        id: number(j, ['tid', 'dissid', 'id']),
        name: text(j, ['dirName', 'title', 'dissname', 'name']),
        cover: text(j, [
          'bigpicUrl',
          'picUrl',
          'picurl',
          'coverUrl',
          'logo',
          'albumPicUrl',
        ]),
        description: text(j, ['desc']),
        count: number(j, ['songNum', 'songnum', 'song_cnt']),
        dirId: number(j, ['dirId', 'dirid']),
        owned: owned,
        saved: saved,
      );
  final int id, count, dirId;
  final String name, cover, description;
  final bool chart, owned, saved;
  bool get editable => owned && dirId > 0 && dirId < 200;
}

class SearchPage {
  const SearchPage({
    required this.source,
    required this.nextOffset,
    required this.total,
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
  });
  final String source;
  final int nextOffset, total;
  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  int get length => songs.length + albums.length + artists.length;
  bool get more => nextOffset > 0 && nextOffset < total;
}

class SongPage {
  const SongPage(this.items, this.nextOffset, this.more);
  final List<Song> items;
  final int nextOffset;
  final bool more;
}

class MusicSession {
  MusicSession(this.raw);
  final Json raw;
  String get id => '${raw['str_musicid'] ?? raw['musicid'] ?? ''}';
  String get key => text(raw, ['musickey']);
  String get nickname => text(raw, ['nick']).isEmpty ? id : text(raw, ['nick']);
  String get avatar => text(raw, ['logo']);
  int get loginType => integer(raw['loginType']);
  String get encryptUin => text(raw, ['encryptUin']);
  bool get validIdentity =>
      (int.tryParse(id) ?? 0) > 0 &&
      key.isNotEmpty &&
      !RegExp(r'[\r\n;]').hasMatch(key) &&
      [1, 2].contains(loginType);
  bool get expired {
    final created = integer(raw['musickeyCreateTime']),
        expires = integer(raw['keyExpiresIn']);
    return created > 0 &&
        expires > 0 &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 >= created + expires;
  }

  bool get canRefresh =>
      loginType == 1 && text(raw, ['refresh_key', 'refresh_token']).isNotEmpty;
  String get cookie =>
      'uin=$id; qqmusic_uin=$id; qm_keyst=$key; qqmusic_key=$key';
  Json get comm => {
    ...deviceComm(obj(raw['device'])),
    'qq': id,
    'authst': key,
    'tmeLoginType': loginType,
  };
  String encode() => jsonEncode(raw);
}

Json deviceComm(Json d) => {
  'ct': 11,
  'cv': 14090008,
  'v': 14090008,
  'chid': '10003505',
  'tmeAppID': 'qqmusic',
  if (d.isNotEmpty) ...{
    'QIMEI': d['qimei'],
    'QIMEI36': d['qimei36'],
    'OpenUDID': d['openUdid'],
    'udid': d['openUdid'],
    'OpenUDID2': d['openUdid'],
    'aid': d['androidId'],
    'os_ver': '10',
    'phonetype': 'MI 6',
    'devicelevel': '29',
    'newdevicelevel': '29',
    'rom': 'xiaomi/iarim/sagit:10/eomam.200122.001/2001221:user/release-keys',
    if (d['uid'] != null) 'uid': d['uid'],
    if (d['sid'] != null) 'sid': d['sid'],
  },
};

class MusicError implements Exception {
  const MusicError(this.message, {this.code});
  final String message;
  final int? code;
  bool get authRejected => [1000, 104400, 104401].contains(code);
  @override
  String toString() => message;
}

class SongStream {
  const SongStream(this.uri, this.quality, this.format);
  final Uri uri;
  final String quality, format;
}

class LyricLine {
  const LyricLine(this.time, this.text, {this.translation = ''});
  final Duration time;
  final String text, translation;
}

List<LyricLine> parseLyrics(String original, String translation) {
  List<LyricLine> parse(String input) {
    final out = <LyricLine>[];
    var offset = 0;
    final offsetTag = RegExp(r'\[offset:([+-]?\d+)\]').firstMatch(input);
    if (offsetTag != null) offset = integer(offsetTag[1]);
    final tag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    for (final line in const LineSplitter().convert(input)) {
      final matches = tag.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final content = line.substring(matches.last.end).trim();
      for (final m in matches) {
        final fraction = (m[3] ?? '').padRight(3, '0');
        final millis =
            integer(m[1]) * 60000 +
            integer(m[2]) * 1000 +
            integer(fraction) +
            offset;
        out.add(
          LyricLine(Duration(milliseconds: millis < 0 ? 0 : millis), content),
        );
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  final trans = {
    for (final line in parse(translation)) line.time.inMilliseconds: line.text,
  };
  return parse(original)
      .map(
        (l) => LyricLine(
          l.time,
          l.text,
          translation: trans[l.time.inMilliseconds] ?? '',
        ),
      )
      .toList();
}
