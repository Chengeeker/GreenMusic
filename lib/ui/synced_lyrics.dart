import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../player/lyrics_settings.dart';
import '../providers.dart';
import 'mini_lyrics.dart';

List<LyricWord> karaokeWords(
  LyricLine line,
  Duration? next,
  Duration? duration,
  KaraokeMode mode,
  bool songHasTiming,
) {
  if (mode == KaraokeMode.off || line.text.isEmpty) return const [];
  final real = line.words.isNotEmpty;
  if (!real &&
      (mode == KaraokeMode.timed ||
          mode == KaraokeMode.song && !songHasTiming)) {
    return const [];
  }
  final characters = line.text.characters.toList();
  final fallback = (characters.length * 220).clamp(800, 8000);
  final boundary = next != null && next > line.time ? next : duration;
  final available = boundary != null && boundary > line.time
      ? (boundary - line.time).inMilliseconds
      : fallback;
  final end =
      line.time +
      Duration(
        milliseconds: math.min(available, next == null ? fallback : 8000),
      );
  if (real) {
    return [
      for (var i = 0; i < line.words.length; i++)
        LyricWord(
          line.words[i].text,
          line.words[i].time,
          end:
              line.words[i].end ??
              (i + 1 < line.words.length
                  ? line.words[i + 1].time
                  : end > line.words[i].time
                  ? end
                  : line.words[i].time + const Duration(milliseconds: 800)),
        ),
    ];
  }
  final span = (end - line.time).inMicroseconds;
  return [
    for (var i = 0; i < characters.length; i++)
      LyricWord(
        characters[i],
        line.time + Duration(microseconds: span * i ~/ characters.length),
        end:
            line.time +
            Duration(microseconds: span * (i + 1) ~/ characters.length),
      ),
  ];
}

class SyncedLyrics extends ConsumerStatefulWidget {
  const SyncedLyrics({super.key, required this.lines, required this.onSeek});
  final List<LyricLine> lines;
  final ValueChanged<Duration> onSeek;
  @override
  ConsumerState<SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<SyncedLyrics>
    with TickerProviderStateMixin {
  static const _padding = 24.0;
  late final _player = ref.read(playerProvider).player;
  late final _position = ValueNotifier(_player.position);
  late final Ticker _ticker;
  late final AnimationController _motion;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  ScrollController? _scroll;
  List<double> _heights = [], _offsets = [];
  Object? _geometry;
  int _geometryRevision = 0, _active = -1;
  bool _visible = true, _reduced = false, _hasTiming = false;
  double _scrollStart = 0, _scrollDelta = 0;
  DateTime _manual = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _active = lyricIndexAt(widget.lines, _player.position);
    _hasTiming = widget.lines.any((l) => l.words.isNotEmpty);
    _ticker = createTicker((_) => _position.value = _player.position);
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _subscriptions.add(_player.positionStream.listen(_update));
    _subscriptions.add(
      _player.playerStateStream.listen((_) {
        if (_visible) _update(_player.position);
        _syncTicker();
      }),
    );
  }

