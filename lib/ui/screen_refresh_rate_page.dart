// Review's grouped display-mode selector, using actual reported modes only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_choice_tile.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/theme/theme_provider.dart';
import 'widgets.dart';

class ScreenRefreshRatePage extends ConsumerStatefulWidget {
  const ScreenRefreshRatePage({super.key});
  @override
  ConsumerState<ScreenRefreshRatePage> createState() =>
      _ScreenRefreshRatePageState();
}

class _ScreenRefreshRatePageState extends ConsumerState<ScreenRefreshRatePage> {
  static const channel = MethodChannel('com.green.music/settings');
  late Future<List<dynamic>?> _modes = channel.invokeMethod<List<dynamic>>(
    'getSupportedDisplayModes',
  );
  @override
  Widget build(BuildContext context) => ReviewPageScaffold(
    title: '屏幕帧率设置',
    bodyBuilder: (context, insets) => FutureBuilder(
      future: _modes,
      builder: (context, snapshot) {
        final modes = (snapshot.data ?? []).whereType<Map>().toList();
        var native = 0;
        for (final m in modes) {
          final width = (m['width'] as num?)?.toInt() ?? 0;
          if (width > native) native = width;
        }
        final options = <({int mode, String title})>[
          (mode: 0, title: '自动 · 跟随系统'),
        ];
        for (var i = 1; i <= 8; i++) {
          final width = i <= 4 ? native : 1080,
              rate = [120, 90, 72, 60][(i - 1) % 4];
          final matches = modes.where(
            (m) =>
                m['width'] == width &&
                ((m['refreshRate'] as num).toDouble() - rate).abs() < .6,
          );
          if (matches.isNotEmpty) {
            options.add((
              mode: i,
              title: '$width×${matches.first['height']} @ $rate Hz',
            ));
          }
        }
        final current = ref.watch(themeProvider).screenRefreshRateMode;
        return ListView(
          padding: EdgeInsets.fromLTRB(16, insets.top + 12, 16, 24),
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('仅列出设备报告支持的显示模式，实际刷新率由系统决定。'),
            ),
            if (snapshot.hasError)
              ErrorPanel(
                PlatformException(code: 'display'),
                retry: () => setState(
                  () => _modes = channel.invokeMethod<List<dynamic>>(
                    'getSupportedDisplayModes',
                  ),
                ),
              ),
            AppSectionCard(
              child: Column(
                children: [
                  for (final o in options)
                    ReviewChoiceTile<int>(
                      title: o.title,
                      value: o.mode,
                      groupValue: current,
                      onSelected: () => runAction(
                        context,
                        () => ref
                            .read(themeProvider.notifier)
                            .setScreenRefreshRateMode(o.mode),
                        success: '已提交显示模式请求',
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
