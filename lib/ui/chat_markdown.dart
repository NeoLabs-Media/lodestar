import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import 'detail_page.dart';
import 'theme.dart';

/// Renders text written by a model (assistant replies, taste summaries…) as Markdown.
///
/// Safe by construction: the parser output is walked by our own renderer, so
/// - raw HTML is never interpreted (HTML nodes come out as literal text),
/// - images are never fetched (only their alt text is shown),
/// - only http(s) links are tappable, and they open in the external browser after a confirmation that shows
///   the real target,
/// - `[#123]` citation tokens become tappable title chips, in any inline position (bold, lists, table cells).
/// Half-finished Markdown (streaming) never throws: an unclosed code fence is shown as plain text until it closes.
class ChatMarkdown extends StatefulWidget {
  final String text;
  final bool streaming;
  final double fontSize;
  final Color? color;
  const ChatMarkdown(
    this.text, {
    super.key,
    this.streaming = false,
    this.fontSize = 14.5,
    this.color,
  });

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final (complete, tail) = widget.streaming
        ? splitIncomplete(widget.text)
        : (widget.text, '');
    final base = TextStyle(
      color: widget.color ?? Atlas.bone,
      height: 1.5,
      fontSize: widget.fontSize,
    );
    final children = _Renderer(
      context,
      base,
      _recognizers,
    ).blocks(parseMarkdown(complete));
    if (tail.isNotEmpty) {
      children.add(Text(tail, style: base.copyWith(color: Atlas.muted)));
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// Splits streamed text into the part that can be rendered and an unfinished tail (an unclosed ``` fence).
(String, String) splitIncomplete(String text) {
  final fences = RegExp(
    r'^[ \t]*```',
    multiLine: true,
  ).allMatches(text).toList();
  if (fences.length.isOdd) {
    final at = fences.last.start;
    return (text.substring(0, at), text.substring(at));
  }
  return (text, '');
}

/// `[#123]` -> <cite id="123"/>
class CiteSyntax extends md.InlineSyntax {
  CiteSyntax() : super(r'\[#(\d+)\]');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('cite')..attributes['id'] = match[1]!);
    return true;
  }
}

List<md.Node> parseMarkdown(String text) {
  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [CiteSyntax()],
    encodeHtml: false,
  );
  try {
    return doc.parseLines(text.replaceAll('\r\n', '\n').split('\n'));
  } catch (_) {
    return [md.Text(text)]; // never let odd input break the chat
  }
}

/// Only plain web links are allowed.
Uri? safeLink(String? href) {
  if (href == null) return null;
  final u = Uri.tryParse(href.trim());
  if (u == null ||
      !u.hasScheme ||
      !(u.scheme == 'http' || u.scheme == 'https') ||
      u.host.isEmpty)
    return null;
  return u;
}

