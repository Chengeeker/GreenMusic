// PROPFIND / MKCOL / latest + timestamped backup workflow reused from Review (MIT).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class WebDavService {
  WebDavService({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 15);
  }
  final Dio _dio;
  static const maxBackupBytes = 8 * 1024 * 1024;
  static Uri baseUri(String value) {
    var raw = value.trim();
    if (!raw.contains('://')) raw = 'https://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery ||
        !(uri.scheme == 'https' ||
            uri.scheme == 'http' &&
                ['localhost', '127.0.0.1'].contains(uri.host))) {
      throw const FormatException('WebDAV 地址必须使用 HTTPS，或本机回环地址');
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  static bool isSecureUrl(String value) {
    try {
      baseUri(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Uri directoryUri(String server, String directory) {
    final name = directory.trim().isEmpty ? 'GreenMusic' : directory.trim();
    if (name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw const FormatException('备份文件夹名称无效');
    }
    final base = baseUri(server);
    return base.resolve('${Uri.encodeComponent(name)}/');
  }

  Future<Response<List<int>>> _request(
    Uri uri,
    String method,
    String username,
    String password, {
    Uint8List? bytes,
  }) async {
    final cancel = CancelToken();
    return _dio.request<List<int>>(
      uri.toString(),
      data: bytes == null ? null : Stream.value(bytes),
      cancelToken: cancel,
      onReceiveProgress: (count, total) {
        if (count > maxBackupBytes || total > maxBackupBytes) {
          cancel.cancel('backup too large');
        }
      },
      options: Options(
        method: method,
        responseType: ResponseType.bytes,
        followRedirects: false,
        sendTimeout: const Duration(seconds: 25),
        receiveTimeout: const Duration(seconds: 25),
        headers: {
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:$password'))}',
          if (method == 'PROPFIND') 'Depth': '0',
          if (bytes != null) ...{
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': bytes.length,
          },
        },
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );
  }

  Future<bool> testConnection({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    try {
      final r = await _request(
        baseUri(serverUrl),
        'PROPFIND',
        username,
        password,
      );
      return [200, 207].contains(r.statusCode);
    } catch (_) {
      return false;
    }
  }

  Future<bool> uploadBackup({
    required String serverUrl,
    required String username,
    required String password,
    required String directoryName,
    required Map<String, dynamic> data,
  }) async {
    try {
      final directory = directoryUri(serverUrl, directoryName),
          bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      if (bytes.length > maxBackupBytes) return false;
      final created = await _request(directory, 'MKCOL', username, password);
      if (![200, 201, 405].contains(created.statusCode)) return false;
      final latest = await _request(
        directory.resolve('backup_greenmusic_latest.json'),
        'PUT',
        username,
        password,
        bytes: bytes,
      );
      if (![200, 201, 204].contains(latest.statusCode)) return false;
      try {
        await _request(
          directory.resolve(
            'backup_greenmusic_${DateTime.now().millisecondsSinceEpoch}.json',
          ),
          'PUT',
          username,
          password,
          bytes: bytes,
        );
      } catch (_) {
        /* The confirmed latest backup remains usable. */
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> downloadLatestBackup({
    required String serverUrl,
    required String username,
    required String password,
    required String directoryName,
  }) async {
    try {
      final r = await _request(
        directoryUri(
          serverUrl,
          directoryName,
        ).resolve('backup_greenmusic_latest.json'),
        'GET',
        username,
        password,
      );
      if (r.statusCode != 200 ||
          r.data == null ||
          r.data!.length > maxBackupBytes) {
        return null;
      }
      final data = jsonDecode(utf8.decode(r.data!));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }
}
