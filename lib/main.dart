import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_provider.dart';
import 'core/theme/app_text_scaler.dart';
import 'core/utils/app_toast.dart';
import 'data/auth_service.dart';
import 'data/qq_music_api.dart';
import 'player/audio_cache.dart';
import 'player/download_storage.dart';
import 'player/music_handler.dart';
import 'providers.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('liquidGlass') == true &&
        prefs.getBool('floatingNav') != false) {
      await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    }
    final api = QqMusicApi();
    final actualAuth = AuthService(api);
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'Lilt / GreenMusic',
      ], await rootBundle.loadString('LICENSE'));
      yield LicenseEntryWithLineBreaks([
        'Review UI',
      ], await rootBundle.loadString('docs/REVIEW_LICENSE'));
      yield LicenseEntryWithLineBreaks([
        'Google Material Icons',
      ], await rootBundle.loadString('docs/MATERIAL_ICONS_LICENSE'));
    });
    final temp = await getTemporaryDirectory();
    final support = await getApplicationSupportDirectory();
    final downloads = AudioCache(
      Directory('${support.path}/music_downloads'),
      legacyDirectory: Directory('${temp.path}/music_cache'),
      maxBytes: (prefs.getInt('cacheLimitMb') ?? 256) * 1024 * 1024,
      storage: DownloadStorage(prefs),
    );
    try {
      await downloads.cleanupInterrupted();
    } on FileSystemException {
      /* Download cleanup must not prevent online playback. */
    }
    final handler = await AudioService.init<MusicHandler>(
      builder: () => MusicHandler(api, actualAuth, prefs, downloads),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.green.music.playback',
        androidNotificationChannelName: '音乐播放',
        androidNotificationIcon: 'drawable/ic_stat_music',
        artDownscaleWidth: 1024,
        artDownscaleHeight: 1024,
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
    await handler.configure();
    runApp(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          apiProvider.overrideWithValue(api),
          authProvider.overrideWith((ref) => actualAuth),
          playerProvider.overrideWithValue(handler),
        ],
        child: const GreenMusicApp(),
      ),
    );
    unawaited(actualAuth.restore());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(DownloadStorage(prefs).requestNotificationOnce());
    });
  } catch (_) {
    runApp(
      MaterialApp(
        theme: AppTheme.lightTheme(colorIndex: 3),
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      '音乐服务启动失败，请关闭应用后重新打开。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: SystemNavigator.pop,
                      child: const Text('关闭应用'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GreenMusicApp extends ConsumerWidget {
  const GreenMusicApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(themeProvider);
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'GreenMusic',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        theme: AppTheme.lightTheme(
          colorIndex: state.themeColorIndex,
          fontWeightAdjustment: state.effectiveFontWeightAdjustment,
          dynamicColorScheme: state.useDynamicColor ? light : null,
        ),
        darkTheme: AppTheme.darkTheme(
          colorIndex: state.themeColorIndex,
          fontWeightAdjustment: state.effectiveFontWeightAdjustment,
          dynamicColorScheme: state.useDynamicColor ? dark : null,
          isPureBlack: state.isPureBlackDark,
        ),
        themeMode: state.themeMode,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: Theme.of(context).brightness == Brightness.dark
              ? SystemUiOverlayStyle.light.copyWith(
                  statusBarColor: Colors.transparent,
                  systemNavigationBarColor: Colors.transparent,
                  systemNavigationBarContrastEnforced: false,
                )
              : SystemUiOverlayStyle.dark.copyWith(
                  statusBarColor: Colors.transparent,
                  systemNavigationBarColor: Colors.transparent,
                  systemNavigationBarContrastEnforced: false,
                ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: AppTextScaler(
                MediaQuery.textScalerOf(context),
                state.appTextScale,
              ),
            ),
            child: DefaultTextStyle(
              style:
                  Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
              child: child!,
            ),
          ),
        ),
        home: const HomePage(),
      ),
    );
  }
}
