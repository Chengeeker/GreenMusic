import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/auth_service.dart';
import '../../data/models.dart';
import '../../player/music_handler.dart';
import '../../providers.dart';
import '../theme/theme_provider.dart';

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    ref.watch(preferencesProvider),
    ref.read(authProvider),
    ref.read(playerProvider),
  ),
);

class BackupService {
  BackupService(
    this.prefs,
    this.auth,
    this.handler, {
    FlutterSecureStorage? secure,
  }) : secure = secure ?? const FlutterSecureStorage();
  final SharedPreferences prefs;
  final AuthService auth;
  final MusicHandler handler;
  final FlutterSecureStorage secure;
  static const boolKeys = {
    'dynamicColor',
    'pureBlack',
    'haptics',
    'floatingNav',
    'liquidGlass',
    'customFontWeight',
    'shuffle',
    'downloadLyrics',
  };
  static const intRanges = {
    'themeMode': (0, 2),
    'colorIndex': (0, 7),
    'fontWeightDelta': (-100, 300),
    'screenRefreshRateMode': (0, 8),
    'queueIndex': (-1, 100000),
    'position': (0, 86400000),
    'repeat': (0, 3),
    'cacheLimitMb': (128, 1024),
  };
  static const stringKeys = {
    'quality',
    'downloadQuality',
    'queue',
    'history',
    'webdavUrl',
    'webdavUsername',
    'webdavDirectory',
  };
  static final keys = {
    ...boolKeys,
    ...stringKeys,
    ...intRanges.keys,
    'appTextScale',
  };
  String getWebDavUrl() => prefs.getString('webdavUrl') ?? '';
  String getWebDavUsername() => prefs.getString('webdavUsername') ?? '';
  String getWebDavDirectory() =>
      prefs.getString('webdavDirectory') ?? 'GreenMusic';
  Future<String> getWebDavPassword() async =>
      await secure.read(key: 'webdav_password') ?? '';
  Future<void> setWebDavUrl(String v) async {
    await prefs.setString('webdavUrl', v);
  }

  Future<void> setWebDavUsername(String v) async {
    await prefs.setString('webdavUsername', v);
  }

  Future<void> setWebDavDirectory(String v) async {
    await prefs.setString('webdavDirectory', v);
  }

  Future<void> setWebDavPassword(String v) =>
      secure.write(key: 'webdav_password', value: v);

  Future<Json> exportAllData({bool includeCredentials = false}) async {
    final data = <String, dynamic>{
      'app': 'greenmusic',
      'schema': 1,
      'backup_mode': includeCredentials ? 'full' : 'safe',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'preferences': {
        for (final key in keys)
          if (prefs.containsKey(key)) key: prefs.get(key),
      },
      if (includeCredentials)
        'credentials': {
          'qqmusic': auth.session?.raw,
          'webdavPassword': await getWebDavPassword(),
        },
    };
    validate(data);
    return data;
  }

  static Json validate(Json backup) {
    if (backup['app'] != 'greenmusic' ||
        backup['schema'] != 1 ||
        !['safe', 'full'].contains(backup['backup_mode']) ||
        backup['preferences'] is! Map) {
      throw const MusicError('不是受支持的 GreenMusic 备份');
    }
    // Ignore retired UI preferences so older backups remain usable.
    final values = Map<String, dynamic>.from(obj(backup['preferences']))
      ..remove('appIcon')
      ..remove('saltUi');
    for (final entry in values.entries) {
      final k = entry.key, v = entry.value;
      if (!keys.contains(k)) throw const MusicError('备份包含未知设置，未恢复');
      if (boolKeys.contains(k) && v is! bool ||
          stringKeys.contains(k) && v is! String) {
        throw const MusicError('备份设置类型无效');
      }
      if (intRanges.containsKey(k)) {
        final r = intRanges[k]!;
        if (v is! int || v < r.$1 || v > r.$2) {
          throw const MusicError('备份设置范围无效');
        }
      }
      if (k == 'appTextScale' &&
          (v is! num || !v.isFinite || v < .8 || v > 1.4)) {
        throw const MusicError('备份字体比例无效');
      }
      if ((k == 'quality' || k == 'downloadQuality') &&
          !['standard', 'exhigh', 'lossless'].contains(v)) {
        throw const MusicError('备份选项无效');
      }
      if (k == 'queue' || k == 'history') {
        dynamic list;
        try {
          list = jsonDecode(v as String);
        } catch (_) {
          throw const MusicError('备份播放记录格式无效');
        }
        if (list is! List ||
            list.any((s) => s is! Map || !Song.fromJson(obj(s)).valid)) {
          throw const MusicError('备份歌曲记录无效');
        }
      }
    }
    if (backup['backup_mode'] == 'full') {
      final credentials = obj(backup['credentials']);
      if (!credentials.containsKey('qqmusic') ||
          credentials['webdavPassword'] is! String) {
        throw const MusicError('全量备份凭据不完整');
      }
      final raw = credentials['qqmusic'];
      if (raw != null &&
          (raw is! Map || !MusicSession(obj(raw)).validIdentity)) {
        throw const MusicError('备份中的 QQ 音乐凭据无效');
      }
    } else if (backup.containsKey('credentials')) {
      throw const MusicError('安全备份包含不应有的凭据字段');
    }
    return values;
  }

  Future<void> _apply(Json values) async {
    for (final e in values.entries) {
      final v = e.key == 'appTextScale' && e.value != null
          ? (e.value as num).toDouble()
          : e.value;
      final ok = v == null
          ? await prefs.remove(e.key)
          : v is bool
          ? await prefs.setBool(e.key, v)
          : v is int
          ? await prefs.setInt(e.key, v)
          : v is num
          ? await prefs.setDouble(e.key, v.toDouble())
          : await prefs.setString(e.key, v as String);
      if (!ok) throw const MusicError('设置写入失败');
    }
  }

  Future<void> restoreAllData(Json backup) async {
    final values = validate(backup),
        previous = {
          for (final key in validate(backup).keys) key: prefs.get(key),
        };
    final full = backup['backup_mode'] == 'full',
        oldSession = auth.session,
        oldPassword = await getWebDavPassword();
    await handler.stop();
    try {
      await _apply(values);
      if (full) {
        final c = obj(backup['credentials']);
        await auth.replaceFromBackup(
          c['qqmusic'] == null ? null : MusicSession(obj(c['qqmusic'])),
        );
        await setWebDavPassword(c['webdavPassword'] as String);
        await handler.cancelDownload();
      } else if (previous.containsKey('webdavUrl') &&
              previous['webdavUrl'] != getWebDavUrl() ||
          previous.containsKey('webdavUsername') &&
              previous['webdavUsername'] != getWebDavUsername()) {
        await setWebDavPassword('');
      }
      handler.reloadSavedState();
    } catch (_) {
      await _apply(previous);
      if (full) {
        await auth.replaceFromBackup(oldSession);
      }
      await setWebDavPassword(oldPassword);
      handler.reloadSavedState();
      rethrow;
    }
  }
}