  void _syncTicker() {
    if (!mounted) return;
    final mode = ref.read(lyricsSettingsProvider).karaoke;
    final active = _active >= 0 && _active < widget.lines.length;
    final hasWords =
        active &&
        (widget.lines[_active].words.isNotEmpty ||
            mode == KaraokeMode.all ||
            mode == KaraokeMode.song && _hasTiming);
    final run =
        _visible &&
        !_reduced &&
        _player.playing &&
        hasWords &&
        mode != KaraokeMode.off;
    if (run && !_ticker.isActive) _ticker.start();
    if (!run && _ticker.isActive) _ticker.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasVisible = _visible;
    final wasReduced = _reduced;
    _visible = TickerMode.valuesOf(context).enabled;
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_visible) {
      if (!wasVisible || _reduced != wasReduced) _geometry = null;
      _active = lyricIndexAt(widget.lines, _player.position);
      _position.value = _player.position;
    }
    if (!_visible || _reduced) _motion.stop();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _active = lyricIndexAt(widget.lines, _player.position);
      _position.value = _player.position;
      _hasTiming = widget.lines.any((l) => l.words.isNotEmpty);
      _manual = DateTime.fromMillisecondsSinceEpoch(0);
      _geometry = null;
      _motion.stop();
      _syncTicker();
    }
  }

  double _target(double height) =>
      (_active < 0
              ? 0.0
              : _padding +
                    _offsets[_active] +
                    math.min(
                      _heights[_active] / 2,
                      math.max(0, height * .35 - 12),
                    ) -
                    height * .35)
          .clamp(0.0, math.max(0, _offsets.last + _padding * 2 - height));

  void _update(Duration position) {
    if (!mounted || !_visible) return;
    _position.value = position;
    final active = lyricIndexAt(widget.lines, position);
    if (active == _active) return;
    final adjacent = active == _active + 1;
    setState(() => _active = active);
    _syncTicker();
    final scroll = _scroll;
    if (active < 0 ||
        scroll == null ||
        !scroll.hasClients ||
        DateTime.now().difference(_manual) < const Duration(seconds: 4)) {
      return;
    }
    final target = _target(scroll.position.viewportDimension);
    _motion.stop();
    if (_reduced || !adjacent) {
      scroll.jumpTo(target);
      return;
    }
    _scrollStart = scroll.offset;
    _scrollDelta = target - _scrollStart;
    if (ref.read(lyricsSettingsProvider).stagger && _scrollDelta.abs() > .1) {
      _motion.forward(from: 0);
    }
    unawaited(
      scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _ticker.dispose();
    _motion.dispose();
    _position.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(lyricsSettingsProvider);
    _syncTicker();
    final scheme = Theme.of(context).colorScheme;
    final align = settings.center ? TextAlign.center : TextAlign.left;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final bold = MediaQuery.boldTextOf(context);
    final style = DefaultTextStyle.of(context).style
        .merge(
          Theme.of(context).textTheme.titleLarge!.copyWith(
            fontSize: settings.fontSize.toDouble(),
            fontWeight: bold
                ? FontWeight.bold
                : FontWeight.values[settings.fontWeight ~/ 100 - 1],
            height: 1.35,
            color: scheme.onSurface,
          ),
        )
        .copyWith(inherit: false);
    final translated = DefaultTextStyle.of(context).style
        .merge(
          Theme.of(context).textTheme.bodyMedium!.copyWith(
            fontSize: settings.fontSize * .65,
            height: 1.35,
            color: scheme.onSurfaceVariant,
            fontWeight: bold ? FontWeight.bold : null,
          ),
        )
        .copyWith(inherit: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = (
          widget.lines,
          constraints.maxWidth,
          constraints.maxHeight,
          style,
          translated,
          scaler,
          direction,
          locale,
          align,
        );
        if (_geometry != geometry) {
          _geometry = geometry;
          _geometryRevision++;
          _motion.stop();
          final measure = TextPainter(
            textDirection: direction,
            textAlign: align,
            textScaler: scaler,
            locale: locale,
          );
          _offsets = [0];
          _heights = [
            for (final line in widget.lines)
              () {
                measure.text = TextSpan(
                  text: line.text.isEmpty ? ' ' : line.text,
                  style: style,
                );
                measure.layout(
                  maxWidth: math.max(1, constraints.maxWidth - 32),
                );
                var height = measure.height + 24;
                if (line.translation.isNotEmpty) {
                  measure.text = TextSpan(
                    text: line.translation,
                    style: translated,
                  );
                  measure.layout(
                    maxWidth: math.max(1, constraints.maxWidth - 32),
                  );
                  height += measure.height + 4;
                }
                height = math.max(48, height);
                _offsets.add(_offsets.last + height);
                return height;
              }(),
          ];
          measure.dispose();
          final old = _scroll;
          _scroll = ScrollController(
            keepScrollOffset: false,
            initialScrollOffset: _target(constraints.maxHeight),
          );
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _manual = DateTime.now();
              if (_motion.isAnimating) {
                setState(_motion.stop);
              }
            }
            return false;
          },
          child: ListView.builder(
            key: ValueKey(_geometryRevision),
            controller: _scroll,
            itemExtentBuilder: (index, _) => _heights[index],
            padding: const EdgeInsets.symmetric(vertical: _padding),
            itemCount: widget.lines.length,
            itemBuilder: (context, i) {
              final line = widget.lines[i], active = i == _active;
              final words = active && !_reduced
                  ? karaokeWords(
                      line,
                      i + 1 < widget.lines.length
                          ? widget.lines[i + 1].time
                          : null,
                      _player.duration,
                      settings.karaoke,
                      _hasTiming,
                    )
                  : const <LyricWord>[];
              final content = RepaintBoundary(
                child: ImageFiltered(
                  enabled:
                      settings.blur &&
                      !active &&
                      !MediaQuery.highContrastOf(context),
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: .6 + (i - _active).abs().clamp(0, 4) * .25,
                    sigmaY: .6 + (i - _active).abs().clamp(0, 4) * .25,
                  ),
                  child: Semantics(
                    selected: active,
                    child: InkWell(
                      onTap: () {
                        _manual = DateTime.fromMillisecondsSinceEpoch(0);
                        widget.onSeek(line.time);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (words.isEmpty)
                              Text(
                                line.text,
                                textAlign: align,
                                style: style.copyWith(
                                  color: active
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                              )
                            else
                              KaraokeText(
                                key: ValueKey('karaoke-$i'),
                                text: line.text,
                                words: words,
                                position: _position,
                                style: style,
                                dimColor: scheme.onSurfaceVariant,
                                align: align,
                              ),
                            if (line.translation.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                line.translation,
                                textAlign: align,
                                style: translated,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              return AnimatedBuilder(
                animation: _motion,
                child: content,
                builder: (context, child) {
                  var offset = 0.0;
                  if (settings.stagger &&
                      !_reduced &&
                      _motion.isAnimating &&
                      _scroll!.hasClients) {
                    final delay = (i - _active + 2).clamp(0, 6) * 18;
                    final progress = ((_motion.value * 420 - delay) / 300)
                        .clamp(0.0, 1.0);
                    offset =
                        _scroll!.offset -
                        _scrollStart -
                        _scrollDelta * Curves.easeOutCubic.transform(progress);
                  }
                  return Transform.translate(
                    key: ValueKey('lyric-motion-$i'),
                    offset: Offset(0, offset),
                    child: child,
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class KaraokeText extends StatefulWidget {
  const KaraokeText({
    super.key,
    required this.text,
    required this.words,
    required this.position,
    required this.style,
    required this.dimColor,
    required this.align,
  });
  final String text;
  final List<LyricWord> words;
  final ValueListenable<Duration> position;
  final TextStyle style;
  final Color dimColor;
  final TextAlign align;
  @override
  State<KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends State<KaraokeText> {
  _KaraokeClipper? _clipper;
  @override
  void dispose() {
    _clipper?.painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clipper?.painter.dispose();
    final style = DefaultTextStyle.of(context).style
        .merge(widget.style)
        .copyWith(inherit: false);
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: Directionality.of(context),
      textAlign: widget.align,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );
    _clipper = _KaraokeClipper(widget.words, widget.position, painter);
    return Stack(
      children: [
        SizedBox(
          width: double.infinity,
          child: Text(
            widget.text,
            textAlign: widget.align,
            style: widget.style.copyWith(color: widget.dimColor),
          ),
        ),
        Positioned.fill(
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: ClipPath(
                clipper: _clipper,
                child: RichText(
                  text: TextSpan(text: widget.text, style: style),
                  textAlign: widget.align,
                  textScaler: MediaQuery.textScalerOf(context),
                  textDirection: Directionality.of(context),
                  locale: Localizations.maybeLocaleOf(context),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _KaraokeClipper extends CustomClipper<Path> {
  _KaraokeClipper(this.words, this.position, this.painter)
    : super(reclip: position);
  final List<LyricWord> words;
  final ValueListenable<Duration> position;
  final TextPainter painter;
  Size? _size;
  List<List<ui.TextBox>> _boxes = [];
  int _completed = -1;
  List<ui.TextBox> _prefix = [];
  @override
  Path getClip(Size size) {
    if (_size != size) {
      _size = size;
      _completed = -1;
      painter.layout(minWidth: size.width, maxWidth: size.width);
      var offset = 0;
      _boxes = [
        for (final word in words)
          () {
            final start = offset;
            offset += word.text.length;
            return painter.getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: offset),
            );
          }(),
      ];
    }
    final path = Path(), now = position.value.inMicroseconds;
    var completed = 0;
    for (final word in words) {
      if (now < word.end!.inMicroseconds) break;
      completed += word.text.length;
    }
    if (_completed != completed) {
      _completed = completed;
      // A complete prefix includes ligatures spanning multiple character segments.
      _prefix = painter.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: completed),
      );
    }
    for (final box in _prefix) {
      path.addRect(box.toRect());
    }
    for (var i = 0; i < words.length; i++) {
      final word = words[i],
          end = word.end!.inMicroseconds,
          start = word.time.inMicroseconds;
      final progress = now <= start
          ? 0.0
          : end <= start
          ? 1.0
          : ((now - start) / (end - start)).clamp(0.0, 1.0);
      if (progress == 0 || progress == 1) continue;
      var width =
          _boxes[i].fold<double>(0, (sum, box) => sum + box.right - box.left) *
          progress;
      for (final box in _boxes[i]) {
        final filled = math.min(width, box.right - box.left);
        if (filled > 0) {
          path.addRect(
            Rect.fromLTRB(
              box.direction == TextDirection.rtl
                  ? box.right - filled
                  : box.left,
              box.top,
              box.direction == TextDirection.rtl
                  ? box.right
                  : box.left + filled,
              box.bottom,
            ),
          );
        }
        width -= filled;
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _KaraokeClipper oldClipper) => true;
}
