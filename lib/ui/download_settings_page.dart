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

String downloadSpeedLabel(int speed) => speed == 0
    ? '不限速'
    : speed < 1024
    ? '$speed KB/s'
    : '${speed / 1024 == speed ~/ 1024 ? speed ~/ 1024 : (speed / 1024).toStringAsFixed(1)} MB/s';

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});
  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  bool _busy = false;
  Future<void> _choose(
    String key,
    String title,
    Map<int, String> choices,
    int current,
  ) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .75,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                for (final entry in choices.entries)
                  ReviewChoiceTile<int>(
                    title: entry.value,
                    value: entry.key,
                    groupValue: current,
                    onSelected: () => Navigator.pop(context, entry.key),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      await _change(() async {
        await ref.read(preferencesProvider).setInt(key, selected);
      });
    }
  }

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
          const AppSectionHeading('下载任务'),
          AppSectionCard(
            child: Column(
              children: [
                ReviewPreferenceTile(
                  title: '同时下载歌曲数',
                  subtitle: '${prefs.getInt('downloadConcurrent') ?? 3} 首',
                  leading: const Icon(Icons.queue_music_rounded),
                  onTap: _busy
                      ? null
                      : () => _choose('downloadConcurrent', '同时下载歌曲数', {
                          for (var i = 1; i <= 5; i++) i: '$i 首',
                        }, prefs.getInt('downloadConcurrent') ?? 3),
                ),
                ReviewPreferenceTile(
                  title: '每首下载连接数',
                  subtitle: '${prefs.getInt('downloadConnections') ?? 1} 个连接',
                  leading: const Icon(Icons.call_split_rounded),
                  onTap: _busy
                      ? null
                      : () => _choose('downloadConnections', '每首下载连接数', {
                          1: '1 个连接',
                          2: '2 个连接',
                          4: '4 个连接',
                        }, prefs.getInt('downloadConnections') ?? 1),
                ),
                ReviewPreferenceTile(
                  title: '下载总限速',
                  subtitle: downloadSpeedLabel(
                    prefs.getInt('downloadSpeedKiB') ?? 0,
                  ),
                  leading: const Icon(Icons.speed_rounded),
                  onTap: _busy
                      ? null
                      : () => _choose('downloadSpeedKiB', '下载总限速', {
                          for (final speed in [
                            0,
                            128,
                            256,
                            512,
                            1024,
                            2048,
                            5120,
                            10240,
                          ])
                            speed: downloadSpeedLabel(speed),
                        }, prefs.getInt('downloadSpeedKiB') ?? 0),
                ),
                ReviewPreferenceTile(
                  title: '网络失败自动重试',
                  subtitle: '${prefs.getInt('downloadRetries') ?? 2} 次',
                  leading: const Icon(Icons.refresh_rounded),
                  onTap: _busy
                      ? null
                      : () => _choose('downloadRetries', '网络失败自动重试', {
                          0: '不自动重试',
                          1: '1 次',
                          2: '2 次',
                          3: '3 次',
                        }, prefs.getInt('downloadRetries') ?? 2),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '设置从下次任务生效。总限速由所有音频连接共享；小文件或不支持可靠分段的音源自动改单连接。更多连接不一定更快。',
            ),
          ),
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
          const SizedBox(height: 24),
          const AppSectionHeading('歌曲信息'),
          AppSectionCard(
            child: ReviewSwitchTile(
              leading: const Icon(Icons.library_music_outlined),
              title: '写入歌曲标签',
              summary: '将封面、标题、艺术家、专辑、发行年份和歌词写入新下载的 MP3 / FLAC；缺失信息留空，不修改已有下载',
              value: prefs.getBool('downloadTags') ?? false,
              onChanged: (value) {
                if (!_busy) {
                  _change(() async {
                    await prefs.setBool('downloadTags', value);
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
