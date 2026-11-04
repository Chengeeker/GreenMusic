import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenmusic/core/design_system/components/review_page_scaffold.dart';
import 'package:greenmusic/ui/widgets.dart';

void main() {
  for (final insideBody in [false, true]) {
    testWidgets('music page inset, body context: $insideBody', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 44);
      tester.view.viewPadding = const FakeViewPadding(top: 44);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      Widget content(BuildContext context) => ListView(
        padding: pagePadding(context),
        children: const [Text('页面内容')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MusicScaffold(
              title: '详情',
              showMini: false,
              body: insideBody ? Builder(builder: content) : content(context),
            ),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('页面内容')).dy -
            tester.getRect(find.byType(AppBar)).bottom,
        closeTo(16, .01),
      );
    });
  }

  testWidgets('settings shell includes the toolbar once', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44);
    tester.view.viewPadding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewPageScaffold(
          title: '设置页',
          bodyBuilder: (context, insets) => ListView(
            padding: insets.add(const EdgeInsets.all(12)),
            children: const [Text('设置内容')],
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('设置内容')).dy -
          tester.getRect(find.byType(AppBar)).bottom,
      closeTo(12, .01),
    );
  });
}
