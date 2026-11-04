import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_choice_tile.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/theme/theme_provider.dart';
import '../providers.dart';
import 'widgets.dart';
import 'downloads_page.dart';

class PlaybackSettingsPage extends ConsumerWidget {
  const PlaybackSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ReviewPageScaffold(
    title: '播放设置',
    bodyBuilder: (context, insets) => ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ).add(insets),
      children: [
        AppSectionCard(
          child: Column(
            children: [
              for (final quality in ['standard', 'exhigh', 'lossless'])
                ReviewChoiceTile<String>(
                  title: qualityName(quality),
                  value: quality,
                  groupValue: ref.watch(themeProvider).quality,
                  summary: quality == 'standard'
                      ? '匿名可用音源优先'
                      : '需要账号及相应权限；不可用时降级',
                  onSelected: () =>
                      ref.read(themeProvider.notifier).setQuality(quality),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class StorageSettingsPage extends ConsumerStatefulWidget {
  const StorageSettingsPage({super.key});
  @override
  ConsumerState<StorageSettingsPage> createState() =>
      _StorageSettingsPageState();
}

class _StorageSettingsPageState extends ConsumerState<StorageSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(preferencesProvider),
        handler = ref.read(playerProvider),
        limit = prefs.getInt('cacheLimitMb') ?? 256;
    return ReviewPageScaffold(
      title: '存储设置',
      bodyBuilder: (context, insets) => ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ).add(insets),
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('空间上限按所有账号与保存位置合计。下载音质、保存位置和歌词可在“下载设置”中调整。'),
          ),
          const AppSectionHeading('下载空间上限'),
          AppSectionCard(
            child: Column(
              children: [
                for (final value in [128, 256, 512, 1024])
                  ReviewChoiceTile<int>(
                    title: '$value MB',
                    value: value,
                    groupValue: limit,
                    onSelected: () => runAction(context, () async {
                      await prefs.setInt('cacheLimitMb', value);
                      handler.cache.maxBytes = value * 1024 * 1024;
                      if (mounted) setState(() {});
                    }),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('空间不足时暂停新增下载，不会自动删除已下载歌曲。降低上限后，已有歌曲仍保留。'),
          ),
        ],
      ),
    );
  }
}

class CacheManagementPage extends ConsumerStatefulWidget {
  const CacheManagementPage({super.key});
  @override
  ConsumerState<CacheManagementPage> createState() =>
      _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  late Future<int> _size = ref.read(playerProvider).cache.size();
  @override
  Widget build(BuildContext context) => ReviewPageScaffold(
    title: '缓存管理',
    bodyBuilder: (context, insets) => ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ).add(insets),
      children: [
        AppSectionCard(
          child: FutureBuilder(
            future: _size,
            builder: (context, s) => ReviewPreferenceTile(
              title: '下载歌曲',
              subtitle: s.hasError
                  ? '暂时无法统计'
                  : s.hasData
                  ? '${(s.data! / 1024 / 1024).toStringAsFixed(1)} MB'
                  : '正在统计…',
              leading: const Icon(Icons.music_note_outlined),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DownloadsPage(),
                  ),
                );
                if (mounted) {
                  setState(() {
                    _size = ref.read(playerProvider).cache.size();
                  });
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        AppSectionCard(
          child: ReviewPreferenceTile(
            title: '封面内存缓存',
            subtitle:
                '${(PaintingBinding.instance.imageCache.currentSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
            leading: const Icon(Icons.image_outlined),
            onTap: () {
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();
              setState(() {});
            },
          ),
        ),
      ],
    ),
  );
}
