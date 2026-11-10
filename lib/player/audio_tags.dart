import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../data/models.dart';

class AudioTags {
  const AudioTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.year = '',
    this.lyrics = '',
    this.cover,
    this.mime = '',
    this.width = 0,
    this.height = 0,
  });
  final String title, artist, album, year, lyrics, mime;
  final Uint8List? cover;
  final int width, height;
}

// Only called for a new, unpublished download. The audio payload is never re-encoded.
Future<File> writeAudioTags(File source, String format, AudioTags tags) async {
  final path = source.path;
  return File(await Isolate.run(() => _write(path, format, tags)));
}

List<int> _u32(int n, [Endian endian = Endian.big]) =>
    (ByteData(4)..setUint32(0, n, endian)).buffer.asUint8List();
List<int> _sync(int n) => [n >> 21 & 127, n >> 14 & 127, n >> 7 & 127, n & 127];
List<int> _utf16(String text) => [
  0xff,
  0xfe,
  for (final c in text.replaceAll('\u0000', '').codeUnits) ...[c & 255, c >> 8],
];

Uint8List _id3(AudioTags t) {
  final frames = BytesBuilder(copy: false);
  void frame(String id, List<int> bytes, [List<int>? attachment]) {
    frames.add([
      ...ascii.encode(id),
      ..._u32(bytes.length + (attachment?.length ?? 0)),
      0,
      0,
    ]);
    frames.add(bytes);
    if (attachment != null) frames.add(attachment);
  }

  for (final entry in {
    'TIT2': t.title,
    'TPE1': t.artist,
    'TALB': t.album,
    'TYER': t.year,
  }.entries) {
    if (entry.value.isNotEmpty) frame(entry.key, [1, ..._utf16(entry.value)]);
  }
  if (t.lyrics.isNotEmpty) {
    frame('USLT', [
      1,
      ...ascii.encode('und'),
      ..._utf16(''),
      0,
      0,
      ..._utf16(t.lyrics),
    ]);
  }
  if (t.cover != null) {
    frame('APIC', [0, ...ascii.encode(t.mime), 0, 3, 0], t.cover);
  }
  final raw = frames.takeBytes();
  final safe = BytesBuilder(copy: false);
  for (var i = 0; i < raw.length; i++) {
    safe.addByte(raw[i]);
    if (raw[i] == 255 &&
        (i + 1 == raw.length || raw[i + 1] == 0 || raw[i + 1] >= 224)) {
      safe.addByte(0);
    }
  }
  final body = safe.takeBytes();
  return (BytesBuilder(copy: false)
        ..add([...ascii.encode('ID3'), 3, 0, 0x80, ..._sync(body.length)])
        ..add(body))
      .takeBytes();
}

List<int> _comments(AudioTags t, List<int>? old) {
  final fields = <String>[];
  if (old != null) {
    final data = ByteData.sublistView(Uint8List.fromList(old));
    var pos = 0;
    int readLength() {
      if (pos + 4 > old.length) throw const MusicError('FLAC 标签损坏');
      final n = data.getUint32(pos, Endian.little);
      pos += 4;
      return n;
    }

    String readString() {
      final length = readLength();
      if (pos + length > old.length) throw const MusicError('FLAC 标签损坏');
      final text = utf8.decode(old.sublist(pos, pos + length));
      pos += length;
      return text;
    }

    readString();
    final count = readLength();
    if (count > old.length ~/ 4) throw const MusicError('FLAC 标签损坏');
    for (var i = 0; i < count; i++) {
      fields.add(readString());
    }
  }
  for (final entry in {
    'TITLE': t.title,
    'ARTIST': t.artist,
    'ALBUM': t.album,
    'DATE': t.year,
    'LYRICS': t.lyrics,
  }.entries) {
    if (entry.value.isEmpty) continue;
    fields.removeWhere((v) => v.split('=').first.toUpperCase() == entry.key);
    fields.add('${entry.key}=${entry.value.replaceAll('\u0000', '')}');
  }
  List<int> value(String s) {
    final bytes = utf8.encode(s);
    return [..._u32(bytes.length, Endian.little), ...bytes];
  }

  return [
    ...value('GreenMusic'),
    ..._u32(fields.length, Endian.little),
    for (final f in fields) ...value(f),
  ];
}

List<int> _picture(AudioTags t) {
  final mime = ascii.encode(t.mime);
  return (BytesBuilder(copy: false)
        ..add([
          ..._u32(3),
          ..._u32(mime.length),
          ...mime,
          ..._u32(0),
          ..._u32(t.width),
          ..._u32(t.height),
          ..._u32(0), // RFC 9639: unknown source-image bit depth is zero.
          ..._u32(0),
          ..._u32(t.cover!.length),
        ])
        ..add(t.cover!))
      .takeBytes();
}

