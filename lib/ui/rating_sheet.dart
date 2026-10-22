import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/catalog_data.dart';
import '../engine/labels.dart';
import '../engine/recommender.dart';
import 'widgets.dart';

/// Opens the rating + "what I liked" editor (bottom sheet on phones, dialog on wide screens).
Future<void> showRatingSheet(BuildContext context, int idx) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  final panel = ChangeNotifierProvider.value(
    value: context.read<AppState>(),
    child: RatingPanel(idx: idx),
  );
  if (wide) {
    return showDialog(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: panel),
      ),
    );
  }
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => panel,
  );
}

const _specificKinds = {
  'romance_dynamics', 'relationship_dynamics', 'archetypes', 'narrative_devices', 'moods',
  'themes', 'ending_types', 'story_structures', 'setting_types', 'comedy_styles',
  'romance_payoffs', 'character_arc_types', 'appeal_factors',
};

/// Reason chips drawn from this title's own profile (themes, dynamics, archetypes, ending…).
List<(String key, String label)> specificReasonsFor(CatalogData c, int idx, {int max = 16}) {
  final cand = <(double, String, String)>[];
  for (final (fid, w) in c.facetsOf(idx)) {
    final f = c.vocab[fid];
    if (!_specificKinds.contains(f.kind) || w < 5.5) continue;
    cand.add((w * c.facetIdf[fid], '${f.kind}|${f.value}', facetChipLabel(f.kind, f.value)));
  }
  cand.sort((a, b) => b.$1.compareTo(a.$1));
  // keep at most 3 from a single kind for variety
  final perKind = <String, int>{};
  final out = <(String, String)>[];
  for (final (_, key, label) in cand) {
    final kind = key.split('|').first;
    if ((perKind[kind] ?? 0) >= 3) continue;
    perKind[kind] = (perKind[kind] ?? 0) + 1;
    out.add(('f:$key', label));
    if (out.length >= max) break;
  }
  return out;
}

class RatingPanel extends StatefulWidget {
  final int idx;
  const RatingPanel({super.key, required this.idx});
  @override
  State<RatingPanel> createState() => _RatingPanelState();
}

class _RatingPanelState extends State<RatingPanel> {
  late double rating;
  bool rated = true;
  late Set<String> reasons;
  late TextEditingController note;
  late List<(String, String)> specific;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final e = app.entryOf(widget.idx);
    rating = e?.rating ?? 8;
    rated = e == null ? true : (e.status != EntryStatus.watched || e.rating != null);
    reasons = {...(e?.reasons ?? <String>{})};
    note = TextEditingController(text: e?.note ?? '');
    specific = specificReasonsFor(app.data, widget.idx);
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.data.titles[widget.idx];
    final cs = Theme.of(context).colorScheme;
    final existing = app.entryOf(widget.idx);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Cover(t.cover, width: 56, height: 80, radius: 8),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.display, style: Theme.of(context).textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(metaLine(t), style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Text('Your rating', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (rated)
                Text(rating == rating.roundToDouble() ? rating.toInt().toString() : rating.toString(),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w800))
              else
                Text('not rated', style: TextStyle(color: cs.onSurfaceVariant)),
            ]),
            Slider(
              value: rating,
              min: 1,
              max: 10,
              divisions: 18,
              label: rating.toString(),
              onChanged: (v) => setState(() {
                rating = v;
                rated = true;
              }),
            ),
            const SizedBox(height: 6),
            Text('What did you like?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text('Tap anything that made this work for you — it directly shapes your recommendations.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final g in genericReasons)
                FilterChip(
                  label: Text(g.label),
                  selected: reasons.contains('g:${g.key}'),
                  onSelected: (v) => setState(() => v ? reasons.add('g:${g.key}') : reasons.remove('g:${g.key}')),
                ),
            ]),
            if (specific.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Specific to this show', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.primary)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final (key, label) in specific)
                  FilterChip(
                    label: Text(label),
                    selected: reasons.contains(key),
                    onSelected: (v) => setState(() => v ? reasons.add(key) : reasons.remove(key)),
                  ),
              ]),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Anything else? (optional note)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Row(children: [
            if (existing != null)
              TextButton.icon(
                onPressed: () {
                  app.remove(widget.idx);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
            TextButton(
              onPressed: () => setState(() => rated = false),
              child: const Text('Skip rating'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () {
                app.rate(widget.idx, rating: rated ? rating : null, reasons: reasons, note: note.text.trim());
                Navigator.pop(context);
              },
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ]),
        ),
      ]),
    );
  }
}
