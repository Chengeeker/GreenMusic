import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../data/models.dart';
import '../providers.dart';

int lyricIndexAt(List<LyricLine> lines, Duration position) {
  var low = 0, high = lines.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (lines[middle].time <= position) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low - 1;
}

class MiniLyrics extends ConsumerStatefulWidget {
  const MiniLyrics({super.key, required this.lines, this.singleLine = false});
  final List<LyricLine> lines;
  final bool singleLine;
  @override
  ConsumerState<MiniLyrics> createState() => _MiniLyricsState();
}

class _MiniLyricsState extends ConsumerState<MiniLyrics> {
  late final AudioPlayer _player;
  late final StreamSubscription<Duration> _subscription;
  late final FixedExtentScrollController _wheel;
  int _active = -1;
  late List<LyricLine> _visible;
  bool _hasTranslations = false;
  bool _activeView = true;
  int _scrollRevision = 0;
  @override
  void initState() {
    super.initState();
    _player = ref.read(playerProvider).player;
    _readLines();
    _wheel = FixedExtentScrollController(initialItem: _active + 1);
    _subscription = _player.positionStream.listen((position) {
      if (!_activeView) return;
      final active = lyricIndexAt(_visible, position);
      if (mounted && active != _active) {
        final adjacent = (active - _active).abs() == 1;
        setState(() => _active = active);
        _positionWheel(animate: adjacent);
      }
    });
  }

  void _readLines() {
    _visible = widget.lines
        .where((line) => line.text.trim().isNotEmpty)
        .toList();
    _hasTranslations = _visible.any((line) => line.translation.isNotEmpty);
    _active = lyricIndexAt(_visible, _player.position);
  }

  void _positionWheel({bool animate = false}) {
    final revision = ++_scrollRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_activeView ||
          !_wheel.hasClients ||
          revision != _scrollRevision) {
        return;
      }
      final target = _active + 1;
      if (animate && !MediaQuery.disableAnimationsOf(context)) {
        unawaited(
          _wheel.animateToItem(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
          ),
        );
      } else {
        _wheel.jumpToItem(target);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _activeView = TickerMode.valuesOf(context).enabled;
    if (_activeView) {
      _active = lyricIndexAt(_visible, _player.position);
      _positionWheel();
    }
  }

  @override
  void didUpdateWidget(covariant MiniLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _readLines();
      _positionWheel();
    } else if (oldWidget.singleLine != widget.singleLine) {
      _positionWheel();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _wheel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_visible.isEmpty) {
      return Text(
        '暂无同步歌词',
        maxLines: 1,
        style: widget.singleLine ? Theme.of(context).textTheme.bodySmall : null,
      );
    }
    final theme = Theme.of(context).textTheme;
    final current = _active < 0 ? null : _visible[_active];
    final translation = current?.translation ?? '';
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    final blur = !widget.singleLine && !MediaQuery.highContrastOf(context);
    return Semantics(
      label:
          '${current?.text ?? '前奏'}${!widget.singleLine && translation.isNotEmpty ? '\n$translation' : ''}',
      child: ExcludeSemantics(
        child: ExcludeFocus(
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return ListWheelScrollView.useDelegate(
                  key: const ValueKey('mini-lyrics-wheel'),
                  controller: _wheel,
                  physics: const NeverScrollableScrollPhysics(),
                  itemExtent:
                      constraints.maxHeight / (widget.singleLine ? 1 : 3),
                  diameterRatio: 2.6,
                  perspective: .0015,
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: _visible.length + 2,
                    builder: (context, item) {
                      final index = item - 1;
                      final line = index >= 0 && index < _visible.length
                          ? _visible[index]
                          : null;
                      final text =
                          line?.text ??
                          (index == -1 && _active == -1 ? '前奏' : '');
                      final role = index == _active
                          ? 'current'
                          : index == _active - 1
                          ? 'previous'
                          : index == _active + 1
                          ? 'next'
                          : null;
                      return TweenAnimationBuilder<double>(
                        key: ValueKey(item),
                        tween: Tween(
                          begin: index == _active ? 1 : 0,
                          end: index == _active ? 1 : 0,
                        ),
                        duration: duration,
                        curve: Curves.easeInOutCubic,
                        builder: (context, focus, _) {
                          final style = widget.singleLine
                              ? theme.bodySmall?.copyWith(height: 1.4)
                              : TextStyle.lerp(
                                  theme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  theme.bodyLarge?.copyWith(
                                    color: scheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  focus,
                                )?.copyWith(
                                  height: _hasTranslations ? 1.2 : 1.5,
                                );
                          return ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: .7 * (1 - focus),
                              sigmaY: .7 * (1 - focus),
                            ),
                            enabled: blur,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: SizedBox(
                                  width: constraints.maxWidth,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        text,
                                        key: !widget.singleLine && role != null
                                            ? ValueKey('mini-lyric-$role')
                                            : null,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: style,
                                      ),
                                      if (!widget.singleLine &&
                                          _hasTranslations)
                                        Opacity(
                                          opacity: focus,
                                          child: Text(
                                            line?.translation ?? '',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.bodySmall?.copyWith(
                                              height: 1,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
