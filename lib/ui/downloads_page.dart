import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../player/audio_cache.dart';
import '../player/music_handler.dart';
import '../providers.dart';
import 'download_settings_page.dart';
import 'widgets.dart';

class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});
  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  late final MusicHandler _handler;
  late Future<List<DownloadedSong>> _entries;
  late String _account;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _handler = ref.read(playerProvider);
    _account = _handler.account;
    _entries = _read();
    _handler.cache.changes.addListener(_reload);
  }

  Future<List<DownloadedSong>> _read() => _handler.cache.entries(
    _account,
    knownSongs: [..._handler.songsFromHistory(), ..._handler.tracks],
  );

  void _reload() {
    if (mounted) {
      setState(() {
        _entries = _read();
      });
    }
  }

  @override
  void dispose() {
    _handler.cache.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _remove(DownloadedSong entry) async {
    if (!await confirm(
          context,
          '删除下载',
          '删除《${entry.song.name}》的${qualityName(entry.quality)}下载文件？',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    await runAction(
      context,
      () => _handler.removeDownload(entry),
      success: '下载已删除',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(authProvider);
    if (_account != _handler.account) {
      _account = _handler.account;
      _entries = _read();
    }
    return MusicScaffold(
      title: '下载歌曲',
      body: FutureBuilder<List<DownloadedSong>>(
        key: ValueKey(_account),
        future: _entries,
        builder: (context, snapshot) {
          final entries = snapshot.data ?? const <DownloadedSong>[];
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _entries;
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: pagePadding(context),
              itemCount: entries.length + 3,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return AppSectionCard(
                    child: Column(
                      children: [
                        ReviewPreferenceTile(
                          title:
                              '${entries.length} 首 · ${downloadSize(entries.fold<int>(0, (sum, e) => sum + e.bytes))}',
                          subtitle: '仅当前账号可见，支持断网播放；文件位置以下载时设置为准。',
                          leading: const Icon(Icons.download_done_rounded),
                          onTap: null,
                        ),
                        const Divider(height: 1, indent: 56),
                        ReviewPreferenceTile(
                          title: '下载设置',
                          subtitle: '下载音质、保存位置与 LRC 歌词',
                          leading: const Icon(Icons.tune_rounded),
                          onTap: () =>
                              openPage(context, const DownloadSettingsPage()),
                        ),
                      ],
                    ),
                  );
                }
                if (index == 1) {
                  return ValueListenableBuilder<SongDownloadProgress?>(
                    valueListenable: _handler.cache.progress,
                    builder: (context, task, _) {
                      if (task == null || task.account != _account) {
                        return const SizedBox(height: 16);
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: AppSectionCard(
                          child: Column(
                            children: [
                              ListTile(
                                title: Text('正在下载：${task.song.name}'),
                                subtitle: Text(
                                  '${downloadSize(task.received)}${task.total > 0 ? ' / ${downloadSize(task.total)}' : ''}',
                                ),
                                trailing: IconButton(
                                  tooltip: '取消下载',
                                  onPressed: () => runAction(
                                    context,
                                    _handler.cancelDownload,
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ),
                              LinearProgressIndicator(
                                value: task.fraction,
                                semanticsLabel: '歌曲下载进度',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                }
                if (index == 2) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return ErrorPanel(snapshot.error!, retry: _reload);
                  }
                  if (entries.isEmpty) {
                    return const EmptyPanel(
                      '还没有下载歌曲，可在歌曲操作菜单或播放页点击下载',
                      icon: Icons.download_outlined,
                    );
                  }
                  return const SizedBox.shrink();
                }
                final entry = entries[index - 3];
                return ListTile(
                  key: ValueKey(entry.file.path),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  leading: Cover(entry.song.cover, size: 44),
                  title: Text(
                    entry.song.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${entry.song.artistNames.isEmpty ? '' : '${entry.song.artistNames}\n'}${qualityName(entry.quality)} · ${downloadSize(entry.bytes)}',
                  ),
                  onTap: _busy
                      ? null
                      : () => runAction(
                          context,
                          () => _handler.playDownloaded(entry),
                        ),
                  trailing: IconButton(
                    tooltip: '删除${entry.song.name}的下载',
                    onPressed: _busy ? null : () => _remove(entry),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
