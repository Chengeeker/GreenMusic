import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/data/models.dart';
import 'package:greenmusic/player/audio_tags.dart';

List<int> u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
List<int> comment(String s) => [
  ...u32(utf8.encode(s).length),
  ...utf8.encode(s),
];

void main() {
  late Directory directory;
  final cover = Uint8List.fromList([255, 216, 255, 224, 0, 0, 255, 217]);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tags-test');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  AudioTags tags() => AudioTags(
    title: '中文标题 🎵',
    artist: '歌手 / Artist',
    album: '专辑',
    year: '2024',
    lyrics: '[00:01.00]歌词\n[00:01.00]Translation',
    cover: cover,
    mime: 'image/jpeg',
    width: 500,
    height: 500,
  );

  test('ID3v2.3 writes UTF16, USLT and APIC; preserves payload and replaces old tag', () async {
    final audio = [255, 251, 144, 0, ...List.filled(4096, 23)];
    final input = File('${directory.path}/input.mp3');
    await input.writeAsBytes([
      ...ascii.encode('ID3'),
      4,
      0,
      0,
      0,
      0,
      0,
      4,
      0,
      0,
      0,
      0,
      ...audio,
    ]);
    final before = await input.readAsBytes();
    final output = await writeAudioTags(input, 'mp3', tags());
    final bytes = await output.readAsBytes();
    expect(bytes.take(6), [73, 68, 51, 3, 0, 128]);
    final size = bytes.sublist(6, 10).fold<int>(0, (a, b) => (a << 7) | b);
    expect(bytes.sublist(10 + size), audio);
    final decoded = <int>[];
    for (var i = 10; i < 10 + size; i++) {
      decoded.add(bytes[i]);
      if (bytes[i] == 255 && i + 1 < 10 + size && bytes[i + 1] == 0) i++;
    }
    final frames = <String, List<int>>{};
    for (var pos = 0; pos < decoded.length;) {
      final id = ascii.decode(decoded.sublist(pos, pos + 4));
      final length = ByteData.sublistView(
        Uint8List.fromList(decoded),
        pos + 4,
        pos + 8,
      ).getUint32(0);
      frames[id] = decoded.sublist(pos + 10, pos + 10 + length);
      pos += 10 + length;
    }
    final title = frames['TIT2']!;
    expect(title.take(3), [1, 255, 254]);
    expect(
      String.fromCharCodes([
        for (var i = 3; i < title.length; i += 2) title[i] | title[i + 1] << 8,
      ]),
      '中文标题 🎵',
    );
    expect(frames.keys, containsAll(['TPE1', 'TALB', 'TYER', 'USLT', 'APIC']));
    expect(
      frames['APIC']!.sublist(frames['APIC']!.length - cover.length),
      cover,
    );
    expect(await input.readAsBytes(), before);
  });

  test(
    'FLAC retains STREAMINFO, seek table, extra comments and audio bytes',
    () async {
      final info = List.filled(34, 1), seek = List.filled(18, 0);
      final comments = [
        ...comment('old'),
        ...u32(2),
        ...comment('REPLAYGAIN_TRACK_GAIN=-3 dB'),
        ...comment('TITLE=old'),
      ];
      final audio = [255, 248, ...List.filled(2048, 7)];
      final input = File('${directory.path}/input.flac');
      await input.writeAsBytes([
        ...ascii.encode('fLaC'),
        0,
        0,
        0,
        34,
        ...info,
        3,
        0,
        0,
        18,
        ...seek,
        132,
        0,
        comments.length >> 8,
        comments.length & 255,
        ...comments,
        ...audio,
      ]);
      final output = await writeAudioTags(input, 'flac', tags());
      final bytes = await output.readAsBytes();
      final blocks = <int, List<int>>{};
      var pos = 4;
      while (true) {
        final h = bytes[pos],
            size = bytes[pos + 1] << 16 | bytes[pos + 2] << 8 | bytes[pos + 3];
        blocks[h & 127] = bytes.sublist(pos + 4, pos + 4 + size);
        pos += size + 4;
        if (h & 128 != 0) break;
      }
      expect(blocks[0], info);
      expect(blocks[3], seek);
      expect(bytes.sublist(pos), audio);
      final text = utf8.decode(blocks[4]!, allowMalformed: true);
      for (final expected in [
        'TITLE=中文标题 🎵',
        'DATE=2024',
        'ARTIST=歌手 / Artist',
        'LYRICS=[00:01.00]歌词',
        'REPLAYGAIN_TRACK_GAIN=-3 dB',
      ]) {
        expect(text, contains(expected));
      }
      expect(text, isNot(contains('TITLE=old')));
      expect(blocks[6]!.sublist(blocks[6]!.length - cover.length), cover);
    },
  );

  test('malformed audio fails without modifying source or leaving a partial tagged file', () async {
    for (final format in ['mp3', 'flac']) {
      final input = File('${directory.path}/bad.$format');
      final original = utf8.encode('<html>not audio</html>');
      await input.writeAsBytes(original);
      await expectLater(
        writeAudioTags(input, format, tags()),
        throwsA(isA<MusicError>()),
      );
      expect(await input.readAsBytes(), original);
      expect(await File('${input.path}.tags.part').exists(), false);
    }
  });
}
