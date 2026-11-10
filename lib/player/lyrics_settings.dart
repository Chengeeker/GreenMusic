import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/theme_provider.dart';

enum KaraokeMode {
  off('关闭', '仅高亮当前整行，不播放逐字动画'),
  timed('仅当前行', '仅有真实逐字时间的行播放动画'),
  song('拓展同首歌词', '歌曲含真实逐字时间时，为其余行估算动画'),
  all('拓展全部行', '所有行均可播放动画；缺少逐字时间时按行时长估算');

  const KaraokeMode(this.label, this.description);
  final String label, description;
}

class LyricsSettings {
  const LyricsSettings({
    this.fontSize = 24,
    this.fontWeight = 600,
    this.center = true,
    this.blur = true,
    this.stagger = true,
    this.karaoke = KaraokeMode.all,
  });
  factory LyricsSettings.read(SharedPreferences prefs) => LyricsSettings(
    fontSize: (prefs.getInt('lyricFontSize') ?? 24).clamp(16, 40),
    fontWeight:
        ((prefs.getInt('lyricFontWeight') ?? 600) ~/ 100).clamp(1, 9) * 100,
    center: prefs.getBool('lyricCenter') ?? true,
    blur: prefs.getBool('lyricBlur') ?? true,
    stagger: prefs.getBool('lyricStagger') ?? true,
    karaoke:
        KaraokeMode.values[(prefs.getInt('lyricKaraoke') ?? 3).clamp(0, 3)],
  );
  final int fontSize, fontWeight;
  final bool center, blur, stagger;
  final KaraokeMode karaoke;
}

final lyricsSettingsProvider =
    StateNotifierProvider<LyricsSettingsNotifier, LyricsSettings>(
      (ref) => LyricsSettingsNotifier(ref.watch(preferencesProvider)),
    );

class LyricsSettingsNotifier extends StateNotifier<LyricsSettings> {
  LyricsSettingsNotifier(this.prefs) : super(LyricsSettings.read(prefs));
  final SharedPreferences prefs;
  void reload() => state = LyricsSettings.read(prefs);
  Future<void> setInt(String key, int value) async {
    if (!await prefs.setInt(key, value)) throw StateError('歌词设置保存失败');
    reload();
  }

  Future<void> setBool(String key, bool value) async {
    if (!await prefs.setBool(key, value)) throw StateError('歌词设置保存失败');
    reload();
  }
}
