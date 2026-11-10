import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../data/models.dart';
import '../player/download_queue.dart';
import '../providers.dart';
import 'download_settings_page.dart';
import 'downloads_page.dart';
import 'storage_settings_page.dart';
import 'widgets.dart';

class BatchDownloadPage extends ConsumerStatefulWidget {
  const BatchDownloadPage({
    super.key,
    required this.title,
    required this.loader,
  });
  final String title;
  final Future<SongPage> Function(int) loader;
  @override
  ConsumerState<BatchDownloadPage> createState() => _BatchDownloadPageState();
}

class _BatchDownloadPageState extends ConsumerState<BatchDownloadPage> {
  late Future<List<Song>> _songs;
  final _selected = <int>{};
  late final String _owner;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _owner = ref.read(playerProvider).account;
    _songs = _load();
  }

  Future<List<Song>> _load() async {
    final epoch = ++_epoch;
    final handler = ref.read(playerProvider);
    final songs = await loadDownloadSongs(
      widget.loader,
      active: () => mounted && epoch == _epoch && _owner == handler.account,
    );
    _selected
      ..clear()
      ..addAll(songs.map((s) => s.id));
    return songs;
  }

  void _start(List<Song> songs) {
    final handler = ref.read(playerProvider);
    unawaited(
      runAction(context, () async {
        if (_owner != handler.account) throw const MusicError('账号已切换，请重新打开歌单');
        final work = handler.downloadSongs(
          widget.title,
          songs.where((s) => _selected.contains(s.id)).toList(),
        );
        if (handler.downloadQueue.busy) {
          openPage(context, const DownloadsPage());
        }
        await work;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final handler = ref.read(playerProvider);
    final prefs = handler.prefs;
    return MusicScaffold(
      title: '批量下载',
      body: FutureBuilder<List<Song>>(
        future: _songs,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在读取完整歌单…'),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return ErrorPanel(
              snapshot.error!,
              retry: () {
                setState(() {
                  _songs = _load();
                });
              },
            );
          }
          final songs = snapshot.data!;
          if (songs.isEmpty) return const EmptyPanel('歌单里没有可下载的歌曲');
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: pagePadding(context),
                  itemCount: songs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          AppSectionCard(
                            child: ReviewPreferenceTile(
                              title: '下载设置',
                              subtitle:
                                  '${qualityName(prefs.getString('downloadQuality') ?? handler.quality)} · ${prefs.getBool('downloadTags') == true ? '写入标签' : '不写入标签'} · ${prefs.getBool('downloadLyrics') == true ? '保存 LRC' : '不保存 LRC'}',
                              leading: const Icon(Icons.tune_rounded),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const DownloadSettingsPage(),
                                  ),
                                );
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                          ReviewPreferenceTile(
                            title: prefs.getString('downloadTree') == null
                                ? '私有存储空间上限'
                                : '公有目录 · 不限下载容量',
                            subtitle: prefs.getString('downloadTree') == null
                                ? '${prefs.getInt('cacheLimitMb') ?? 256} MB · 空间不足时停止，不删除已下载歌曲'
                                : '仅受设备和所选文件夹的实际可用空间限制',
                            leading: const Icon(Icons.storage_outlined),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const StorageSettingsPage(),
                                ),
                              );
                              if (mounted) setState(() {});
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '同时下载 ${prefs.getInt('downloadConcurrent') ?? 3} 首，每首最多 ${prefs.getInt('downloadConnections') ?? 1} 个连接，${downloadSpeedLabel(prefs.getInt('downloadSpeedKiB') ?? 0)}。自动跳过已有文件，失败项可重试。离开页面后继续下载。应用被系统关闭后，可重新发起，已完成歌曲会保留。',
                            ),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '全选 · 已选 ${_selected.length} / ${songs.length} 首',
                            ),
                            tristate: true,
                            value: _selected.length == songs.length
                                ? true
                                : _selected.isEmpty
                                ? false
                                : null,
                            onChanged: (_) => setState(() {
                              if (_selected.length == songs.length) {
                                _selected.clear();
                              } else {
                                _selected.addAll(songs.map((s) => s.id));
                              }
                            }),
                          ),
                        ],
                      );
                    }
                    final song = songs[index - 1];
                    return CheckboxListTile(
                      key: ValueKey('select-download-${song.id}'),
                      title: Text(song.name),
                      subtitle: Text(song.artistNames),
                      value: _selected.contains(song.id),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(song.id);
                        } else {
                          _selected.remove(song.id);
                        }
                      }),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ListenableBuilder(
                    listenable: handler.downloadQueue,
                    builder: (context, _) => FilledButton.icon(
                      onPressed: _selected.isEmpty || handler.downloadQueue.busy
                          ? null
                          : () => _start(songs),
                      icon: const Icon(Icons.download_rounded),
                      label: Text(
                        handler.downloadQueue.busy
                            ? '已有下载任务进行中'
                            : '下载所选 ${_selected.length} 首',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
