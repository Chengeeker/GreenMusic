import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' show parseFragment;

import '../core/design_system/components/review_card.dart';
import '../core/utils/app_toast.dart';
import '../data/library_api.dart';
import '../data/models.dart';
import '../data/qq_music_api.dart';
import 'batch_download_page.dart';
import '../providers.dart';
import 'widgets.dart';

class SongCollectionPage extends ConsumerStatefulWidget {
  const SongCollectionPage({
    super.key,
    required this.title,
    this.cover = '',
    this.description = '',
    this.playlist,
    this.album,
    this.artist,
    this.loader,
  });
  SongCollectionPage.playlist(MusicList list, {super.key})
    : title = list.name,
      cover = list.cover,
      description = list.description,
      playlist = list,
      album = null,
      artist = null,
      loader = null;
  SongCollectionPage.album(Album value, {super.key})
    : title = value.name,
      cover = value.cover,
      description = '',
      playlist = null,
      album = value,
      artist = null,
      loader = null;
  final String title, cover, description;
  final MusicList? playlist;
  final Album? album;
  final Artist? artist;
  final Future<SongPage> Function(int)? loader;
  @override
  ConsumerState<SongCollectionPage> createState() => _SongCollectionPageState();
}

Future<SongPage> _collectionPage(
  QqMusicApi api,
  SongCollectionPage config,
  int offset,
) async {
  if (config.loader != null) {
    return await config.loader!(offset);
  } else if (config.playlist != null) {
    return await api.playlistPage(config.playlist!, offset: offset);
  } else if (config.album != null) {
    final list = await api.albumSongs(config.album!);
    return SongPage(list, list.length, false);
  } else if (config.artist != null) {
    final list = await api.artistSongs(config.artist!, offset: offset);
    return SongPage(list, offset + list.length, list.length >= 50);
  } else {
    return const SongPage([], 0, false);
  }
}

