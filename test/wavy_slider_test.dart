import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/ui/wavy_slider_track.dart';

void main() {
  for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
    testWidgets(
      'wavy track paints and preserves native keyboard/semantics: $direction',
      (tester) async {
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final semantics = tester.ensureSemantics();
        var value = 50.0, phase = 0.0;
        late StateSetter update;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.lightTheme(),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 240,
                    child: Directionality(
                      textDirection: direction,
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          update = setState;
                          return RepaintBoundary(
                            key: const ValueKey('wave-paint'),
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                trackShape: WavySliderTrackShape(phase: phase),
                              ),
                              child: Slider(
                                focusNode: focus,
                                value: value,
                                min: 0,
                                max: 100,
                                padding: EdgeInsets.zero,
                                semanticFormatterCallback: (v) =>
                                    '${v.round()}%',
                                onChanged: (v) => setState(() => value = v),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Future<List<int>> pixels() async => (await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('wave-paint')),
                )
                .toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return data!.buffer.asUint8List().toList();
          }))!;
          final before = await pixels();
          update(() => phase = .25);
          await tester.pumpAndSettle();
          expect(listEquals(before, await pixels()), isFalse);
          final values = <String>[];
          void collect(SemanticsNode node) {
            values.add(node.getSemanticsData().value);
            node.visitChildren((child) {
              collect(child);
              return true;
            });
          }

          collect(tester.getSemantics(find.byType(Slider)));
          expect(values, contains('50%'));
          focus.requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(
            value,
            direction == TextDirection.ltr ? greaterThan(50) : lessThan(50),
          );
          for (final end in [0.0, 100.0]) {
            update(() => value = end);
            await tester.pumpAndSettle();
            expect(tester.widget<Slider>(find.byType(Slider)).value, end);
            expect(tester.takeException(), isNull);
          }
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
