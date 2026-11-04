import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../providers.dart';
import 'collection_pages.dart';
import 'widgets.dart';

class SearchView extends ConsumerStatefulWidget {
  const SearchView({super.key});
  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  final _query = TextEditingController(), _scroll = ScrollController();
  final _songs = <Song>[], _albums = <Album>[], _artists = <Artist>[];
  List<String> _suggestions = [];
  Timer? _debounce;
  CancelToken? _searchCancel, _suggestCancel;
  int _kind = 0, _offset = 0, _total = 0, _generation = 0;
  String _source = '', _submitted = '';
  bool _busy = false, _more = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _scroll.dispose();
    _debounce?.cancel();
    _searchCancel?.cancel();
    _suggestCancel?.cancel();
    super.dispose();
  }

  void _nearEnd() {
    if (_scroll.position.extentAfter < 500 && _error == null) _load();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _suggestCancel?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final cancel = CancelToken();
      _suggestCancel = cancel;
      try {
        final suggestions = await ref
            .read(apiProvider)
            .suggestions(value, cancel: cancel);
        if (mounted && !cancel.isCancelled && _query.text == value) {
          setState(() => _suggestions = suggestions);
        }
      } catch (_) {
        if (mounted && !cancel.isCancelled) setState(() => _suggestions = []);
      }
    });
  }

  void _submit([String? value]) {
    final query = (value ?? _query.text).trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    _debounce?.cancel();
    _suggestCancel?.cancel();
    _searchCancel?.cancel();
    _query.text = query;
    _generation++;
    _songs.clear();
    _albums.clear();
    _artists.clear();
    _suggestions = [];
    _submitted = query;
    _offset = 0;
    _source = '';
    _more = true;
    _busy = false;
    _error = null;
    _load();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _load() async {
    if (_busy || !_more || _submitted.isEmpty) return;
    final generation = _generation, cancel = CancelToken();
    _searchCancel = cancel;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(apiProvider)
          .search(
            _submitted,
            kind: _kind,
            offset: _offset,
            source: _source,
            cancel: cancel,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        final seenSongs = _songs.map((s) => s.id).toSet(),
            seenAlbums = _albums.map((s) => s.id).toSet(),
            seenArtists = _artists.map((s) => s.id).toSet();
        final fresh = page.songs.where((s) => seenSongs.add(s.id)).toList();
        final freshAlbums = page.albums
            .where((s) => seenAlbums.add(s.id))
            .toList();
        final freshArtists = page.artists
            .where((s) => seenArtists.add(s.id))
            .toList();
        _songs.addAll(fresh);
        _albums.addAll(freshAlbums);
        _artists.addAll(freshArtists);
        _source = page.source;
        _total = page.total;
        _more = page.more && page.nextOffset > _offset;
        if (_offset > 0 &&
            fresh.isEmpty &&
            freshAlbums.isEmpty &&
            freshArtists.isEmpty) {
          _more = false;
          _error = const MusicError('服务端搜索分页未前进，请重新搜索');
        }
        _offset = page.nextOffset;
      });
    } catch (e) {
      if (mounted && generation == _generation && !cancel.isCancelled) {
        setState(() => _error = e);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final length = _kind == 0
        ? _songs.length
        : _kind == 1
        ? _artists.length
        : _albums.length;
    return CustomScrollView(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: pagePadding(context).copyWith(bottom: 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SearchBar(
                  controller: _query,
                  leading: const Icon(Icons.search_rounded),
                  hintText: '歌曲、歌手、专辑',
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                  trailing: [
                    IconButton(
                      tooltip: '开始搜索',
                      onPressed: _submit,
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < 3; i++)
                      ChoiceChip(
                        label: Text(['歌曲', '歌手', '专辑'][i]),
                        selected: i == _kind,
                        onSelected: (_) {
                          setState(() => _kind = i);
                          if (_submitted.isNotEmpty) _submit();
                        },
                      ),
                  ],
                ),
                if (_submitted.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '“$_submitted” · 共 $_total 项',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_suggestions.isNotEmpty)
          SliverList.builder(
            itemCount: _suggestions.length,
            itemBuilder: (context, i) => ListTile(
              leading: const Icon(Icons.search_rounded),
              title: Text(_suggestions[i]),
              onTap: () => _submit(_suggestions[i]),
            ),
          )
        else
          SliverList.builder(
            itemCount: length,
            itemBuilder: (context, i) {
              if (_kind == 0) {
                return SongTile(
                  _songs[i],
                  onPlay: () =>
                      ref.read(playerProvider).playSongs(_songs, start: i),
                );
              }
              if (_kind == 1) {
                final artist = _artists[i];
                return ListTile(
                  leading: Cover(artist.cover, radius: 24),
                  title: Text(artist.name),
                  onTap: () => openPage(context, ArtistPage(artist)),
                );
              }
              final album = _albums[i];
              return ListTile(
                leading: Cover(album.cover),
                title: Text(album.name),
                onTap: () => openPage(context, SongCollectionPage.album(album)),
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
              : _submitted.isEmpty
              ? const EmptyPanel('搜索你想听的音乐', icon: Icons.search_rounded)
              : length == 0
              ? const EmptyPanel('没有找到结果，换个关键词试试')
              : _more
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    onPressed: _load,
                    child: const Text('加载更多'),
                  ),
                )
              : const SizedBox(height: 24),
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
        ),
      ],
    );
  }
}
