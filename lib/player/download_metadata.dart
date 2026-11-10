import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';

import '../data/models.dart';
import 'audio_tags.dart';

Future<AudioTags> downloadMetadata(
  Dio http,
  Song song,
  String lyrics,
  CancelToken cancel,
) async {
  Uint8List? cover;
  var mime = '', width = 0, height = 0;
  if (song.cover.isNotEmpty) {
    final uri = Uri.tryParse(song.cover);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const MusicError('封面地址无效');
    }
    final response = await http.get<ResponseBody>(
      song.cover,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Cookie': ''},
      ),
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (bytes.length + chunk.length > 5 * 1024 * 1024) {
        throw const MusicError('封面超过 5 MB，未写入歌曲');
      }
      bytes.add(chunk);
    }
    cover = bytes.takeBytes();
    if (cover.length >= 3 &&
        cover[0] == 255 &&
        cover[1] == 216 &&
        cover[2] == 255) {
      mime = 'image/jpeg';
    } else if (cover.length >= 8 &&
        cover[0] == 137 &&
        cover[1] == 80 &&
        cover[2] == 78 &&
        cover[3] == 71) {
      mime = 'image/png';
    } else {
      throw const MusicError('封面不是支持的 JPEG / PNG 图片');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(cover);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        width = descriptor.width;
        height = descriptor.height;
        if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
          throw const MusicError('封面尺寸无效或过大');
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }
  if (cancel.isCancelled) throw cancel.cancelError!;
  return AudioTags(
    title: song.name,
    artist: song.artistNames,
    album: song.album.name,
    year: song.releaseYear,
    lyrics: lyrics,
    cover: cover,
    mime: mime,
    width: width,
    height: height,
  );
}
