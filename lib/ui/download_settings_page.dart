import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_choice_tile.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../core/design_system/components/review_switch_tile.dart';
import '../core/theme/theme_provider.dart';
import '../player/download_storage.dart';
import '../providers.dart';
import 'widgets.dart';

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});
  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  bool _busy = false;
  Future<void> _change(Future<void> Function() action) async {
    setState(() => _busy = true);
    await runAction(context, action);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(preferencesProvider);
    final storage = DownloadStorage(prefs);
    final quality =
        prefs.getString('downloadQuality') ?? ref.read(playerProvider).quality;
    return ReviewPageScaffold(
      title: '下载设置',
      bodyBuilder: (context, insets) => ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ).add(insets),
        children: [
          const AppSectionHeading('下载音质'),
          AppSectionCard(
            child: Column(
              children: [
                for (final value in ['standard', 'exhigh', 'lossless'])
                  ReviewChoiceTile<String>(
                    title: qualityName(value),
                    value: value,
                    groupValue: quality,
                    summary: value == 'standard' ? null : '需要相应账号权限；不可用时降级',
                    onSelected: () {
                      if (!_busy) {
                        _change(() async {
                          await prefs.setString('downloadQuality', value);
                        });
                      }
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const AppSectionHeading('保存位置'),
          AppSectionCard(
            child: Column(
              children: [
                ReviewPreferenceTile(
                  title: '歌曲保存文件夹',
                  subtitle: storage.label,
                  leading: const Icon(Icons.folder_open_outlined),
                  onTap: _busy
                      ? null
                      : () => _change(() async {
                          await storage.chooseDirectory();
                        }),
                ),
                if (storage.tree != null)
                  ReviewPreferenceTile(
                    title: '恢复应用专用目录',
                    leading: const Icon(Icons.restore_rounded),
                    onTap: _busy ? null : () => _change(storage.resetDirectory),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              storage.tree == null
                  ? '选择文件夹时由系统授予读写权限。应用专用目录中的歌曲会随卸载删除。修改位置只影响新下载，已有歌曲仍可在下载列表中管理。'
                  : '新歌曲及歌词保存到所选文件夹，卸载后仍保留。请保持文件夹授权；修改位置只影响新下载，已有歌曲仍在原位置。',
            ),
          ),
          const AppSectionHeading('歌词'),
          AppSectionCard(
            child: ReviewSwitchTile(
              leading: const Icon(Icons.lyrics_outlined),
              title: '同时下载 LRC 歌词',
              summary: '新下载包含时间标签和可用翻译；没有歌词的歌曲仅保存音频',
              value: prefs.getBool('downloadLyrics') ?? false,
              onChanged: (value) {
                if (!_busy) {
                  _change(() async {
                    await prefs.setBool('downloadLyrics', value);
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
