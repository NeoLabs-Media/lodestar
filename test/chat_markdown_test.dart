// Markdown in assistant messages: formatting, citations inside any inline position, half-finished streaming
// text, HTML/script injection, unsafe links, long unbroken strings.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/ui/chat_markdown.dart';
import 'package:lodestar/ui/detail_page.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

const sample = '''# Big heading
## Second
Some **bold**, *italic* and ~~gone~~ text with `inline code`.

1. First
2. Second
   - nested a
   - nested b
3. Third

- bullet one
- bullet two

> a quote

---

```dart
final x = 1;
```

| Title | Why |
|---|---|
| **Fixture Movie 2** | calm |
| [#103] | tense |

[the site](https://example.com/page)
''';

Future<AppState> boot(WidgetTester t) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_md');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  UserStore.open('${dir.path}/user.db')
    ..setSetting('catalog_source', 'file')
    ..close();
  final app = AppState();
  await t.runAsync(() => app.init(supportDirOverride: dir.path));
  return app;
}

Future<void> show(
  WidgetTester t,
  AppState app,
  String text, {
  bool streaming = false,
  double width = 360,
}) async {
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: Atlas.theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: ChatMarkdown(text, streaming: streaming),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

String allText(WidgetTester t) => [
  for (final r in t.widgetList<RichText>(find.byType(RichText)))
    r.text.toPlainText(),
].join('\n');

void main() {
  Cover.offline = true;

  testWidgets(
    'renders bold, italic, strikethrough, headings, nested lists, code, quote, rule, table and links without raw markers',
    (t) async {
      final app = await boot(t);
      await show(t, app, sample, width: 520);
      final txt = allText(t);
      for (final raw in ['**', '~~', '```', '# ', '| ---', '[the site]']) {
        expect(txt, isNot(contains(raw)), reason: raw);
      }
      for (final s in [
        'Big heading',
        'bold',
        'italic',
        'gone',
        'inline code',
        'nested a',
        'bullet two',
        'a quote',
        'final x = 1;',
        'the site',
        'calm',
        'tense',
      ]) {
        expect(txt, contains(s), reason: s);
      }
      expect(txt, contains('1.'));
      expect(txt, contains('•'));
      expect(find.byType(Table), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      // bold really is bold, strikethrough really is struck
      TextStyle? styleOf(String needle) {
        TextStyle? found;
        for (final r in t.widgetList<RichText>(find.byType(RichText))) {
          r.text.visitChildren((s) {
            if (s is TextSpan && s.text == needle) found = s.style;
            return true;
          });
        }
        return found;
      }

      expect(styleOf('bold')!.fontWeight, FontWeight.w700);
      expect(styleOf('italic')!.fontStyle, FontStyle.italic);
      expect(styleOf('gone')!.decoration, TextDecoration.lineThrough);
      expect(
        styleOf('Big heading')!.fontSize!,
        lessThan(20),
        reason: 'headings are scaled down for a chat bubble',
      );
    },
  );

  testWidgets(
    'a citation token becomes a tappable chip inside bold text, a list item and a table cell',
    (t) async {
      final app = await boot(t);
      await show(
        t,
        app,
        '**Try [#102] first**\n\n- then [#103] later\n\n| a | b |\n|---|---|\n| x | [#104] |\n',
      );
      for (final id in [102, 103, 104]) {
        expect(
          find.byKey(ValueKey('cite-$id')),
          findsOneWidget,
          reason: 'id $id',
        );
      }
      expect(allText(t), isNot(contains('[#')));
      await t.tap(find.byKey(const ValueKey('cite-103')));
      await t.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      // unknown ids render nothing and do not crash
      await t.pageBack();
      await t.pumpWidget(const SizedBox());
      await show(t, app, 'ghost [#99999] here');
      expect(find.byType(CiteChip), findsOneWidget);
      expect(find.byType(DetailPage), findsNothing);
    },
  );

  testWidgets(
    'unfinished Markdown while streaming never throws; an open code fence stays plain text until it closes',
    (t) async {
      final app = await boot(t);
      for (var i = 0; i <= sample.length; i += 9) {
        await show(t, app, sample.substring(0, i), streaming: true);
      }
      await show(
        t,
        app,
        'Intro **bold start\n\n```dart\nfinal x = 1;',
        streaming: true,
      );
      expect(
        allText(t),
        contains('```dart'),
        reason: 'the unclosed fence is shown as plain text',
      );
      expect(allText(t), contains('Intro'));
      await show(
        t,
        app,
        'Intro\n\n```dart\nfinal x = 1;\n```\n',
        streaming: true,
      );
      expect(allText(t), isNot(contains('```')));
      await show(t, app, '| a | b |\n|---|---|\n| half', streaming: true);
      expect(allText(t), contains('half'));
      // pure parser sweep over every prefix
      for (var i = 0; i <= sample.length; i++) {
        expect(() => parseMarkdown(sample.substring(0, i)), returnsNormally);
      }
    },
  );

  testWidgets(
    'HTML and scripts are shown as literal text; images are never loaded',
    (t) async {
      final app = await boot(t);
      await show(
        t,
        app,
        '<script>alert(1)</script>\n\nhi <b>x</b> <img src="https://evil.example/p.png" onerror="alert(1)"> **ok**\n\n![pic](https://evil.example/p.png)\n\n<iframe src="x"></iframe>',
      );
      final txt = allText(t);
      expect(txt, contains('<script>alert(1)</script>'));
      expect(txt, contains('ok'));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(DetailPage), findsNothing);
    },
  );

  test('only http(s) links are allowed', () {
    expect(safeLink('https://example.com/a?b=1')!.host, 'example.com');
    expect(safeLink('http://example.com'), isNotNull);
    for (final bad in [
      'javascript:alert(1)',
      'JaVaScRiPt:alert(1)',
      'data:text/html,x',
      'file:///etc/passwd',
      'mailto:a@b.c',
      '/relative',
      '//host/x',
      'https://',
      '',
      null,
    ]) {
      expect(safeLink(bad), isNull, reason: '$bad');
    }
  });

  testWidgets(
    'unsafe links are plain text; a web link asks first and shows its real target',
    (t) async {
      final app = await boot(t);
      await show(
        t,
        app,
        '[js](javascript:alert(1))\n\n[dat](data:text/html,x)\n\n[fil](file:///etc/passwd)\n\n[web](https://example.com/real?x=1)',
      );
      for (final name in ['js', 'dat', 'fil']) {
        await t.tap(find.text(name, findRichText: true), warnIfMissed: false);
        await t.pump();
        expect(find.text('Open this link?'), findsNothing, reason: name);
      }
      await t.tap(find.text('web', findRichText: true));
      await t.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      expect(
        t
            .widget<SelectableText>(find.byKey(const ValueKey('link-target')))
            .data,
        'https://example.com/real?x=1',
      );
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Open this link?'), findsNothing);
    },
  );

  testWidgets(
    'long unbroken strings do not overflow (text, list, table, code, heading)',
    (t) async {
      final app = await boot(t);
      final long = 'x' * 400;
      await show(
        t,
        app,
        '# $long\n\n$long\n\n- $long\n  - $long\n\n> $long\n\n| a | b |\n|---|---|\n| $long | $long |\n\n```\n$long\n```\n\n**$long**',
      );
      expect(t.takeException(), isNull);
    },
  );
}