Future<void> confirmAndOpen(BuildContext context, Uri uri) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Open this link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('It opens in your browser:'),
          const SizedBox(height: 8),
          SelectableText(
            uri.toString(),
            key: const ValueKey('link-target'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('link-open'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (ok == true) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _Renderer {
  final BuildContext context;
  final TextStyle base;
  final List<TapGestureRecognizer> _recognizers;
  _Renderer(this.context, this.base, this._recognizers);

  static const _inlineTags = {
    'strong',
    'em',
    'del',
    'code',
    'a',
    'br',
    'img',
    'cite',
    'b',
    'i',
  };

  List<Widget> blocks(List<md.Node> nodes) {
    final out = <Widget>[];
    for (final n in nodes) {
      final w = block(n);
      if (w != null) out.add(w);
    }
    return out;
  }

  Widget _gap(Widget w, {double bottom = 8}) => Padding(
    padding: EdgeInsets.only(bottom: bottom),
    child: w,
  );

  Widget? block(md.Node n) {
    if (n is md.Text) {
      // raw HTML and stray text: shown literally, never interpreted
      return n.text.trim().isEmpty ? null : _gap(Text(n.text, style: base));
    }
    final e = n as md.Element;
    switch (e.tag) {
      case 'p':
        return _gap(_rich(e.children ?? const [], base));
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final size = e.tag == 'h1'
            ? 1.22
            : (e.tag == 'h2' ? 1.14 : 1.06); // kept small to fit a chat bubble
        return _gap(
          _rich(
            e.children ?? const [],
            base.copyWith(
              fontSize: base.fontSize! * size,
              fontWeight: FontWeight.w700,
            ),
          ),
          bottom: 6,
        );
      case 'ul' || 'ol':
        return _list(e);
      case 'blockquote':
        return _gap(
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Atlas.accent, width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: blocks(e.children ?? const []),
            ),
          ),
        );
      case 'pre':
        return _gap(_codeBlock(e));
      case 'hr':
        return _gap(const Divider(height: 16));
      case 'table':
        return _gap(_table(e));
      default:
        return _gap(_rich(e.children ?? [md.Text(e.textContent)], base));
    }
  }

  Widget _codeBlock(md.Element pre) {
    final code = pre.textContent.replaceAll(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          code,
          style: base.copyWith(
            fontFamily: 'Menlo',
            fontFamilyFallback: const ['Consolas', 'monospace'],
            fontSize: base.fontSize! - 1.5,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  Widget _list(md.Element list, {int depth = 0}) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    var i = 0;
    final items = <Widget>[];
    for (final c in list.children ?? const <md.Node>[]) {
      if (c is! md.Element || c.tag != 'li') continue;
      final marker = ordered ? '${start + i}.' : (depth == 0 ? '•' : '–');
      i++;
      // a list item mixes inline text with nested lists / paragraphs
      final inline = <md.Node>[];
      final nested = <Widget>[];
      void flush() {
        if (inline.isNotEmpty) {
          nested.add(_rich([...inline], base));
          inline.clear();
        }
      }

      for (final k in c.children ?? const <md.Node>[]) {
        if (k is md.Element && (k.tag == 'ul' || k.tag == 'ol')) {
          flush();
          nested.add(_list(k, depth: depth + 1));
        } else if (k is md.Element && k.tag == 'p') {
          flush();
          nested.add(_rich(k.children ?? const [], base));
        } else if (k is md.Element && !_inlineTags.contains(k.tag)) {
          flush();
          final b = block(k);
          if (b != null) nested.add(b);
        } else {
          inline.add(k);
        }
      }
      flush();
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: ordered ? 26 : 18,
                child: Text(marker, style: base.copyWith(color: Atlas.muted)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: nested,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        left: depth == 0 ? 2 : 6,
        bottom: depth == 0 ? 8 : 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  Widget _table(md.Element t) {
    final rows = <List<(List<md.Node>, bool, String?)>>[];
    void collect(md.Element section, bool head) {
      for (final r in section.children ?? const <md.Node>[]) {
        if (r is md.Element && r.tag == 'tr') {
          rows.add([
            for (final c in r.children ?? const <md.Node>[])
              if (c is md.Element)
                (
                  c.children ?? const <md.Node>[],
                  head || c.tag == 'th',
                  c.attributes['style'],
                ),
          ]);
        }
      }
    }

    for (final s in t.children ?? const <md.Node>[]) {
      if (s is md.Element) collect(s, s.tag == 'thead');
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows
        .map((r) => r.length)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(
          color: Colors.white.withValues(alpha: .14),
          width: .8,
        ),
        children: [
          for (final r in rows)
            TableRow(
              decoration: r.isNotEmpty && r.first.$2
                  ? BoxDecoration(color: Colors.white.withValues(alpha: .05))
                  : null,
              children: [
                for (var c = 0; c < cols; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: c < r.length
                        ? ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 260),
                            child: _rich(
                              r[c].$1,
                              base.copyWith(
                                fontSize: base.fontSize! - 1,
                                fontWeight: r[c].$2 ? FontWeight.w700 : null,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _rich(List<md.Node> nodes, TextStyle style) {
    final spans = <InlineSpan>[];
    for (final n in nodes) {
      _inline(n, style, spans);
    }
    return Text.rich(TextSpan(children: spans, style: style));
  }

  TapGestureRecognizer? _linkRec; // set while rendering the inside of a link

  void _inline(md.Node n, TextStyle style, List<InlineSpan> out) {
    if (n is md.Text) {
      out.add(TextSpan(text: n.text, style: style, recognizer: _linkRec));
      return;
    }
    final e = n as md.Element;
    List<InlineSpan> kids(TextStyle s) {
      final l = <InlineSpan>[];
      for (final c in e.children ?? const <md.Node>[]) {
        _inline(c, s, l);
      }
      return l;
    }

    switch (e.tag) {
      case 'strong' || 'b':
        out.add(
          TextSpan(
            children: kids(
              style.copyWith(fontWeight: FontWeight.w700, color: Atlas.boneHi),
            ),
            style: style,
          ),
        );
      case 'em' || 'i':
        out.add(
          TextSpan(
            children: kids(style.copyWith(fontStyle: FontStyle.italic)),
            style: style,
          ),
        );
      case 'del':
        out.add(
          TextSpan(
            children: kids(
              style.copyWith(decoration: TextDecoration.lineThrough),
            ),
            style: style,
          ),
        );
      case 'code':
        out.add(
          TextSpan(
            text: e.textContent,
            recognizer: _linkRec,
            style: style.copyWith(
              fontFamily: 'Menlo',
              fontFamilyFallback: const ['Consolas', 'monospace'],
              fontSize: style.fontSize! - 1.5,
              backgroundColor: Colors.white.withValues(alpha: .08),
            ),
          ),
        );
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'img':
        out.add(
          TextSpan(text: e.attributes['alt'] ?? '', style: style),
        ); // never loaded
      case 'cite':
        final id = int.tryParse(e.attributes['id'] ?? '');
        if (id != null)
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: CiteChip(id),
            ),
          );
      case 'a':
        final uri = safeLink(e.attributes['href']);
        if (uri == null) {
          out.addAll(
            kids(style),
          ); // javascript:, data:, file:, relative… -> plain text
        } else {
          final rec = TapGestureRecognizer()
            ..onTap = () => confirmAndOpen(context, uri);
          _recognizers.add(rec);
          _linkRec =
              rec; // the recognizer must sit on the text leaves, children do not inherit it
          final inner = kids(
            style.copyWith(
              color: Atlas.accent,
              decoration: TextDecoration.underline,
            ),
          );
          _linkRec = null;
          out.add(
            TextSpan(children: inner, mouseCursor: SystemMouseCursors.click),
          );
        }
      default:
        out.addAll(kids(style));
    }
  }
}

/// A cited catalog title as an inline, tappable chip that opens its detail page.
class CiteChip extends StatelessWidget {
  final int id;
  const CiteChip(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final idx = app.data.idToIdx[id];
    if (idx == null) return const SizedBox.shrink();
    final t = app.data.titles[idx];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        key: ValueKey('cite-$id'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => DetailPage(idx: idx))),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Atlas.accent.withValues(alpha: .14),
            border: Border.all(color: Atlas.accent.withValues(alpha: .5)),
          ),
          child: Text(
            t.display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Atlas.boneHi),
          ),
        ),
      ),
    );
  }
}
