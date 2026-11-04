import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';

class DownloadStorage {
  DownloadStorage(this.prefs);
  final SharedPreferences prefs;
  static const channel = MethodChannel('com.green.music/files');
  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw MusicError(e.message ?? '系统未能完成文件或通知授权操作');
    }
  }

  String? get tree => prefs.getString('downloadTree');
  String get label => prefs.getString('downloadTreeLabel') ?? '应用专用目录';

  Future<bool> chooseDirectory() async {
    final result = await _call<dynamic>('chooseDirectory');
    if (result == null) return false;
    if (result is! Map ||
        result['uri'] is! String ||
        Uri.tryParse(result['uri'] as String)?.scheme != 'content' ||
        result['label'] is! String) {
      throw const MusicError('系统未返回有效文件夹授权');
    }
    await prefs.setString('downloadTree', result['uri']!);
    await prefs.setString('downloadTreeLabel', result['label']!);
    return true;
  }

  Future<void> resetDirectory() async {
    await prefs.remove('downloadTree');
    await prefs.remove('downloadTreeLabel');
  }

  Future<String> write(
    String tree,
    String name,
    String path,
    String mime,
  ) async => (await _call<String>('writeFile', {
    'tree': tree,
    'name': name,
    'path': path,
    'mime': mime,
  }))!;
  Future<bool> exists(String uri) async =>
      await _call<bool>('exists', {'uri': uri}) ?? false;
  Future<void> delete(String uri) => _call<void>('deleteFile', {'uri': uri});

  Future<bool> notifications({
    bool request = false,
    bool openSettings = true,
  }) async =>
      await _call<bool>(
        request ? 'requestNotifications' : 'notificationsEnabled',
        request ? {'openSettings': openSettings} : null,
      ) ??
      false;
  Future<void> requestNotificationOnce() async {
    if (prefs.getBool('notificationAsked') == true) return;
    try {
      await notifications(request: true, openSettings: false);
      await prefs.setBool('notificationAsked', true);
    } on MusicError {
      /* Settings allows a later retry. */
    }
  }
}
