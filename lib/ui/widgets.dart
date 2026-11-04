import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/review_frosted_app_bar.dart';
import '../core/utils/app_dialog.dart';
import '../core/utils/app_toast.dart';
import '../data/models.dart';
import '../data/qq_music_api.dart';
import '../providers.dart';
import '../player/music_handler.dart';
import 'mini_lyrics.dart';
import 'player_transition.dart';
import 'player_swipe_slide.dart';
import 'song_actions.dart';

String qualityName(String value) => switch (value) {
  'exhigh' => '高品质 MP3',
  'lossless' => '无损 FLAC',
  _ => '标准 MP3',
};

String downloadSize(int bytes) =>
    '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

class StationaryTapGuard {
  Offset? _start;
  bool _allowed = true;
  void down(TapDownDetails details) {
    _start = details.globalPosition;
    _allowed = true;
  }

  void up(TapUpDetails details) {
    final start = _start;
    _allowed = start == null || (details.globalPosition - start).distance <= 6;
    _start = null;
  }

  void cancel() {
    _start = null;
    _allowed = true;
  }

  bool consumeTap() {
    final allowed = _allowed;
    _allowed = true;
    return allowed;
  }
}

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) AppToast.show(context, success);
  } catch (e) {
    if (context.mounted) {
      AppToast.show(
        context,
        errorText(e),
        duration: const Duration(seconds: 5),
      );
    }
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String content,
) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askName(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showAppDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 20,
        decoration: const InputDecoration(labelText: '歌单名称'),
        onSubmitted: (s) {
          if (s.trim().isNotEmpty) Navigator.pop(ctx, s.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(ctx, controller.text.trim());
            }
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  // Keep the controller alive until the dialog's reverse transition completes.
  await Future<void>.delayed(const Duration(milliseconds: 80));
  controller.dispose();
  return value;
}

void openPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class Cover extends StatelessWidget {
  const Cover(
    this.url, {
    super.key,
    this.size = 48,
    this.radius = 12,
    this.placeholder,
  });
  final String url;
  final double size, radius;
  final Widget? placeholder;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback =
        placeholder ??
        ColoredBox(
          color: scheme.secondaryContainer,
          child: Center(
            child: Icon(
              Icons.music_note_rounded,
              color: scheme.onSecondaryContainer,
              size: size * .4,
            ),
          ),
        );
    final uri = Uri.tryParse(url),
        pixels = (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
          1,
          1200,
        );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox.square(
          dimension: size,
          child: uri == null || !['http', 'https'].contains(uri.scheme)
              ? fallback
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  cacheWidth: pixels,
                  errorBuilder: (_, e, s) => fallback,
                  frameBuilder: (_, child, frame, wasSynchronous) =>
                      frame == null ? fallback : child,
                ),
        ),
      ),
    );
  }
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel(this.error, {super.key, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_off_rounded,
          size: 36,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(errorText(error), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel(
    this.message, {
    super.key,
    this.icon = Icons.library_music_outlined,
  });
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

class SongTile extends ConsumerWidget {
  const SongTile(
    this.song, {
    super.key,
    required this.onPlay,
    this.list,
    this.onChanged,
  });
  final Song song;
  final VoidCallback onPlay;
  final MusicList? list;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(playerProvider);
    return ValueListenableBuilder(
      valueListenable: handler.changes,
      builder: (context, _, child) => ListTile(
        leading: Cover(song.cover),
        selected: handler.current?.id == song.id,
        title: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${song.artistNames} · ${song.album.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: onPlay,
        trailing: IconButton(
          tooltip: '${song.name}的更多操作',
          icon: const Icon(Icons.more_horiz_rounded),
          onPressed: () => showSongActions(
            context,
            ref,
            song,
            list: list,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});
  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  Song? _swipeTarget;
  final _openTap = StationaryTapGuard();

  Widget _trackContent(
    BuildContext context,
    MusicHandler handler,
    Song song, {
    bool preview = false,
  }) {
    final lyrics = handler.lyricsFor(song);
    final loading = !preview && handler.loading;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4);
    return Row(
      key: ValueKey(song.id),
      children: [
        PlayerHero(
          part: PlayerPart.artwork,
          child: Cover(song.cover, size: 42),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlayerHero(
                part: PlayerPart.title,
                child: Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              SizedBox(
                key: const ValueKey('mini-player-lyric'),
                height: MediaQuery.textScalerOf(context).scale(12) * 1.4,
                child: FutureBuilder<List<LyricLine>>(
                  future: lyrics,
                  builder: (context, snapshot) {
                    final status = loading
                        ? '正在加载歌曲…'
                        : snapshot.connectionState == ConnectionState.waiting
                        ? '正在加载歌词…'
                        : snapshot.hasError
                        ? '歌词暂不可用'
                        : !snapshot.hasData
                        ? '正在加载歌词…'
                        : null;
                    return status != null
                        ? Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          )
                        : preview
                        ? Text(
                            snapshot.data!
                                    .where(
                                      (line) =>
                                          line.text.trim().isNotEmpty &&
                                          line.time <= Duration.zero,
                                    )
                                    .lastOrNull
                                    ?.text ??
                                '前奏',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          )
                        : MiniLyrics(lines: snapshot.data!, singleLine: true);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(playerProvider);
    return ValueListenableBuilder(
      valueListenable: handler.changes,
      builder: (context, _, child) {
        final song = handler.current;
        if (song == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Builder(
            builder: (miniContext) => Semantics(
              hint: '左滑下一首，右滑上一首',
              child: PlayerSwipeSlide(
                key: const ValueKey('mini-player-track-switch'),
                value: (song.id, song.mid, handler.index, handler.tracks),
                duration: const Duration(milliseconds: 320),
                neighbor: (step) {
                  if (handler.tracks.length < 2) return null;
                  final next = step == 1
                      ? handler.nextQueueIndex
                      : handler.index <= 0
                      ? handler.tracks.length - 1
                      : handler.index - 1;
                  _swipeTarget = handler.tracks[next];
                  return _trackContent(
                    context,
                    handler,
                    _swipeTarget!,
                    preview: true,
                  );
                },
                onSwipe: (step) {
                  final next = handler.tracks.indexWhere(
                    (track) =>
                        track.id == _swipeTarget?.id &&
                        track.mid == _swipeTarget?.mid,
                  );
                  if (next < 0 || next == handler.index) return false;
                  runAction(context, () => handler.skipToQueueItem(next));
                  return true;
                },
                child: _trackContent(context, handler, song),
                frame: (content) => Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTapDown: _openTap.down,
                              onTapUp: _openTap.up,
                              onTapCancel: _openTap.cancel,
                              onTap: () {
                                if (_openTap.consumeTap()) {
                                  openPlayer(miniContext);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                child: content,
                              ),
                            ),
                          ),
                          PlayButton(compact: true),
                          IconButton(
                            tooltip: '播放队列',
                            onPressed: () => showQueue(context, ref),
                            icon: const Icon(Icons.queue_music_rounded),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                      StreamBuilder<Duration>(
                        stream: handler.player.positionStream,
                        builder: (context, s) {
                          final total =
                              handler.player.duration?.inMilliseconds ??
                              song.duration.inMilliseconds;
                          final value = total > 0
                              ? ((s.data?.inMilliseconds ?? 0) / total).clamp(
                                  0.0,
                                  1.0,
                                )
                              : 0.0;
                          return LinearProgressIndicator(
                            value: value,
                            minHeight: 2,
                            backgroundColor: Colors.transparent,
                          );
                        },
                      ),
                    ],
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

class PlayButton extends ConsumerWidget {
  const PlayButton({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(playerProvider);
    return StreamBuilder(
      stream: h.player.playerStateStream,
      builder: (context, s) => ValueListenableBuilder(
        valueListenable: h.changes,
        builder: (context, _, child) {
          final loading = h.loading;
          final playing = loading ? h.playRequested : h.player.playing;
          final icon = loading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: compact
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.onPrimary,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: compact ? 28 : 40,
                );
          Future<void> action() =>
              runAction(context, playing ? h.pause : h.play);
          return compact
              ? IconButton(
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: action,
                  icon: icon,
                )
              : IconButton.filled(
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: action,
                  icon: icon,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(64, 64),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                );
        },
      ),
    );
  }
}

class MusicScaffold extends StatelessWidget {
  const MusicScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.showMini = true,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool showMini;
  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: ReviewFrostedAppBar(title: Text(title), actions: actions),
    body: body,
    bottomNavigationBar: showMini
        ? const SafeArea(top: false, child: MiniPlayer())
        : null,
  );
}

EdgeInsets pagePadding(BuildContext context, {double horizontal = 16}) =>
    EdgeInsets.fromLTRB(
      horizontal,
      reviewContentTopInset(context) + 16,
      horizontal,
      24 + MediaQuery.viewPaddingOf(context).bottom,
    );
