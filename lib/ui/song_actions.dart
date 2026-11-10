import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_api.dart';
import '../data/models.dart';
import '../data/qq_music_api.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../providers.dart';
import 'collection_pages.dart';
import 'widgets.dart';

Future<void> downloadSongWithChoice(
  BuildContext context,
  WidgetRef ref,
  Song song,
) async {
  final handler = ref.read(playerProvider);
  if (handler.downloadQueue.busy || handler.cache.progress.value != null) {
    await runAction(context, () async {
      throw const MusicError('已有歌曲正在下载，请稍候');
    });
    return;
  }
  final api = ref.read(apiProvider);
  final preferred =
      handler.prefs.getString('downloadQuality') ?? handler.quality;
  final selected = await showModalBottomSheet<({Song song, String quality})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _DownloadQualitySheet(song: song, api: api, preferred: preferred),
  );
  if (selected == null || !context.mounted) return;
  await runAction(
    context,
    () => handler.downloadSong(selected.song, quality: selected.quality),
    success: '已下载，可在“我的 → 下载歌曲”中播放和管理',
  );
}

class _DownloadQualitySheet extends StatefulWidget {
  const _DownloadQualitySheet({
    required this.song,
    required this.api,
    required this.preferred,
  });
  final Song song;
  final QqMusicApi api;
  final String preferred;
  @override
  State<_DownloadQualitySheet> createState() => _DownloadQualitySheetState();
}

