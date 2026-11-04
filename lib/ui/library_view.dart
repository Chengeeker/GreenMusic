import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../data/library_api.dart';
import '../data/models.dart';
import '../providers.dart';
import 'collection_pages.dart';
import 'downloads_page.dart';
import 'login_page.dart';
import 'settings_page.dart';
import 'widgets.dart';

class LibraryView extends ConsumerStatefulWidget {
  const LibraryView({super.key});
  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView> {
  List<MusicList> _lists = [];
  bool _saved = false, _busy = false, _more = false, _creating = false;
  String? _account;
  Object? _error;
  int _offset = 0, _epoch = 0;
  Future<void> _load({bool refresh = false}) async {
    if (_account == null || _busy && !refresh) return;
    if (refresh) {
      _epoch++;
      _offset = 0;
      _more = true;
    }
    final epoch = _epoch, offset = _offset;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final page = _saved
          ? await api.savedLists(offset)
          : LibraryPage(await api.ownedLists(), false, 0);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        if (refresh) _lists = [];
        final seen = _lists.map((p) => p.id).toSet();
        final fresh = page.items.where((p) => seen.add(p.id)).toList();
        _lists.addAll(fresh);
        _more = page.more && page.nextOffset > offset && fresh.isNotEmpty;
        _offset = page.nextOffset;
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = e);
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await askName(context, '创建歌单');
    if (name == null || !mounted) return;
    setState(() => _creating = true);
    await runAction(context, () async {
      await ref.read(apiProvider).createPlaylist(name);
      _saved = false;
      await _load(refresh: true);
    }, success: '已创建歌单');
    if (mounted) setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider), session = auth.session;
    if (session?.id != _account) {
      _account = session?.id;
      _epoch++;
      _lists = [];
      _offset = 0;
      _error = null;
      _busy = false;
      if (session != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load(refresh: true);
        });
      }
    }
    final api = ref.read(apiProvider), handler = ref.read(playerProvider);
    void history() {
      openPage(
        context,
        SongCollectionPage(
          title: '最近播放',
          loader: (offset) async {
            final list = handler.songsFromHistory();
            return SongPage(list, list.length, false);
          },
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: CustomScrollView(
        primary: false,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: pagePadding(context).copyWith(bottom: 24),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSectionCard(
                    key: const ValueKey('library-account'),
                    child: ReviewPreferenceTile(
                      title: session?.nickname ?? '登录 QQ 音乐',
                      subtitle: session == null
                          ? '同步歌单与收藏'
                          : '${session.loginType == 1 ? '微信' : 'QQ'}账号 · ${session.id}',
                      leading: session?.avatar.isNotEmpty == true
                          ? Cover(session!.avatar, size: 48, radius: 24)
                          : const Icon(Icons.account_circle_outlined, size: 40),
                      onTap: session == null
                          ? () => openPage(context, const LoginPage())
                          : () => runAction(
                              context,
                              auth.ensureSession,
                              success: '账号状态已更新',
                            ),
                    ),
                  ),
                  if (auth.restoreError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        auth.restoreError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  AppSectionCard(
                    child: Column(
                      children: [
                        ReviewPreferenceTile(
                          title: '下载歌曲',
                          leading: const Icon(Icons.download_outlined),
                          onTap: () => openPage(context, const DownloadsPage()),
                        ),
                        const Divider(height: 1, indent: 56),
                        ReviewPreferenceTile(
                          title: '最近播放',
                          leading: const Icon(Icons.history_rounded),
                          onTap: history,
                        ),
                        if (session != null) ...[
                          const Divider(height: 1, indent: 56),
                          ReviewPreferenceTile(
                            title: '收藏专辑',
                            leading: const Icon(Icons.album_outlined),
                            onTap: () => openPage(
                              context,
                              AlbumsPage(title: '收藏专辑', load: api.likedAlbums),
                            ),
                          ),
                          const Divider(height: 1, indent: 56),
                          ReviewPreferenceTile(
                            title: '已购单曲',
                            leading: const Icon(Icons.music_note_outlined),
                            onTap: () => openPage(
                              context,
                              SongCollectionPage(
                                title: '已购单曲',
                                loader: (offset) async {
                                  final p = await api.purchasedPage(
                                    false,
                                    offset,
                                  );
                                  return SongPage(
                                    songs(p.items),
                                    p.nextOffset,
                                    p.more,
                                  );
                                },
                              ),
                            ),
                          ),
                          const Divider(height: 1, indent: 56),
                          ReviewPreferenceTile(
                            title: '已购数字专辑',
                            leading: const Icon(Icons.shopping_bag_outlined),
                            onTap: () => openPage(
                              context,
                              AlbumsPage(
                                title: '已购数字专辑',
                                load: (offset) async {
                                  final p = await api.purchasedPage(
                                    true,
                                    offset,
                                  );
                                  return LibraryPage(
                                    p.items.map(Album.fromJson).toList(),
                                    p.more,
                                    p.nextOffset,
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                        const Divider(height: 1, indent: 56),
                        ReviewPreferenceTile(
                          key: const ValueKey('library-settings'),
                          title: '设置',
                          leading: const Icon(Icons.settings_outlined),
                          onTap: () => openPage(context, const SettingsPage()),
                        ),
                      ],
                    ),
                  ),
                  if (session != null) ...[
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('自建歌单'),
                                selected: !_saved,
                                onSelected: (_) {
                                  setState(() => _saved = false);
                                  _load(refresh: true);
                                },
                              ),
                              ChoiceChip(
                                label: const Text('收藏歌单'),
                                selected: _saved,
                                onSelected: (_) {
                                  setState(() => _saved = true);
                                  _load(refresh: true);
                                },
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '创建歌单',
                          onPressed: _creating ? null : _create,
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _lists.length,
            itemBuilder: (context, i) {
              final list = _lists[i];
              return ListTile(
                leading: Cover(list.cover),
                title: Text(list.name),
                subtitle: Text(
                  '${list.count} 首${list.dirId == 201 ? ' · 我喜欢的音乐' : ''}',
                ),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SongCollectionPage.playlist(list),
                    ),
                  );
                  if (mounted) _load(refresh: true);
                },
              );
            },
          ),
          if (session != null)
            SliverToBoxAdapter(
              child: _error != null
                  ? ErrorPanel(
                      _error!,
                      retry: () => _load(refresh: _lists.isEmpty),
                    )
                  : _busy
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _lists.isEmpty
                  ? const EmptyPanel('这里还没有歌单')
                  : _more
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextButton(
                        onPressed: _load,
                        child: const Text('加载更多歌单'),
                      ),
                    )
                  : const SizedBox(height: 32),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
          ),
        ],
      ),
    );
  }
}
