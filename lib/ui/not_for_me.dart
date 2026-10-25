import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/labels.dart';
import 'rating_sheet.dart';
import 'theme.dart';

/// What the user told us in the "What put you off?" sheet.
class NotForMeResult {
  final Set<String> reasons; // n:aspect, x:kind|value, h:content_warnings|value
  final String note;
  final bool bringBack; // editing only: take it out of the skipped list
  const NotForMeResult(this.reasons, this.note, {this.bringBack = false});
}

/// Tag chips (most distinctive first) and general aspects offered for a title, as dislike keys.
({List<(String, String)> tags, List<(String, String)> aspects}) notForMeChoices(
  AppState app,
  int idx,
) {
  final tags = [
    for (final (k, label) in specificReasonsFor(app.data, idx, max: 14))
      ('x:${k.substring(2)}', label),
  ];
  final aspects = [
    for (final g in [...genericReasons, ...dislikeOnlyAspects])
      ('n:${g.key}', g.label),
  ];
  return (tags: tags, aspects: aspects);
}

/// Entry point for every "Not for me" button. Honours the "ask why" setting:
/// sheet (default) opens the sheet first, snackbar hides at once and offers "Tell us why", never just hides.
Future<void> notForMe(BuildContext context, int idx) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  switch (app.askWhyMode) {
    case 'never':
      app.skip(idx);
    case 'snackbar':
      app.skip(idx);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Hidden: ${app.data.titles[idx].display}'),
            action: SnackBarAction(
              label: 'Tell us why',
              onPressed: () => editSkipReasons(context, idx),
            ),
          ),
        );
    default:
      final r = await showNotForMeSheet(context, idx);
      if (r != null) app.skip(idx, reasons: r.reasons, note: r.note);
  }
}

/// Edit (or clear) the reasons of a title that is already skipped.
Future<void> editSkipReasons(BuildContext context, int idx) async {
  final app = context.read<AppState>();
  final e = app.entries[idx];
  final r = await showNotForMeSheet(
    context,
    idx,
    initial: e?.reasons ?? const {},
    note: e?.note ?? '',
    editing: true,
  );
  if (r == null) return;
  if (r.bringBack) {
    app.remove(idx);
  } else {
    app.skip(idx, reasons: r.reasons, note: r.note);
  }
}

Future<NotForMeResult?> showNotForMeSheet(
  BuildContext context,
  int idx, {
  Set<String> initial = const {},
  String note = '',
  bool editing = false,
}) {
  final panel = ChangeNotifierProvider.value(
    value: context.read<AppState>(),
    child: NotForMePanel(
      idx: idx,
      initial: initial,
      note: note,
      editing: editing,
    ),
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<NotForMeResult>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 700),
          child: panel,
        ),
      ),
    );
  }
  return showModalBottomSheet<NotForMeResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => panel,
  );
}

class NotForMePanel extends StatefulWidget {
  final int idx;
  final Set<String> initial;
  final String note;
  final bool editing;
  const NotForMePanel({
    super.key,
    required this.idx,
    this.initial = const {},
    this.note = '',
    this.editing = false,
  });
  @override
  State<NotForMePanel> createState() => _NotForMePanelState();
}

class _NotForMePanelState extends State<NotForMePanel> {
  late final Set<String> picked = {...widget.initial};
  late final TextEditingController noteCtl = TextEditingController(
    text: widget.note,
  );

  @override
  void dispose() {
    noteCtl.dispose();
    super.dispose();
  }

  void toggle(String key) => setState(() {
    if (!picked.remove(key)) picked.add(key);
    if (!picked.contains(key) && key.startsWith('x:content_warnings|'))
      picked.remove('h:${key.substring(2)}');
  });

  NotForMeResult result({bool clear = false}) =>
      NotForMeResult(clear ? <String>{} : {...picked}, noteCtl.text);

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.data.titles[widget.idx];
    final ch = notForMeChoices(app, widget.idx);
    // keep reasons that were saved earlier even if they are not among the current top chips
    final shown = {
      for (final (k, _) in [...ch.tags, ...ch.aspects]) k,
    };
    final extra = [
      for (final r in picked)
        if ((r.startsWith('x:') || r.startsWith('n:')) && !shown.contains(r))
          (
            r,
            r.startsWith('n:')
                ? (genericReasonByKey(r.substring(2))?.label ?? r)
                : facetLabel(r.substring(2)),
          ),
    ];
    final warnings = [
      for (final r in picked)
        if (r.startsWith('x:content_warnings|')) r,
    ];

    Widget chips(List<(String, String)> items) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (k, label) in items)
          ReasonChip(
            key: ValueKey('nfm-$k'),
            label: label,
            state: picked.contains(k) ? 2 : 0,
            onTap: () => toggle(k),
          ),
      ],
    );

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What put you off?', style: Atlas.serif(size: 26)),
          const SizedBox(height: 4),
          Text(
            t.display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Atlas.muted),
          ),
          const SizedBox(height: 4),
          const Text(
            'Pick what you dislike. Only those parts get pushed down, not everything about this title.',
            style: TextStyle(color: Atlas.muted, fontSize: 13, height: 1.4),
          ),
          if (ch.tags.isNotEmpty || extra.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('IN THIS TITLE', style: Atlas.kicker),
            const SizedBox(height: 8),
            chips([...ch.tags, ...extra.where((e) => e.$1.startsWith('x:'))]),
          ],
          const SizedBox(height: 16),
          const Text('IN GENERAL', style: Atlas.kicker),
          const SizedBox(height: 8),
          chips([...ch.aspects, ...extra.where((e) => e.$1.startsWith('n:'))]),
          for (final w in warnings)
            CheckboxListTile(
              key: ValueKey('hide-$w'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: picked.contains('h:${w.substring(2)}'),
              onChanged: (v) => setState(
                () => v == true
                    ? picked.add('h:${w.substring(2)}')
                    : picked.remove('h:${w.substring(2)}'),
              ),
              title: Text(
                'Always hide titles with “${facetLabel(w.substring(2))}”',
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: noteCtl,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'Anything else? (optional)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('nfm-confirm'),
                onPressed: () => Navigator.pop(context, result()),
                child: Text(widget.editing ? 'Save' : 'Not for me'),
              ),
              if (!widget.editing)
                OutlinedButton(
                  key: const ValueKey('nfm-hide'),
                  onPressed: () => Navigator.pop(context, result(clear: true)),
                  child: const Text('Just hide it'),
                ),
              if (widget.editing) ...[
                OutlinedButton(
                  key: const ValueKey('nfm-clear'),
                  onPressed: () => Navigator.pop(context, result(clear: true)),
                  child: const Text('Clear reasons'),
                ),
                TextButton(
                  key: const ValueKey('nfm-back'),
                  onPressed: () => Navigator.pop(
                    context,
                    const NotForMeResult({}, '', bringBack: true),
                  ),
                  child: const Text('Bring it back'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// "kind|value" -> chip wording.
String facetLabel(String kindValue) {
  final p = kindValue.split('|');
  return p.length == 2 ? facetChipLabel(p[0], p[1]) : kindValue;
}

/// Plain-words list of the reasons on a skipped title, e.g. "slow-burn romance, pacing".
String skipReasonText(Set<String> reasons) {
  final out = <String>[];
  for (final r in reasons) {
    if (r.startsWith('n:')) {
      out.add(
        (genericReasonByKey(r.substring(2))?.label ?? r.substring(2))
            .toLowerCase(),
      );
    } else if (r.startsWith('x:')) {
      out.add(facetLabel(r.substring(2)).toLowerCase());
    }
  }
  return out.join(', ');
}