class _DownloadQualitySheetState extends State<_DownloadQualitySheet> {
  late final Future<Song> _details =
      [
        'standard',
        'exhigh',
        'lossless',
      ].every((quality) => widget.song.downloadBytes(quality) > 0)
      ? Future.value(widget.song)
      : widget.api.songDetail(widget.song);

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: FutureBuilder<Song>(
          future: _details,
          builder: (context, snapshot) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  '下载音质',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final quality in ['standard', 'exhigh', 'lossless'])
                Builder(
                  builder: (context) {
                    final size = snapshot.data?.downloadBytes(quality) ?? 0;
                    final bytes = size > 0
                        ? size
                        : widget.song.downloadBytes(quality);
                    return ReviewPreferenceTile(
                      title: qualityName(quality),
                      subtitle: quality == widget.preferred ? '默认下载音质' : null,
                      leading: Icon(
                        quality == widget.preferred
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      trailing: Text(
                        bytes > 0
                            ? downloadSize(bytes)
                            : snapshot.connectionState ==
                                  ConnectionState.waiting
                            ? '读取中…'
                            : '大小未知',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onTap: () {
                        final detail = snapshot.data;
                        final resolved = detail == null
                            ? widget.song
                            : Song.fromJson({
                                ...widget.song.raw,
                                if (detail.mid.isNotEmpty) 'mid': detail.mid,
                                'file': {
                                  ...obj(widget.song.raw['file']),
                                  ...obj(detail.raw['file']),
                                  if (detail.mediaMid.isNotEmpty)
                                    'media_mid': detail.mediaMid,
                                },
                              });
                        Navigator.pop(context, (
                          song: resolved,
                          quality: quality,
                        ));
                      },
                    );
                  },
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('本次选择不会更改默认设置。大小对应所选版本，不可用时会使用可下载的音质。'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showSongActions(
  BuildContext context,
  WidgetRef ref,
  Song song, {
  MusicList? list,
  VoidCallback? onChanged,
  Future<void> Function()? onChooseQuality,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Cover(song.cover),
              title: Text(song.name),
              subtitle: Text(song.artistNames),
            ),
            if (onChooseQuality != null)
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('播放音质'),
                onTap: () => Navigator.pop(ctx, 'quality'),
              ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('加入播放队列'),
              onTap: () => Navigator.pop(ctx, 'queue'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载歌曲'),
              onTap: () => Navigator.pop(ctx, 'download'),
            ),
            ListTile(
              leading: const Icon(Icons.favorite_outline_rounded),
              title: const Text('喜欢 / 取消喜欢'),
              onTap: () => Navigator.pop(ctx, 'like'),
            ),
            ListTile(
              leading: const Icon(Icons.library_add_outlined),
              title: const Text('添加到歌单'),
              onTap: () => Navigator.pop(ctx, 'playlist'),
            ),
            if (song.album.mid.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: const Text('查看专辑'),
                onTap: () => Navigator.pop(ctx, 'album'),
              ),
            if (song.artists.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('查看歌手'),
                onTap: () => Navigator.pop(ctx, 'artist'),
              ),
            if (list?.editable == true)
              ListTile(
                leading: const Icon(Icons.playlist_remove_rounded),
                title: const Text('从歌单移除'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'quality') {
    await onChooseQuality?.call();
    return;
  }
  final api = ref.read(apiProvider), handler = ref.read(playerProvider);
  switch (action) {
    case 'download':
      await downloadSongWithChoice(context, ref, song);
    case 'queue':
      await runAction(context, () => handler.addSong(song), success: '已加入播放队列');
    case 'like':
      await runAction(context, () async {
        final liked = await api.songLiked(song);
        await api.likeSong(song, !liked);
      }, success: '喜欢状态已更新');
    case 'playlist':
      await runAction(context, () async {
        final lists = (await api.ownedLists())
            .where((p) => p.editable)
            .toList();
        if (!context.mounted) return;
        final target = await showModalBottomSheet<MusicList>(
          context: context,
          builder: (ctx) => SafeArea(
            child: lists.isEmpty
                ? const EmptyPanel('请先在“我的”中创建歌单')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: lists.length,
                    itemBuilder: (ctx, i) => ListTile(
                      leading: Cover(lists[i].cover),
                      title: Text(lists[i].name),
                      onTap: () => Navigator.pop(ctx, lists[i]),
                    ),
                  ),
          ),
        );
        if (target != null) await api.editPlaylistSongs(target.id, [song.id]);
      });
    case 'album':
      openPage(context, SongCollectionPage.album(song.album));
    case 'artist':
      Artist? artist = song.artists.first;
      if (song.artists.length > 1) {
        artist = await showModalBottomSheet<Artist>(
          context: context,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in song.artists)
                  ListTile(
                    title: Text(a.name),
                    onTap: () => Navigator.pop(ctx, a),
                  ),
              ],
            ),
          ),
        );
      }
      if (context.mounted && artist != null) {
        openPage(context, ArtistPage(artist));
      }
    case 'remove':
      if (await confirm(context, '从歌单移除', '将《${song.name}》从此歌单移除？') &&
          context.mounted) {
        await runAction(context, () async {
          await api.editPlaylistSongs(list!.id, [song.id], add: false);
          onChanged?.call();
        }, success: '已从歌单移除');
      }
  }
}

Future<void> showQueue(BuildContext context, WidgetRef ref) async {
  final handler = ref.read(playerProvider);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: ValueListenableBuilder(
          valueListenable: handler.changes,
          builder: (ctx, _, child) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '播放队列 · ${handler.tracks.length}',
                        style: Theme.of(ctx).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '停止播放',
                      onPressed: () => runAction(ctx, handler.stop),
                      icon: const Icon(Icons.stop_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: handler.tracks.isEmpty
                    ? const EmptyPanel('队列里还没有歌曲')
                    : ListView.builder(
                        itemCount: handler.tracks.length,
                        itemBuilder: (ctx, i) {
                          final song = handler.tracks[i];
                          return ListTile(
                            selected: i == handler.index,
                            leading: Cover(song.cover),
                            title: Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.artistNames,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => runAction(
                              ctx,
                              () => handler.skipToQueueItem(i),
                            ),
                            trailing: IconButton(
                              tooltip: '移出队列',
                              onPressed: () =>
                                  runAction(ctx, () => handler.removeSong(i)),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
