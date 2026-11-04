import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/review_choice_tile.dart';
import '../core/theme/theme_provider.dart';
import '../core/utils/haptic_feedback_util.dart';
import '../data/models.dart';
import '../player/music_handler.dart';
import '../providers.dart';
import 'collection_pages.dart';
import 'player_transition.dart';
import 'player_swipe_slide.dart';
import 'song_actions.dart';
import 'widgets.dart';
import 'mini_lyrics.dart';
import 'wavy_slider_track.dart';

String durationText(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});
  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  int? _songId;
  Future<List<LyricLine>>? _lyrics;
  List<LyricLine>? _lyricData;
  bool _showLyrics = false;
  LocalHistoryEntry? _lyricsHistory;
  bool _disposing = false;
  int _viewRevision = 0;
  final _lyricsTap = StationaryTapGuard();
  String? _paletteKey;
  ColorScheme? _palette;

  void _openLyricsFromTap() {
    if (_lyricsTap.consumeTap()) _setLyrics(true);
  }

  void _setLyrics(bool show) {
    if (show == _showLyrics) return;
    if (!show) {
      _lyricsHistory!.remove();
      return;
    }
    _lyricsHistory = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        _lyricsHistory = null;
        if (mounted && !_disposing) {
          setState(() {
            _showLyrics = false;
            _viewRevision++;
          });
        }
      },
    );
    ModalRoute.of(context)!.addLocalHistoryEntry(_lyricsHistory!);
    setState(() {
      _showLyrics = true;
      _viewRevision++;
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _lyricsHistory?.remove();
    super.dispose();
  }

  void _colorFromCover(Song song, double size, ColorScheme base) {
    final key = '${song.cover}|${base.brightness}';
    if (_paletteKey == key) return;
    _paletteKey = key;
    _palette = null;
    final uri = Uri.tryParse(song.cover);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
      1,
      1200,
    );
    // Match Cover's ResizeImage key so color extraction shares the decoded cover.
    final provider = ResizeImage(NetworkImage(song.cover), width: pixels);
    unawaited(
      ColorScheme.fromImageProvider(
            provider: provider,
            brightness: base.brightness,
          )
          .then((scheme) {
            if (mounted && _paletteKey == key) {
              setState(() => _palette = scheme);
            }
          })
          .catchError((Object _) {
            /* Keep the application's colors when artwork is unavailable. */
          }),
    );
  }

  Future<void> _chooseQuality(BuildContext playerContext) =>
      showModalBottomSheet<void>(
        context: playerContext,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .75,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        '播放音质',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                    ),
                    for (final quality in ['standard', 'exhigh', 'lossless'])
                      ReviewChoiceTile<String>(
                        title: qualityName(quality),
                        value: quality,
                        groupValue: ref.read(themeProvider).quality,
                        onSelected: () async {
                          await runAction(
                            context,
                            () => ref
                                .read(themeProvider.notifier)
                                .setQuality(quality),
                          );
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                        },
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('从下次加载生效；当前歌曲保留现有音质，权限不足时自动降级。'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _metadata(BuildContext context, Song song) => Column(
    key: const ValueKey('player-header'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PlayerHero(
        part: PlayerPart.title,
        child: Text(
          song.name,
          key: const ValueKey('player-song-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
      ),
      const SizedBox(height: 4),
      PlayerHero(
        part: PlayerPart.artist,
        child: Text(
          song.artistNames,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    ],
  );

  Widget _transport(BuildContext context, MusicHandler handler) => Row(
    key: const ValueKey('player-transport'),
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        tooltip: handler.shuffle ? '关闭随机播放' : '随机播放',
        isSelected: handler.shuffle,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: handler.shuffle
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
        ),
        icon: const Icon(Icons.shuffle_rounded),
        onPressed: () => runAction(
          context,
          () => handler.setShuffleMode(
            handler.shuffle
                ? AudioServiceShuffleMode.none
                : AudioServiceShuffleMode.all,
          ),
        ),
      ),
      IconButton(
        tooltip: '上一首',
        icon: const Icon(Icons.skip_previous_rounded, size: 32),
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => runAction(context, handler.skipToPrevious),
      ),
      const PlayButton(),
      IconButton(
        tooltip: '下一首',
        icon: const Icon(Icons.skip_next_rounded, size: 32),
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => runAction(context, handler.skipToNext),
      ),
      IconButton(
        tooltip: switch (handler.repeat) {
          AudioServiceRepeatMode.one => '单曲循环',
          AudioServiceRepeatMode.all => '列表循环',
          _ => '顺序播放',
        },
        isSelected: handler.repeat != AudioServiceRepeatMode.none,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: handler.repeat != AudioServiceRepeatMode.none
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
        ),
        icon: Icon(
          handler.repeat == AudioServiceRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
        ),
        onPressed: () => runAction(
          context,
          () => handler.setRepeatMode(switch (handler.repeat) {
            AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
            AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
            _ => AudioServiceRepeatMode.none,
          }),
        ),
      ),
    ],
  );

  Widget _utilities(BuildContext context, MusicHandler handler, Song song) =>
      Row(
        key: const ValueKey('player-utilities'),
        children: [
          IconButton(
            tooltip: _showLyrics ? '显示封面' : '同步歌词',
            isSelected: _showLyrics,
            icon: const Icon(Icons.lyrics_outlined),
            selectedIcon: const Icon(Icons.lyrics),
            onPressed: () => _setLyrics(!_showLyrics),
          ),
          IconButton(
            tooltip: '歌曲评论',
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            onPressed: () => openPage(context, CommentsPage(song)),
          ),
          ValueListenableBuilder(
            valueListenable: handler.cache.progress,
            builder: (context, task, _) {
              final active =
                  task != null &&
                  task.account == handler.account &&
                  task.song.id == song.id;
              final local = [
                'file',
                'content',
              ].contains(handler.currentStream?.uri.scheme);
              return IconButton(
                tooltip: active
                    ? '取消下载'
                    : local
                    ? '已下载到本机'
                    : '下载歌曲',
                onPressed: active
                    ? () => runAction(context, handler.cancelDownload)
                    : local
                    ? null
                    : () => downloadSongWithChoice(context, ref, song),
                icon: active
                    ? SizedBox.square(
                        dimension: 24,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              strokeWidth: 2,
                              value: task.fraction,
                            ),
                            const Icon(Icons.close_rounded, size: 14),
                          ],
                        ),
                      )
                    : Icon(
                        local
                            ? Icons.download_done_rounded
                            : Icons.download_rounded,
                      ),
              );
            },
          ),
          IconButton(
            tooltip: '播放队列（${handler.tracks.length}首）',
            icon: const Icon(Icons.queue_music_rounded),
            onPressed: () => showQueue(context, ref),
          ),
          IconButton(
            tooltip: '歌曲操作',
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () => showSongActions(
              context,
              ref,
              song,
              onChooseQuality: () => _chooseQuality(context),
            ),
          ),
        ].map((child) => Expanded(child: Center(child: child))).toList(),
      );

  Widget _error(BuildContext context, MusicHandler handler) =>
      ValueListenableBuilder(
        valueListenable: handler.errors,
        builder: (context, error, _) => error == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => runAction(context, handler.play),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      );

  Widget _controls(BuildContext context, MusicHandler handler, Song song) =>
      Column(
        key: const ValueKey('player-fixed-controls'),
        mainAxisSize: MainAxisSize.min,
        children: [
          _error(context, handler),
          _PlayerSeekBar(key: ValueKey(song.id), handler: handler, song: song),
          const SizedBox(height: 8),
          _transport(context, handler),
          const SizedBox(height: 12),
          _utilities(context, handler, song),
        ],
      );

  Widget _lyricsView(
    BuildContext context,
    MusicHandler handler,
    Song song, {
    bool mini = false,
  }) {
    if (handler.loading) {
      return Center(
        child: mini ? const Text('正在加载歌曲…') : const CircularProgressIndicator(),
      );
    }
    final lyrics = _lyrics ??= handler.lyricsFor(song);
    void retry() => setState(() {
      _lyricData = null;
      _lyrics = handler.lyricsFor(song, refresh: true);
    });
    return FutureBuilder<List<LyricLine>>(
      key: ValueKey(song.id),
      future: lyrics,
      initialData: song.id == _songId ? _lyricData : null,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return mini
              ? Center(
                  child: TextButton(
                    onPressed: retry,
                    child: const Text('歌词加载失败，点按重试'),
                  ),
                )
              : ErrorPanel(snapshot.error!, retry: retry);
        }
        if (!snapshot.hasData) {
          return Center(
            child: mini
                ? const Text('正在加载歌词…')
                : const CircularProgressIndicator(),
          );
        }
        if (song.id == _songId && identical(_lyrics, lyrics)) {
          _lyricData = snapshot.data;
        }
        if (snapshot.data!.isEmpty) {
          return mini
              ? const Center(child: Text('暂无同步歌词'))
              : const Center(
                  child: EmptyPanel('这首歌暂时没有同步歌词', icon: Icons.lyrics_outlined),
                );
        }
        if (mini) {
          return MiniLyrics(key: ValueKey(song.id), lines: snapshot.data!);
        }
        return SyncedLyrics(
          lines: snapshot.data!,
          onSeek: (position) =>
              unawaited(runAction(context, () => handler.seek(position))),
        );
      },
    );
  }

  Widget _miniLyrics(BuildContext context, MusicHandler handler, Song song) =>
      Semantics(
        button: true,
        label: '打开同步歌词',
        child: InkWell(
          onTapDown: _lyricsTap.down,
          onTapUp: _lyricsTap.up,
          onTapCancel: _lyricsTap.cancel,
          onTap: _openLyricsFromTap,
          child: SizedBox(
            key: const ValueKey('player-mini-lyrics'),
            width: double.infinity,
            height: MediaQuery.textScalerOf(context).scale(16) * 6,
            child: _lyricsView(context, handler, song, mini: true),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(playerProvider), baseTheme = Theme.of(context);
    final contentOpacity = MediaQuery.disableAnimationsOf(context)
        ? kAlwaysCompleteAnimation
        : (ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation).drive(
            CurveTween(curve: const Interval(.55, 1, curve: Curves.easeOut)),
          );
    ref.watch(themeProvider);
    return ValueListenableBuilder(
      valueListenable: handler.changes,
      builder: (context, _, child) {
        final song = handler.current;
        final showLyrics = _showLyrics;
        final viewRevision = _viewRevision;
        final colorKey = '${song?.cover}|${baseTheme.colorScheme.brightness}';
        if (song == null || _paletteKey != colorKey) _palette = null;
        if (song == null) _paletteKey = null;
        if (song?.id != _songId) {
          _songId = song?.id;
          _lyrics = null;
          _lyricData = null;
        }
        Widget panel(Song song, bool showLyrics) => LayoutBuilder(
          key: ValueKey(showLyrics),
          builder: (context, constraints) {
            if (song.id != handler.current?.id) return const SizedBox.shrink();
            final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
            final lyricHeight = 96 * textScale;
            final artSize = math
                .min(
                  constraints.maxWidth,
                  math.max(100.0, constraints.maxHeight - lyricHeight - 32),
                )
                .clamp(100.0, 400.0);
            if (showLyrics == _showLyrics && viewRevision == _viewRevision) {
              _colorFromCover(song, artSize, baseTheme.colorScheme);
            }
            if (showLyrics) return _lyricsView(context, handler, song);
            final artwork = Semantics(
              button: true,
              label: '打开同步歌词',
              child: GestureDetector(
                onTapDown: _lyricsTap.down,
                onTapUp: _lyricsTap.up,
                onTapCancel: _lyricsTap.cancel,
                onTap: _openLyricsFromTap,
                child: RepaintBoundary(
                  key: const ValueKey('player-artwork'),
                  child: PlayerHero(
                    part: PlayerPart.artwork,
                    child: Cover(song.cover, size: artSize, radius: 28),
                  ),
                ),
              ),
            );
            return SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(child: artwork),
                  const SizedBox(height: 20),
                  _miniLyrics(context, handler, song),
                ],
              ),
            );
          },
        );
        var scheme = _palette ?? baseTheme.colorScheme;
        final pureBlack = baseTheme.colorScheme.surface == Colors.black;
        if (pureBlack) scheme = scheme.copyWith(surface: Colors.black);
        return Theme(
          data: baseTheme.copyWith(colorScheme: scheme),
          child: Builder(
            builder: (context) => Scaffold(
              backgroundColor: scheme.surface,
              body: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: pureBlack
                        ? [Colors.black, Colors.black]
                        : [
                            Color.alphaBlend(
                              scheme.primaryContainer.withValues(alpha: .42),
                              scheme.surface,
                            ),
                            scheme.surface,
                          ],
                  ),
                ),
                child: FadeTransition(
                  opacity: contentOpacity,
                  child: SafeArea(
                    child: song == null
                        ? const Center(child: EmptyPanel('选择一首歌曲开始聆听'))
                        : Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  28,
                                  24,
                                  12,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: _metadata(context, song),
                                ),
                              ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final wide = constraints.maxWidth >= 600;
                                    final controls = _controls(
                                      context,
                                      handler,
                                      song,
                                    );
                                    return PlayerSwipeSlide(
                                      key: const ValueKey('player-view-swipe'),
                                      direction: showLyrics ? 1 : -1,
                                      value: (song.id, song.mid, showLyrics),
                                      neighbor: (step) =>
                                          (step == 1 && !showLyrics ||
                                              step == -1 && showLyrics)
                                          ? panel(song, !showLyrics)
                                          : null,
                                      onSwipe: (step) {
                                        _setLyrics(step == 1);
                                        return true;
                                      },
                                      child: panel(song, showLyrics),
                                      frame: (content) => Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 24,
                                        ),
                                        child: wide
                                            ? Row(
                                                children: [
                                                  Expanded(
                                                    flex: 44,
                                                    child: content,
                                                  ),
                                                  const SizedBox(width: 32),
                                                  Expanded(
                                                    flex: 56,
                                                    child: SingleChildScrollView(
                                                      primary: false,
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 12,
                                                          ),
                                                      child: ConstrainedBox(
                                                        constraints: BoxConstraints(
                                                          minHeight: math.max(
                                                            0,
                                                            constraints
                                                                    .maxHeight -
                                                                12,
                                                          ),
                                                        ),
                                                        child: Align(
                                                          alignment: Alignment
                                                              .bottomCenter,
                                                          child: controls,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : Column(
                                                children: [
                                                  Expanded(child: content),
                                                  const SizedBox(height: 12),
                                                  ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      maxHeight:
                                                          constraints
                                                              .maxHeight *
                                                          .55,
                                                    ),
                                                    child: SingleChildScrollView(
                                                      primary: false,
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 12,
                                                          ),
                                                      child: controls,
                                                    ),
                                                  ),
                                                ],
                                              ),
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
            ),
          ),
        );
      },
    );
  }
}