String _write(String path, String format, AudioTags tags) {
  if ([
            tags.title,
            tags.artist,
            tags.album,
            tags.year,
            tags.lyrics,
          ].fold<int>(0, (n, s) => n + s.length) >
          1024 * 1024 ||
      (tags.cover?.length ?? 0) > 5 * 1024 * 1024) {
    throw const MusicError('歌曲标签过大');
  }
  final source = File(path).openSync();
  final output = File('$path.tags.part');
  RandomAccessFile? sink;
  try {
    final length = source.lengthSync();
    List<int> read(int size) {
      if (size < 0 || size > 16 * 1024 * 1024) throw const MusicError('音频标签过大');
      final bytes = source.readSync(size);
      if (bytes.length != size) throw const MusicError('音频文件不完整');
      return bytes;
    }

    var end = length;
    final header = BytesBuilder(copy: false);
    if (format == 'mp3') {
      final prefix = read(10);
      var start = 0;
      if (ascii.decode(prefix.take(3).toList(), allowInvalid: true) == 'ID3') {
        if (![2, 3, 4].contains(prefix[3]) ||
            prefix.skip(6).any((b) => b > 127)) {
          throw const MusicError('不支持的 MP3 标签头');
        }
        start = 10 + prefix.skip(6).fold<int>(0, (a, b) => (a << 7) | b);
        if (prefix[3] == 4 && prefix[5] & 16 != 0) start += 10;
      }
      if (start + 4 > length) throw const MusicError('MP3 文件不完整');
      source.setPositionSync(start);
      final frame = read(4);
      if (frame[0] != 255 || frame[1] & 224 != 224 || frame[1] & 6 == 0) {
        throw const MusicError('音源不是有效的 MP3 文件');
      }
      if (length - start >= 128) {
        source.setPositionSync(length - 128);
        if (ascii.decode(read(3), allowInvalid: true) == 'TAG') end -= 128;
      }
      source.setPositionSync(start);
      header.add(_id3(tags));
    } else if (format == 'flac') {
      if (ascii.decode(read(4), allowInvalid: true) != 'fLaC') {
        throw const MusicError('音源不是有效的 FLAC 文件');
      }
      final blocks = <(int, List<int>)>[];
      List<int>? comments;
      var last = false;
      var total = 0;
      while (!last) {
        final h = read(4);
        last = h[0] & 128 != 0;
        final type = h[0] & 127;
        final size = (h[1] << 16) | (h[2] << 8) | h[3];
        total += size + 4;
        if (total > 16 * 1024 * 1024 || type == 127) {
          throw const MusicError('FLAC 标签无效或过大');
        }
        final body = read(size);
        if (blocks.isEmpty && (type != 0 || size != 34)) {
          throw const MusicError('FLAC 缺少音频信息');
        }
        if (type == 4) {
          comments = body;
        } else if (type != 1 &&
            !(type == 6 &&
                tags.cover != null &&
                size >= 4 &&
                ByteData.sublistView(Uint8List.fromList(body)).getUint32(0) ==
                    3)) {
          blocks.add((type, body));
        }
      }
      if (source.positionSync() >= length) {
        throw const MusicError('FLAC 没有音频数据');
      }
      blocks.add((4, _comments(tags, comments)));
      if (tags.cover != null) blocks.add((6, _picture(tags)));
      header.add(ascii.encode('fLaC'));
      for (var i = 0; i < blocks.length; i++) {
        final (type, body) = blocks[i];
        if (body.length > 0xffffff) throw const MusicError('FLAC 标签过大');
        header.add([
          type | (i == blocks.length - 1 ? 128 : 0),
          body.length >> 16,
          body.length >> 8 & 255,
          body.length & 255,
        ]);
        header.add(body);
      }
    } else {
      throw const MusicError('暂不支持此音频格式的标签写入');
    }
    if (header.length > 16 * 1024 * 1024) throw const MusicError('音频标签过大');
    sink = output.openSync(mode: FileMode.write);
    sink.writeFromSync(header.takeBytes());
    final buffer = Uint8List(256 * 1024);
    while (source.positionSync() < end) {
      final remaining = end - source.positionSync();
      final n = source.readIntoSync(
        buffer,
        0,
        remaining < buffer.length ? remaining : buffer.length,
      );
      if (n == 0) throw const MusicError('音频文件不完整');
      sink.writeFromSync(buffer, 0, n);
    }
    sink.flushSync();
    return output.path;
  } catch (_) {
    sink?.closeSync();
    sink = null;
    if (output.existsSync()) output.deleteSync();
    rethrow;
  } finally {
    sink?.closeSync();
    source.closeSync();
  }
}
