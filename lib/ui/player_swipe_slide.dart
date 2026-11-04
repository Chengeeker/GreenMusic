import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'player_transition.dart';

/// A physical left drag previews +1; a physical right drag previews -1.
class PlayerSwipeSlide extends StatefulWidget {
  const PlayerSwipeSlide({
    super.key,
    required this.value,
    required this.child,
    required this.neighbor,
    required this.onSwipe,
    this.frame,
    this.direction = 1,
    this.duration = const Duration(milliseconds: 220),
  });

  final Object value;
  final Widget child;
  final Widget? Function(int step) neighbor;
  final bool Function(int step) onSwipe;
  final Duration duration;
  final Widget Function(Widget content)? frame;
  final int direction;

  @override
  State<PlayerSwipeSlide> createState() => _PlayerSwipeSlideState();
}

class _PlayerSwipeSlideState extends State<PlayerSwipeSlide>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(vsync: this);
  Widget? _neighbor;
  double _distance = 0, _travel = 240;
  int _step = 0, _revision = 0, _switchEpoch = 0;
  bool _cancelled = false, _awaitingValue = false;

  void _clear() {
    _revision++;
    _progress.stop();
    _progress.value = 0;
    _neighbor = null;
    _distance = 0;
    _step = 0;
    _awaitingValue = false;
  }

  @override
  void didUpdateWidget(covariant PlayerSwipeSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      // A completed drag already displayed the new page; do not animate it twice.
      if (_awaitingValue) _switchEpoch++;
      _clear();
    }
  }

  void _start(DragStartDetails _) {
    _revision++;
    _progress.stop();
    _cancelled = false;
    _distance = (_step == 1 ? -1 : 1) * _progress.value * _travel;
  }

  void _update(DragUpdateDetails details) {
    _distance += details.delta.dx;
    final step = _distance < 0 ? 1 : -1;
    if (step != _step) {
      setState(() {
        _step = step;
        _neighbor = widget.neighbor(step);
      });
    }
    _progress.value =
        _neighbor == null || MediaQuery.disableAnimationsOf(context)
        ? 0
        : (_distance.abs() / _travel).clamp(0.0, 1.0);
  }

  void _end(DragEndDetails details) {
    if (_cancelled) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final sameDirection = velocity == 0 || velocity.sign == _distance.sign;
    unawaited(
      _settle(_neighbor != null && _distance.abs() >= 48 && sameDirection),
    );
  }

  void _cancel() {
    // Accepted drags can report PointerCancel as an end instead of onCancel.
    _cancelled = true;
    unawaited(_settle(false));
  }

  Future<void> _settle(bool commit) async {
    final revision = ++_revision;
    final target = commit ? 1.0 : 0.0;
    final remaining = (target - _progress.value).abs();
    try {
      await _progress
          .animateTo(
            target,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Duration(milliseconds: (180 * remaining).round()),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || revision != _revision) return;
    if (commit) {
      _awaitingValue = true;
      if (widget.onSwipe(_step)) return;
      _awaitingValue = false;
      await _settle(false);
      return;
    }
    setState(_clear);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) {
        _travel = constraints.maxWidth.clamp(1.0, double.infinity);
        return ClipRect(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              SlideTransition(
                key: const ValueKey('swipe-slide-current'),
                position: Tween<Offset>(
                  begin: Offset.zero,
                  end: Offset(-_step.toDouble(), 0),
                ).animate(_progress),
                child: AnimatedSwitcher(
                  key: ValueKey(_switchEpoch),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : widget.duration,
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(
                        child.key == ValueKey(widget.value)
                            ? widget.direction.toDouble()
                            : -widget.direction.toDouble(),
                        0,
                      ),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      for (final old in previous) inactivePlayerTransition(old),
                      ?current,
                    ],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(widget.value),
                    child: widget.child,
                  ),
                ),
              ),
              if (_neighbor != null)
                Positioned.fill(
                  child: SlideTransition(
                    key: const ValueKey('swipe-slide-target'),
                    position: Tween<Offset>(
                      begin: Offset(_step.toDouble(), 0),
                      end: Offset.zero,
                    ).animate(_progress),
                    // Static previews must locate the current lyric without a muted scroll animation.
                    child: MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: true),
                      child: inactivePlayerTransition(_neighbor!),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    return Listener(
      onPointerCancel: (_) => _cancel(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: _cancel,
        child: widget.frame?.call(content) ?? content,
      ),
    );
  }
}
