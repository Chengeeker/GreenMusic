import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/ui/player_swipe_slide.dart';

void main() {
  testWidgets('held slides reverse, settle, cancel and discard stale targets', (
    tester,
  ) async {
    var value = 1, commits = 0, direction = 1;
    var accept = true, reduced = false;
    late StateSetter update;
    Widget page(int index) => SizedBox.expand(
      child: ColoredBox(
        color: [Colors.red, Colors.green, Colors.blue][index],
        child: Text('page $index'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 240,
                    height: 100,
                    child: PlayerSwipeSlide(
                      value: value,
                      direction: direction,
                      child: page(value),
                      neighbor: (step) => value + step >= 0 && value + step < 3
                          ? page(value + step)
                          : null,
                      onSwipe: (step) {
                        if (!accept) return false;
                        update(() {
                          value += step;
                          commits++;
                        });
                        return true;
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final area = find.byType(PlayerSwipeSlide);
    double progress() =>
        1 -
        tester
            .widget<SlideTransition>(
              find.byKey(const ValueKey('swipe-slide-target')),
            )
            .position
            .value
            .dx
            .abs();
    final origin = tester.getTopLeft(find.text('page 1')).dx;
    final held = await tester.startGesture(tester.getCenter(area));
    await held.moveBy(const Offset(-96, 0));
    await tester.pump();
    expect(progress(), closeTo(.4, .001));
    expect(
      tester.getTopLeft(find.text('page 1')).dx,
      closeTo(origin - 96, .001),
    );
    expect(
      tester.getTopLeft(find.text('page 2')).dx,
      closeTo(origin + 144, .001),
    );
    expect(
      find.descendant(of: area, matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(commits, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress(), closeTo(.4, .001));
    await held.moveBy(const Offset(72, 0));
    await tester.pump();
    expect(progress(), closeTo(.1, .001));
    await held.up();
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(find.text('page 2'), findsNothing);

    final cancelled = await tester.startGesture(tester.getCenter(area));
    await cancelled.moveBy(const Offset(-30, 0));
    await cancelled.moveBy(const Offset(-90, 0));
    await tester.pump();
    expect(progress(), closeTo(.5, .001));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(commits, 0);

    final release = await tester.startGesture(tester.getCenter(area));
    await release.moveBy(const Offset(-120, 0));
    await release.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final inFlight = progress();
    final interrupt = await tester.startGesture(tester.getCenter(area));
    await interrupt.moveBy(Offset(inFlight * 240 - 24, 0));
    await tester.pump();
    expect(progress(), closeTo(.1, .001));
    await interrupt.up();
    await tester.pumpAndSettle();
    expect(commits, 0);

    final stale = await tester.startGesture(tester.getCenter(area));
    await stale.moveBy(const Offset(-100, 0));
    await tester.pump();
    update(() {
      value = 0;
      direction = -1;
    });
    await tester.pump();
    await stale.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.getTopLeft(find.text('page 0')).dx,
      inExclusiveRange(origin - 240, origin),
    );
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(find.text('page 0'), findsOneWidget);
    expect(find.text('page 2'), findsNothing);

    accept = false;
    await tester.drag(area, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(value, 0);
    expect(find.byKey(const ValueKey('swipe-slide-target')), findsNothing);
    accept = true;
    await tester.drag(area, const Offset(-120, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(commits, 1);
    expect(value, 1);
    expect(find.text('page 0'), findsNothing);
    expect(find.byKey(const ValueKey('swipe-slide-target')), findsNothing);
    expect(
      tester
          .widget<SlideTransition>(
            find.byKey(const ValueKey('swipe-slide-current')),
          )
          .position
          .value,
      Offset.zero,
    );
    update(() {
      reduced = true;
    });
    await tester.pump();
    final accessible = await tester.startGesture(tester.getCenter(area));
    await accessible.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(progress(), 0);
    expect(commits, 1);
    await accessible.up();
    await tester.pumpAndSettle();
    expect(commits, 2);
    expect(value, 2);
    expect(find.text('page 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
