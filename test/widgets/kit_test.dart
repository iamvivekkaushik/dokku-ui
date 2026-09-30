import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Future<void> pump(WidgetTester tester, Widget child, {double width = 800}) async {
  await tester.runAsync(loadAppFonts);
  tester.view
    ..physicalSize = Size(width, 600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: child))));
}

void main() {
  testWidgets('a segmented control is only as wide as its labels', (tester) async {
    String? picked;
    await pump(
      tester,
      Wrap(children: [
        Seg<String>(value: 'Grid', options: const ['Grid', 'List'], onChanged: (v) => picked = v),
      ]),
    );
    final size = tester.getSize(find.byType(Seg<String>));
    expect(size.width, lessThan(140));
    expect(size.height, lessThan(40));
    await tester.tap(find.text('List'));
    expect(picked, 'List');
  });

  testWidgets('an expanded segmented control shares the width equally', (tester) async {
    await pump(
      tester,
      SizedBox(width: 300, child: Seg<String>(expand: true, value: 'a', options: const ['a', 'bbbbbb', 'c'], onChanged: (_) {})),
    );
    final a = tester.getSize(find.text('a').first), c = tester.getSize(find.text('c').first);
    expect(tester.getSize(find.byType(Seg<String>)).width, 300);
    expect(a.height, c.height);
  });

  testWidgets('a disabled button does nothing and a loading one shows progress', (tester) async {
    var taps = 0;
    await pump(
      tester,
      Column(mainAxisSize: MainAxisSize.min, children: [
        Btn('Enabled', onPressed: () => taps++),
        const Btn('Disabled'),
        Btn('Busy', loading: true, onPressed: () => taps++),
      ]),
    );
    await tester.tap(find.text('Enabled'));
    await tester.tap(find.text('Disabled'), warnIfMissed: false);
    await tester.tap(find.text('Busy'), warnIfMissed: false);
    expect(taps, 1);
    expect(find.byType(Spinner), findsOneWidget);
  });

  testWidgets('a switch reports the new value', (tester) async {
    bool? value;
    await pump(tester, AppSwitch(value: false, onChanged: (v) => value = v, label: 'Restart'));
    await tester.tap(find.byType(AppSwitch));
    expect(value, isTrue);
  });

  testWidgets('type-to-confirm keeps the action disabled until the text matches', (tester) async {
    bool? result;
    await pump(
      tester,
      Builder(
        builder: (context) => Btn('Open', onPressed: () async {
          result = await confirm(context, const Confirm(title: 'Destroy demo?', label: 'Destroy', danger: true, typeToConfirm: 'demo'));
        }),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Destroy'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(result, isNull, reason: 'nothing typed yet');
    await tester.enterText(find.byType(EditableText), 'demo');
    await tester.pump();
    await tester.tap(find.text('Destroy'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(result, isTrue);
  });

  testWidgets('a synced field follows the server until the user edits it', (tester) async {
    final c = SyncedController('main');
    addTearDown(c.dispose);
    c.sync('develop');
    expect(c.text, 'develop');
    expect(c.dirty, isFalse);
    c.controller.text = 'my-branch';
    expect(c.dirty, isTrue);
    c.sync('release');
    expect(c.text, 'my-branch', reason: 'a refresh must not overwrite what is being typed');
  });

  testWidgets('chart bars stand on the bottom line', (tester) async {
    await pump(tester, const SizedBox(width: 300, child: Sparkbars(values: [10, 20], max: 100)));
    final chart = tester.getRect(find.byType(Sparkbars));
    final bars = find.descendant(of: find.byType(Sparkbars), matching: find.byType(FractionallySizedBox));
    final last = tester.getRect(find.descendant(of: bars.last, matching: find.byType(Container)));
    expect(last.bottom, closeTo(chart.bottom, 1.5));
    expect(last.height, closeTo(chart.height * .2, 1.5));
  });

  testWidgets('a fitted grid widens a few cards to fill the row', (tester) async {
    Widget grid({required bool fit}) => AutoGrid(
        minWidth: 150, fit: fit, children: [for (var i = 0; i < 2; i++) Panel(child: SizedBox(height: 40, child: Text('card $i')))]);

    await pump(tester, grid(fit: false));
    expect(tester.getSize(find.byType(Panel).first).width, lessThan(200), reason: 'empty columns are kept');

    await pump(tester, grid(fit: true));
    expect(tester.getSize(find.byType(Panel).first).width, closeTo((800 - 16) / 2, 1));
  });

  testWidgets('a grid with a maximum width widens a few cards only up to it', (tester) async {
    Widget grid(int cards, {double? maxWidth}) => AutoGrid(
        minWidth: 150, maxWidth: maxWidth, children: [for (var i = 0; i < cards; i++) Panel(child: SizedBox(height: 40, child: Text('card $i')))]);
    double width() => tester.getSize(find.byType(Panel).first).width;

    // Four columns fit; two cards share the row when they may be this wide.
    await pump(tester, grid(2, maxWidth: 400));
    expect(width(), closeTo((800 - 16) / 2, 1));
    // A tighter cap keeps a third, empty column.
    await pump(tester, grid(2, maxWidth: 300));
    expect(width(), closeTo((800 - 2 * 16) / 3, 1));
    // One card is not stretched across the row either.
    await pump(tester, grid(1, maxWidth: 400));
    expect(width(), closeTo((800 - 16) / 2, 1));
    // A full row is laid out as usual.
    await pump(tester, grid(4, maxWidth: 400));
    expect(width(), closeTo((800 - 3 * 16) / 4, 1));
  });

  testWidgets('a fitted grid balances its rows and widens a shorter last row', (tester) async {
    Widget grid(int cards) => SingleChildScrollView(
          child: AutoGrid(
              minWidth: 250, fit: true, children: [for (var i = 0; i < cards; i++) Panel(child: SizedBox(height: 40, child: Text('card $i')))]),
        );
    double width(int card) => tester.getSize(find.byType(Panel).at(card)).width;
    double top(int card) => tester.getTopLeft(find.byType(Panel).at(card)).dy;

    // Three fit side by side at this width.
    await pump(tester, grid(4));
    expect([for (var i = 0; i < 4; i++) width(i)], everyElement(closeTo((800 - 16) / 2, 1)));
    expect(top(1), top(0));
    expect(top(2), greaterThan(top(0)));
    expect(top(3), top(2));

    await pump(tester, grid(5));
    expect(width(0), closeTo((800 - 32) / 3, 1));
    expect(width(4), closeTo((800 - 16) / 2, 1), reason: 'two cards share the last row');
  });

  testWidgets('a grid falls back to one column on a phone without stretching', (tester) async {
    await pump(
      tester,
      SingleChildScrollView(
        child: AutoGrid(minWidth: 300, children: [for (var i = 0; i < 3; i++) Panel(child: SizedBox(height: 40 + i * 10, child: Text('card $i')))]),
      ),
      width: 375,
    );
    expect(tester.takeException(), isNull);
    final first = tester.getRect(find.text('card 0')), second = tester.getRect(find.text('card 1'));
    expect(second.top, greaterThan(first.bottom), reason: 'cards stack vertically');
  });
}
