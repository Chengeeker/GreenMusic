import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_choice_tile.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../core/design_system/components/review_switch_tile.dart';
import '../player/lyrics_settings.dart';
import 'widgets.dart';

class LyricsSettingsPage extends ConsumerStatefulWidget {
  const LyricsSettingsPage({super.key});
  @override
  ConsumerState<LyricsSettingsPage> createState() => _LyricsSettingsPageState();
}

class _LyricsSettingsPageState extends ConsumerState<LyricsSettingsPage> {
  int? _size, _weight;

  Widget _slider(
    String title,
    String key,
    int value,
    int min,
    int max,
    int step,
    ValueChanged<int> preview,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 16,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text('$value', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        Slider(
          key: ValueKey(key),
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: (max - min) ~/ step,
          label: '$value',
          semanticFormatterCallback: (v) => '$title ${v.round()}',
          onChanged: (v) => preview(v.round()),
          onChangeEnd: (v) async {
            await runAction(
              context,
              () => ref
                  .read(lyricsSettingsProvider.notifier)
                  .setInt(key, v.round()),
            );
            if (mounted) {
              setState(() {
                _size = null;
                _weight = null;
              });
            }
          },
        ),
      ],
    ),
  );

  Future<void> _chooseMode(KaraokeMode mode) async {
    final choice = await showModalBottomSheet<KaraokeMode>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '逐字动画兼容策略',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                for (final value in KaraokeMode.values)
                  ReviewChoiceTile<KaraokeMode>(
                    title: value.label,
                    summary: value.description,
                    value: value,
                    groupValue: mode,
                    onSelected: () => Navigator.pop(context, value),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice != null && mounted) {
      await runAction(
        context,
        () => ref
            .read(lyricsSettingsProvider.notifier)
            .setInt('lyricKaraoke', choice.index),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(lyricsSettingsProvider);
    final notifier = ref.read(lyricsSettingsProvider.notifier);
    final size = _size ?? settings.fontSize,
        weight = _weight ?? settings.fontWeight;
    return ReviewPageScaffold(
      title: '歌词界面',
      bodyBuilder: (context, insets) => ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ).add(insets),
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('设置应用于完整歌词页面，迷你歌词保持原有布局。'),
          ),
          const AppSectionHeading('文字与动效'),
          AppSectionCard(
            child: Column(
              children: [
                _slider(
                  '歌词视图字体大小',
                  'lyricFontSize',
                  size,
                  16,
                  40,
                  1,
                  (v) => setState(() => _size = v),
                ),
                ReviewSwitchTile(
                  title: '歌词视图文本居中对齐',
                  value: settings.center,
                  summary: '关闭后左对齐',
                  onChanged: (v) => runAction(
                    context,
                    () => notifier.setBool('lyricCenter', v),
                  ),
                ),
                _slider(
                  '字体粗细',
                  'lyricFontWeight',
                  weight,
                  100,
                  900,
                  100,
                  (v) => setState(() => _weight = v),
                ),
                ReviewSwitchTile(
                  title: '歌词视图模糊',
                  value: settings.blur,
                  summary: '轻微模糊非当前行；高对比度模式下自动关闭',
                  onChanged: (v) => runAction(
                    context,
                    () => notifier.setBool('lyricBlur', v),
                  ),
                ),
                ReviewSwitchTile(
                  title: '交错滚动效果',
                  value: settings.stagger,
                  summary: '自动换行时，各行错开节奏跟随；手动滚动不受影响',
                  onChanged: (v) => runAction(
                    context,
                    () => notifier.setBool('lyricStagger', v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          AppSectionCard(
            child: ReviewPreferenceTile(
              title: '卡拉 OK（逐字）歌词动画兼容策略',
              subtitle: settings.karaoke.label,
              leading: const Icon(Icons.lyrics_outlined),
              onTap: () => _chooseMode(settings.karaoke),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${settings.karaoke.description}。估算动画不代表真实演唱时间；系统减少动态效果时停用逐字与交错动画。',
            ),
          ),
          const AppSectionHeading('文字预览'),
          AppSectionCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  '让每一句歌词\n跟随音乐流动',
                  key: const ValueKey('lyric-settings-preview'),
                  textAlign: settings.center
                      ? TextAlign.center
                      : TextAlign.left,
                  style: TextStyle(
                    fontSize: size.toDouble(),
                    height: 1.35,
                    fontWeight: FontWeight.values[weight ~/ 100 - 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
