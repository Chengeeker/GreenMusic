import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../utils/haptic_feedback_util.dart';

final preferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('Preferences not initialized'),
);
final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeState>(
  (ref) => ThemeNotifier(ref.watch(preferencesProvider)),
);

class ThemeState {
  const ThemeState({
    this.themeMode = ThemeMode.system,
    this.useDynamicColor = true,
    this.themeColorIndex = 3,
    this.isPureBlackDark = false,
    this.enableHaptics = true,
    this.useFloatingNavBar = true,
    this.quality = 'standard',
    this.fontWeightAdjustment = 0,
    this.useCustomFontWeight = false,
    this.customFontWeightDelta = 0,
    this.appTextScale = 1,
    this.screenRefreshRateMode = 0,
    this.useLiquidGlass = false,
  });
  final ThemeMode themeMode;
  final bool useDynamicColor, isPureBlackDark, enableHaptics, useFloatingNavBar;
  final int themeColorIndex;
  final int fontWeightAdjustment;
  final String quality;
  final bool useCustomFontWeight, useLiquidGlass;
  final int customFontWeightDelta, screenRefreshRateMode;
  final double appTextScale;
  int get effectiveFontWeightAdjustment =>
      useCustomFontWeight ? customFontWeightDelta : fontWeightAdjustment;
}

class ThemeNotifier extends StateNotifier<ThemeState> {
  ThemeNotifier(this.prefs) : super(const ThemeState()) {
    reload();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFontWeightAdjustmentChanged' &&
          call.arguments is int) {
        _fontWeightAdjustment = call.arguments as int;
        if (mounted) reload();
      }
    });
    _loadFontWeight();
  }
  final SharedPreferences prefs;
  static const _channel = MethodChannel('com.green.music/settings');
  int _fontWeightAdjustment = 0;
  Future<void> _loadFontWeight() async {
    try {
      _fontWeightAdjustment =
          await _channel.invokeMethod<int>('getFontWeightAdjustment') ?? 0;
      if (mounted) reload();
    } on MissingPluginException {
      /* Widget tests and non-Android previews use the default. */
    } on PlatformException {
      /* A system setting failure must not prevent startup. */
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  void reload() {
    state = ThemeState(
      themeMode: ThemeMode.values[(prefs.getInt('themeMode') ?? 0).clamp(0, 2)],
      useDynamicColor: prefs.getBool('dynamicColor') ?? true,
      themeColorIndex: prefs.getInt('colorIndex') ?? 3,
      isPureBlackDark: prefs.getBool('pureBlack') ?? false,
      enableHaptics: prefs.getBool('haptics') ?? true,
      useFloatingNavBar: prefs.getBool('floatingNav') ?? true,
      quality: prefs.getString('quality') ?? 'standard',
      useCustomFontWeight: prefs.getBool('customFontWeight') ?? false,
      customFontWeightDelta: (prefs.getInt('fontWeightDelta') ?? 0).clamp(
        -100,
        300,
      ),
      appTextScale: (prefs.getDouble('appTextScale') ?? 1).clamp(.8, 1.4),
      screenRefreshRateMode: prefs.getInt('screenRefreshRateMode') ?? 0,
      useLiquidGlass: prefs.getBool('liquidGlass') ?? false,
      fontWeightAdjustment: _fontWeightAdjustment,
    );
    HapticFeedbackUtil.isEnabled = state.enableHaptics;
  }

  Future<void> setBool(String key, bool value) async {
    await prefs.setBool(key, value);
    reload();
  }

  Future<void> setInt(String key, int value) async {
    await prefs.setInt(key, value);
    reload();
  }

  Future<void> setQuality(String value) async {
    await prefs.setString('quality', value);
    reload();
  }

  Future<void> setThemeMode(ThemeMode v) => setInt('themeMode', v.index);
  Future<void> setPureBlackDark(bool v) => setBool('pureBlack', v);
  Future<void> setUseDynamicColor(bool v) => setBool('dynamicColor', v);
  Future<void> setThemeColorIndex(int v) => setInt('colorIndex', v);
  Future<void> setUseFloatingNavBar(bool v) => setBool('floatingNav', v);
  Future<void> setUseLiquidGlass(bool v) async {
    if (v) await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    await setBool('liquidGlass', v);
  }

  Future<void> setEnableHaptics(bool v) => setBool('haptics', v);
  Future<void> setUseCustomFontWeight(bool v) => setBool('customFontWeight', v);
  Future<void> setCustomFontWeightDelta(int v) =>
      setInt('fontWeightDelta', v.clamp(-100, 300));
  void previewAppTextScale(double value) {
    state = ThemeState(
      themeMode: state.themeMode,
      useDynamicColor: state.useDynamicColor,
      themeColorIndex: state.themeColorIndex,
      isPureBlackDark: state.isPureBlackDark,
      enableHaptics: state.enableHaptics,
      useFloatingNavBar: state.useFloatingNavBar,
      quality: state.quality,
      fontWeightAdjustment: state.fontWeightAdjustment,
      useCustomFontWeight: state.useCustomFontWeight,
      customFontWeightDelta: state.customFontWeightDelta,
      screenRefreshRateMode: state.screenRefreshRateMode,
      useLiquidGlass: state.useLiquidGlass,
      appTextScale: value.clamp(.8, 1.4),
    );
  }

  Future<void> setAppTextScale(double value) async {
    await prefs.setDouble('appTextScale', value.clamp(.8, 1.4));
    reload();
  }

  Future<void> setScreenRefreshRateMode(int value) async {
    await _channel.invokeMethod('setScreenRefreshRateMode', {'mode': value});
    await setInt('screenRefreshRateMode', value);
  }
}
