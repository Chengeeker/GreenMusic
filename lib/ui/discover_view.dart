import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/review_card.dart';
import '../data/library_api.dart';
import '../data/models.dart';
import '../providers.dart';
import 'collection_pages.dart';
import 'login_page.dart';
import 'widgets.dart';

class DiscoverView extends ConsumerStatefulWidget {
  const DiscoverView({super.key});
  @override
  ConsumerState<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends ConsumerState<DiscoverView> {
  late Future<List<MusicList>> _featured = ref.read(apiProvider).featured();
  Future<List<MusicList>>? _personal;
  Future<List<({String title, List<Song> tracks})>>? _shelves;
  String? _account;
  void _setAccount(String? account) {
    if (account == _account) return;
    _account = account;
    _personal = account == null ? null : ref.read(apiProvider).recommended();
    _shelves = account == null ? null : ref.read(apiProvider).songShelves();
  }

  Future<void> _refresh() async {
    setState(() {
      _featured = ref.read(apiProvider).featured();
      if (_account != null) {
        _personal = ref.read(apiProvider).recommended();
        _shelves = ref.read(apiProvider).songShelves();
      }
    });
    try {
      await _featured;
    } catch (_) {
      /* FutureBuilder renders the error and retry. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    _setAccount(auth.session?.id);
    final api = ref.read(apiProvider), scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _refresh,
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
                  Text(
                    '今天，听点什么',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    auth.session == null
                        ? '发现喜欢的旋律'
                        : '${auth.session!.nickname}，欢迎回来',
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = (constraints.maxWidth - 24) / 3;
                      Widget tile(
                        String title,
                        IconData icon,
                        VoidCallback onTap,
                      ) => SizedBox(
                        width: width,
                        child: ReviewCard(
                          margin: EdgeInsets.zero,
                          elevation: 0,
                          color: scheme.secondaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          onTap: onTap,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  icon,
                                  color: scheme.onSecondaryContainer,
                                  size: 24,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(
                                        color: scheme.onSecondaryContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                      void accountSongs(
                        String title,
                        Future<List<Song>> Function() load,
                      ) {
                        if (auth.session == null) {
                          openPage(context, const LoginPage());
                          return;
                        }
                        openPage(
                          context,
                          SongCollectionPage(
                            title: title,
                            loader: (offset) async {
                              final list = await load();
                              return SongPage(list, list.length, false);
                            },
                          ),
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          tile(
                            '每日推荐',
                            Icons.today_rounded,
                            () => accountSongs('每日推荐', api.daily),
                          ),
                          const SizedBox(width: 12),
                          tile(
                            '个性电台',
                            Icons.radio_rounded,
                            () => accountSongs('个性电台', api.radio),
                          ),
                          const SizedBox(width: 12),
                          tile(
                            '排行榜',
                            Icons.bar_chart_rounded,
                            () => openPage(
                              context,
                              MusicListsPage(title: '排行榜', load: api.charts),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (auth.session == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: TextButton.icon(
                        onPressed: () => openPage(context, const LoginPage()),
                        icon: const Icon(Icons.person_outline_rounded),
                        label: const Text('登录，找回你的音乐'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_shelves != null)
            FutureBuilder(
              future: _shelves,
              builder: (context, s) {
                if (s.hasError) {
                  return SliverToBoxAdapter(
                    child: ErrorPanel(
                      s.error!,
                      retry: () => setState(() => _shelves = api.songShelves()),
                    ),
                  );
                }
                if (!s.hasData) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                return SliverMainAxisGroup(
                  slivers: [
                    for (final shelf in s.data!) ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
                        sliver: SliverToBoxAdapter(
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  shelf.title,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                tooltip: '播放${shelf.title}',
                                onPressed: () => ref
                                    .read(playerProvider)
                                    .playSongs(shelf.tracks),
                                icon: const Icon(
                                  Icons.play_circle_outline_rounded,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverList.builder(
                        itemCount: shelf.tracks.length.clamp(0, 5),
                        itemBuilder: (context, i) => SongTile(
                          shelf.tracks[i],
                          onPlay: () => ref
                              .read(playerProvider)
                              .playSongs(shelf.tracks, start: i),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => openPage(
                              context,
                              SongCollectionPage(
                                title: shelf.title,
                                loader: (offset) async => SongPage(
                                  shelf.tracks,
                                  shelf.tracks.length,
                                  false,
                                ),
                              ),
                            ),
                            child: const Text('查看全部'),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          if (_personal != null) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
              sliver: SliverToBoxAdapter(
                child: Text(
                  '为你推荐',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            FutureBuilder(
              future: _personal,
              builder: (context, s) {
                if (s.hasError) {
                  return SliverToBoxAdapter(
                    child: ErrorPanel(
                      s.error!,
                      retry: () =>
                          setState(() => _personal = api.recommended()),
                    ),
                  );
                }
                if (!s.hasData) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: s.data!.isEmpty
                      ? const SliverToBoxAdapter(
                          child: EmptyPanel('QQ 音乐暂未返回个性化歌单'),
                        )
                      : PlaylistGrid(s.data!),
                );
              },
            ),
          ],
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 16, 16),
            sliver: SliverToBoxAdapter(
              child: Text(
                '推荐歌单',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          FutureBuilder(
            future: _featured,
            builder: (context, s) {
              if (s.hasError) {
                return SliverToBoxAdapter(
                  child: ErrorPanel(s.error!, retry: _refresh),
                );
              }
              if (!s.hasData) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: s.data!.isEmpty
                    ? const SliverToBoxAdapter(child: EmptyPanel('暂时没有推荐歌单'))
                    : PlaylistGrid(s.data!),
              );
            },
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
          ),
        ],
      ),
    );
  }
}