class _PlayerSeekBar extends StatefulWidget {
  const _PlayerSeekBar({super.key, required this.handler, required this.song});
  final MusicHandler handler;
  final Song song;
  @override
  State<_PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<_PlayerSeekBar>
    with SingleTickerProviderStateMixin {
  double? _drag;
  late final AnimationController _wave;
  late final StreamSubscription<dynamic> _playback;
  bool _motionAllowed = false;
  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _playback = widget.handler.player.playerStateStream.listen(
      (_) => _syncWave(),
    );
    widget.handler.changes.addListener(_syncWave);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncWave();
  }

  void _syncWave() {
    if (!mounted) return;
    final animate =
        _motionAllowed &&
        widget.handler.player.playing &&
        !widget.handler.loading &&
        widget.handler.currentStream != null &&
        _drag == null;
    if (animate && !_wave.isAnimating) _wave.repeat();
    if (!animate && _wave.isAnimating) _wave.stop();
  }

  @override
  void dispose() {
    widget.handler.changes.removeListener(_syncWave);
    _playback.cancel();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = widget.handler, scheme = Theme.of(context).colorScheme;
    return StreamBuilder<Duration?>(
      stream: handler.player.durationStream,
      builder: (context, duration) => StreamBuilder<Duration>(
        stream: handler.player.positionStream,
        builder: (context, position) {
          final total = handler.currentStream == null
              ? widget.song.duration
              : duration.data ??
                    handler.player.duration ??
                    widget.song.duration;
          final max = math.max(1.0, total.inMilliseconds.toDouble());
          final current =
              (_drag ??
                      (handler.currentStream == null
                              ? Duration.zero
                              : position.data ?? handler.player.position)
                          .inMilliseconds
                          .toDouble())
                  .clamp(0.0, max);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _wave,
                  builder: (context, child) => SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      trackShape: WavySliderTrackShape(phase: _wave.value),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                        disabledThumbRadius: 6,
                        elevation: 0,
                        pressedElevation: 0,
                      ),
                      activeTrackColor: scheme.primary,
                      inactiveTrackColor: scheme.surfaceContainerHighest,
                      thumbColor: scheme.primary,
                      overlayColor: noTouchOverlay(
                        scheme.primary.withValues(alpha: .12),
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey('player-seek'),
                      padding: EdgeInsets.zero,
                      min: 0,
                      max: max,
                      value: current,
                      semanticFormatterCallback: (v) =>
                          '${durationText(Duration(milliseconds: v.round()))} / ${durationText(total)}',
                      onChanged: handler.currentStream == null
                          ? null
                          : (v) {
                              setState(() => _drag = v);
                              _syncWave();
                            },
                      onChangeEnd: handler.currentStream == null
                          ? null
                          : (v) {
                              setState(() => _drag = null);
                              _syncWave();
                              unawaited(
                                runAction(
                                  context,
                                  () => handler.seek(
                                    Duration(milliseconds: v.round()),
                                  ),
                                ),
                              );
                            },
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    durationText(Duration(milliseconds: current.round())),
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    durationText(total),
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class SyncedLyrics extends ConsumerStatefulWidget {
  const SyncedLyrics({super.key, required this.lines, required this.onSeek});
  final List<LyricLine> lines;
  final ValueChanged<Duration> onSeek;
  @override
  ConsumerState<SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<SyncedLyrics> {
  static const _verticalPadding = 24.0;
  ScrollController? _scroll;
  late final _player = ref.read(playerProvider).player;
  StreamSubscription<Duration>? _subscription;
  int _active = -1;
  DateTime _manual = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    _active = lyricIndexAt(widget.lines, _player.position);
    _subscription = _player.positionStream.listen(_update);
  }

  @override
  void didUpdateWidget(covariant SyncedLyrics old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) {
      _active = -1;
      _manual = DateTime.fromMillisecondsSinceEpoch(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _update(_player.position);
      });
    }
  }

  void _update(Duration position) {
    final active = lyricIndexAt(widget.lines, position);
    if (active == _active || !mounted) return;
    setState(() => _active = active);
    final scroll = _scroll;
    if (active < 0 ||
        scroll == null ||
        !scroll.hasClients ||
        DateTime.now().difference(_manual) < const Duration(seconds: 4)) {
      return;
    }
    final target =
        (active * lineHeight - scroll.position.viewportDimension * .35).clamp(
          0.0,
          scroll.position.maxScrollExtent,
        );
    if (MediaQuery.disableAnimationsOf(context)) {
      scroll.jumpTo(target);
    } else {
      unawaited(
        scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  double get lineHeight => MediaQuery.textScalerOf(context).scale(22) * 3.8;
  @override
  void dispose() {
    _subscription?.cancel();
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Fixed extents allow correct positioning before the first paint.
      _scroll ??= ScrollController(
        keepScrollOffset: false,
        initialScrollOffset:
            (_active * lineHeight - constraints.maxHeight * .35).clamp(
              0.0,
              math.max(
                0.0,
                widget.lines.length * lineHeight +
                    _verticalPadding * 2 -
                    constraints.maxHeight,
              ),
            ),
      );
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollStartNotification && n.dragDetails != null) {
            _manual = DateTime.now();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          itemExtent: lineHeight,
          padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
          itemCount: widget.lines.length,
          itemBuilder: (context, i) {
            final line = widget.lines[i];
            return Semantics(
              selected: i == _active,
              child: InkWell(
                onTap: () => widget.onSeek(line.time),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        line.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: i == _active
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: i == _active
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      if (line.translation.isNotEmpty)
                        Text(
                          line.translation,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.start,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
