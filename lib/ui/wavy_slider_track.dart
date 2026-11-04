import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps Slider's native input/semantics; only the painted track is customized.
class WavySliderTrackShape extends RoundedRectSliderTrackShape {
  const WavySliderTrackShape({this.phase = 0});
  final double phase;
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    final active = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    ).evaluate(enableAnimation)!;
    final inactive = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    ).evaluate(enableAnimation)!;
    final rtl = textDirection == TextDirection.rtl;
    final width = rect.width;
    final thumb =
        (rtl ? rect.right - thumbCenter.dx : thumbCenter.dx - rect.left).clamp(
          0.0,
          width,
        );
    double x(double distance) =>
        rtl ? rect.right - distance : rect.left + distance;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final inactiveStart = (thumb + 7).clamp(0.0, width);
    if (inactiveStart < width) {
      context.canvas.drawLine(
        Offset(x(inactiveStart), rect.center.dy),
        Offset(x(width), rect.center.dy),
        paint..color = inactive,
      );
    }
    final end = math.max(0.0, thumb - 7);
    if (end <= 0) return;
    final path = Path()..moveTo(x(0), rect.center.dy);
    // Two-pixel samples bound the work to the visible track, without path metrics.
    for (double d = 2; d < end + 2; d += 2) {
      final distance = math.min(d, end);
      final taper = math.min(1.0, math.min(distance / 8, (end - distance) / 8));
      final y =
          rect.center.dy +
          math.sin((distance / 24 - phase) * math.pi * 2) * 2.5 * taper;
      path.lineTo(x(distance), y);
    }
    context.canvas.drawPath(path, paint..color = active);
  }
}