class _SongCollectionPageState extends ConsumerState<SongCollectionPage> {
  final _scroll = ScrollController();
  final _songs = <Song>[];
  bool _loading = false, _more = true, _writing = false;
  Object? _error;
  int _offset = 0, _epoch = 0;
  late String _title = widget.title;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
    _load();
  }

  @override
  void dispose() {
    _epoch++;
    _scroll.dispose();
    super.dispose();
  }

  void _nearEnd() {
    if (_scroll.position.extentAfter < 500 && _error == null) _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh || !_more && !refresh) return;
    if (refresh) {
      _epoch++;
      _songs.clear();
      _offset = 0;
      _more = true;
    }
    final epoch = _epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final page = await _collectionPage(api, widget, _offset);
      if (!mounted || epoch != _epoch) return;
      final seen = _songs.map((s) => s.id).toSet();
      final fresh = page.items.where((s) => seen.add(s.id)).toList();
      setState(() {
        _songs.addAll(fresh);
        _more = page.more && page.nextOffset > _offset;
        _offset = page.nextOffset;
        if (page.more && fresh.isEmpty) {
          _more = false;
          _error = const MusicError('服务端分页未前进，请下拉刷新');
        }
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = e);
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _menu() async {
    final p = widget.playlist;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p?.editable == true) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('重命名歌单'),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除歌单'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
            if (p?.saved == true)
              ListTile(
                leading: const Icon(Icons.bookmark_remove_outlined),
                title: const Text('取消收藏歌单'),
                onTap: () => Navigator.pop(ctx, 'unfavorite'),
              ),
            if (widget.album != null)
              ListTile(
                leading: const Icon(Icons.favorite_outline_rounded),
                title: const Text('收藏 / 取消收藏专辑'),
                onTap: () => Navigator.pop(ctx, 'album'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final api = ref.read(apiProvider);
    setState(() => _writing = true);
    try {
      if (action == 'rename') {
        final name = await askName(context, '重命名歌单', initial: _title);
        if (name == null || !mounted) return;
        await api.renamePlaylist(p!.id, name);
        if (mounted) setState(() => _title = name);
      } else if (action == 'delete') {
        if (!await confirm(context, '删除歌单', '删除“$_title”及其歌单记录？此操作无法在应用内撤销。') ||
            !mounted) {
          return;
        }
        await api.deletePlaylist(p!.id);
        if (mounted) Navigator.pop(context);
      } else if (action == 'unfavorite') {
        if (!await confirm(context, '取消收藏', '取消收藏“$_title”？') || !mounted) {
          return;
        }
        await api.unfavoritePlaylist(p!.id);
        if (mounted) Navigator.pop(context);
      } else if (action == 'album') {
        final liked = await api.albumLiked(widget.album!);
        await api.likeAlbum(widget.album!, !liked);
        if (mounted) AppToast.show(context, liked ? '已取消收藏专辑' : '已收藏专辑');
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, e is MusicError ? e.message : '操作未完成，请刷新检查');
      }
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasMenu =
        widget.playlist?.editable == true ||
        widget.playlist?.saved == true ||
        widget.album != null;
    return MusicScaffold(
      title: _title,
      actions: [
        if (hasMenu)
          IconButton(
            tooltip: '歌单操作',
            onPressed: _writing ? null : _menu,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
      ],
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: pagePadding(context).copyWith(bottom: 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Cover(widget.cover, size: 104, radius: 22),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${_songs.length} 首${_more ? ' · 可继续加载' : ''}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          parseFragment(widget.description).text ?? '',
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _songs.isEmpty
                          ? null
                          : () => ref.read(playerProvider).playSongs(_songs),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        final api = ref.read(apiProvider);
                        final config = widget;
                        openPage(
                          context,
                          BatchDownloadPage(
                            title: _title,
                            loader: (offset) =>
                                _collectionPage(api, config, offset),
                          ),
                        );
                      },
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('批量下载'),
                    ),
                  ],
                ),
              ),
            ),
            SliverList.builder(
              itemCount: _songs.length,
              itemBuilder: (context, i) => SongTile(
                _songs[i],
                onPlay: () =>
                    ref.read(playerProvider).playSongs(_songs, start: i),
                list: widget.playlist,
                onChanged: () => _load(refresh: true),
              ),
            ),
            SliverToBoxAdapter(
              child: _error != null
                  ? ErrorPanel(_error!, retry: () => _load())
                  : _loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _songs.isEmpty
                  ? const EmptyPanel('这里还没有歌曲')
                  : _more
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton(
                        onPressed: () => _load(),
                        child: const Text('加载更多'),
                      ),
                    )
                  : const SizedBox(height: 24),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistGrid extends StatelessWidget {
  const PlaylistGrid(this.lists, {super.key});
  final List<MusicList> lists;
  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final count = (constraints.crossAxisExtent / 170).floor().clamp(2, 6);
      final size = (constraints.crossAxisExtent - (count - 1) * 12) / count;
      return SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
          mainAxisExtent:
              size + MediaQuery.textScalerOf(context).scale(16) * 3 + 8,
        ),
        itemCount: lists.length,
        itemBuilder: (context, i) {
          final list = lists[i];
          return ReviewCard(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            onTap: () => openPage(context, SongCollectionPage.playlist(list)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Cover(list.cover, size: size, radius: 18),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    list.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class MusicListsPage extends ConsumerStatefulWidget {
  const MusicListsPage({super.key, required this.title, required this.load});
  final String title;
  final Future<List<MusicList>> Function() load;
  @override
  ConsumerState<MusicListsPage> createState() => _MusicListsPageState();
}

class _MusicListsPageState extends ConsumerState<MusicListsPage> {
  late Future<List<MusicList>> _future = widget.load();
  @override
  Widget build(BuildContext context) => MusicScaffold(
    title: widget.title,
    body: FutureBuilder(
      future: _future,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: ErrorPanel(
              s.error!,
              retry: () => setState(() => _future = widget.load()),
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _future = widget.load());
            await _future;
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: pagePadding(context),
                sliver: s.data!.isEmpty
                    ? const SliverToBoxAdapter(child: EmptyPanel('暂时没有歌单'))
                    : PlaylistGrid(s.data!),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class ArtistPage extends ConsumerWidget {
  const ArtistPage(this.artist, {super.key});
  final Artist artist;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SongCollectionPage(
    title: artist.name,
    cover: artist.cover,
    artist: artist,
  );
}

class AlbumsPage extends ConsumerStatefulWidget {
  const AlbumsPage({super.key, required this.title, required this.load});
  final String title;
  final Future<LibraryPage<Album>> Function(int) load;
  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage> {
  final _items = <Album>[];
  int _offset = 0;
  bool _busy = false, _more = true;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy || !_more) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.load(_offset);
      if (!mounted) return;
      setState(() {
        final seen = _items.map((x) => x.id).toSet();
        final fresh = page.items.where((x) => seen.add(x.id)).toList();
        _items.addAll(fresh);
        _more = page.more && page.nextOffset > _offset && fresh.isNotEmpty;
        _offset = page.nextOffset;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MusicScaffold(
    title: widget.title,
    body: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400 && _error == null) _load();
        return false;
      },
      child: ListView.builder(
        padding: pagePadding(context, horizontal: 8),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return _error != null
                ? ErrorPanel(_error!, retry: _load)
                : _busy
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _items.isEmpty
                ? const EmptyPanel('这里还没有专辑')
                : _more
                ? TextButton(onPressed: _load, child: const Text('加载更多'))
                : const SizedBox(height: 24);
          }
          final album = _items[i];
          return ListTile(
            leading: Cover(album.cover),
            title: Text(album.name),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => openPage(context, SongCollectionPage.album(album)),
          );
        },
      ),
    ),
  );
}

class CommentsPage extends ConsumerStatefulWidget {
  const CommentsPage(this.song, {super.key});
  final Song song;
  @override
  ConsumerState<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends ConsumerState<CommentsPage> {
  final _comments = <Json>[];
  Json? _cursor;
  int _latestTotal = 0, _epoch = 0;
  bool _hot = false, _busy = false, _more = true;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy || !_more) return;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(apiProvider)
          .comments(widget.song, cursor: _cursor, hot: _hot);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final seen = _comments.map((c) => c['CmId']).toSet();
        final fresh = page.items.where((c) => seen.add(c['CmId'])).toList();
        _comments.addAll(fresh);
        _cursor = page.cursor;
        if (!_hot) _latestTotal = page.total;
        _more = !_hot && page.cursor != null && fresh.isNotEmpty;
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = e);
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  void _change(bool hot) {
    if (hot == _hot) return;
    setState(() {
      _epoch++;
      _hot = hot;
      _comments.clear();
      _cursor = null;
      _busy = false;
      _more = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) => MusicScaffold(
    title: '歌曲评论',
    body: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400 && _error == null) _load();
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: pagePadding(context).copyWith(bottom: 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('最新评论 · $_latestTotal'),
                        selected: !_hot,
                        onSelected: (_) => _change(false),
                      ),
                      ChoiceChip(
                        label: const Text('热门评论'),
                        selected: _hot,
                        onSelected: (_) => _change(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _comments.length,
            itemBuilder: (context, i) {
              final c = _comments[i];
              final date = DateTime.fromMillisecondsSinceEpoch(
                integer(c['PubTime']) * 1000,
              );
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Cover(text(c, ['Avatar']), size: 36, radius: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            text(c, ['Nick']),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(parseFragment(text(c, ['Content'])).text ?? ''),
                          const SizedBox(height: 8),
                          Text(
                            '${date.year}-${date.month}-${date.day} · ${integer(c['PraiseNum'])} 赞',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          SliverToBoxAdapter(
            child: _error != null
                ? ErrorPanel(_error!, retry: _load)
                : _busy
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _comments.isEmpty
                ? const EmptyPanel('还没有评论')
                : _more
                ? TextButton(onPressed: _load, child: const Text('加载更多评论'))
                : const SizedBox(height: 32),
          ),
        ],
      ),
    ),
  );
}
