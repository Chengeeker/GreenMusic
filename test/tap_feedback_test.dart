import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/core/theme/app_theme.dart';
import 'package:greenmusic/core/utils/haptic_feedback_util.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('search bar has no short or held press ink: dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? AppTheme.darkTheme() : AppTheme.lightTheme(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: RepaintBoundary(
                  key: ValueKey('search-paint'),
                  child: SearchBar(
                    leading: Icon(Icons.search_rounded),
                    hintText: '搜索歌曲',
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
              find.byKey(const ValueKey('search-paint')),
            )
            .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List().toList();
      }))!;
      final before = await pixels();
      final press = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.search_rounded)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(await pixels(), orderedEquals(before));
      await tester.pump(const Duration(milliseconds: 650));
      expect(await pixels(), orderedEquals(before));
      await press.cancel();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'no click ripple, haptics still respect preference: dark=$dark',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        final enabled = HapticFeedbackUtil.isEnabled;
        addTearDown(() {
          HapticFeedbackUtil.isEnabled = enabled;
          HapticFeedbackUtil.resetForTesting();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        HapticFeedbackUtil.isEnabled = true;
        HapticFeedbackUtil.resetForTesting();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.darkTheme() : AppTheme.lightTheme(),
            home: Material(
              child: Center(
                child: InkWell(
                  onTap: () => taps++,
                  child: const SizedBox(width: 100, height: 48),
                ),
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(InkWell));
        InteractiveInkFeature feedback() =>
            Theme.of(context).splashFactory.create(
              controller: Material.of(context),
              referenceBox: tester.renderObject(find.byType(InkWell)),
              position: const Offset(12, 12),
              color: Colors.green,
              textDirection: TextDirection.ltr,
            );
        final first = feedback();
        Material.of(context).addInkFeature(first);
        await tester.pump();
        expect(first, isA<NoSplash>());
        expect(
          calls
              .where((c) => c.method == 'HapticFeedback.vibrate')
              .single
              .arguments,
          'HapticFeedbackType.lightImpact',
        );
        first.dispose();
        HapticFeedbackUtil.isEnabled = false;
        final disabled = feedback();
        Material.of(context).addInkFeature(disabled);
        await tester.pump();
        expect(disabled, isA<NoSplash>());
        expect(
          calls.where((c) => c.method == 'HapticFeedback.vibrate'),
          hasLength(1),
        );
        disabled.dispose();
        await tester.tap(find.byType(InkWell));
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
