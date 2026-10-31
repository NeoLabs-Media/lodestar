import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/catalog_data.dart';
import '../engine/labels.dart';
import '../engine/recommender.dart';
import 'theme.dart';
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: panel,
        ),
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
  'anilist_tag',
  'keyword',
  'content_warnings',
  'romance_dynamics',
  'relationship_dynamics',
  'archetypes',
  'narrative_devices',
  'moods',
  'themes',
  'ending_types',
  'story_structures',
  'setting_types',
  'comedy_styles',
  'romance_payoffs',
  'character_arc_types',
  'appeal_factors',
};

/// Reason chips drawn from this title's own profile (themes, dynamics, archetypes, ending…).
List<(String key, String label)> specificReasonsFor(
  CatalogData c,
  int idx, {
  int max = 20,
}) {
  final cand = <(double, String, String)>[];
  for (final (fid, w) in c.facetsOf(idx)) {
    final f = c.vocab[fid];
    if (!_specificKinds.contains(f.kind) || w < 5.5) continue;
    cand.add((
      w * c.facetIdf[fid],
      '${f.kind}|${f.value}',
      facetChipLabel(f.kind, f.value),
    ));
  }
  cand.sort((a, b) => b.$1.compareTo(a.$1));
  // keep at most 3 from a single kind for variety
  final perKind = <String, int>{};
  final out = <(String, String)>[];
  for (final (_, key, label) in cand) {
    final kind = key.split('|').first;
    if ((perKind[kind] ?? 0) >=
        (kind == 'anilist_tag' || kind == 'keyword' ? 4 : 3))
      continue;
    perKind[kind] = (perKind[kind] ?? 0) + 1;
    out.add(('f:$key', label));
    if (out.length >= max) break;
  }
  return out;
}

/// Reason keys: `g:<generic>` / `f:<kind>|<value>` = liked, `n:<generic>` / `x:<kind>|<value>` = disliked.
String _dislikeKey(String likeKey) =>
    (likeKey.startsWith('g:') ? 'n:' : 'x:') + likeKey.substring(2);

/// 0 = not set, 1 = liked, 2 = disliked.
int reasonState(Set<String> reasons, String likeKey) =>
    reasons.contains(likeKey)
    ? 1
    : (reasons.contains(_dislikeKey(likeKey)) ? 2 : 0);

/// none -> liked -> disliked -> none
void cycleReason(Set<String> reasons, String likeKey) {
  final dis = _dislikeKey(likeKey);
  if (reasons.contains(likeKey)) {
    reasons
      ..remove(likeKey)
      ..add(dis);
  } else if (reasons.contains(dis)) {
    reasons.remove(dis);
  } else {
    reasons.add(likeKey);
  }
}

/// Tri-state chip: tap once to like, again to dislike, again to clear.
class ReasonChip extends StatelessWidget {
  final String label;
  final int state;
  final VoidCallback onTap;
  const ReasonChip({
    super.key,
    required this.label,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const bad = Color(0xFFE08A7A);
    final liked = state == 1, disliked = state == 2;
    final color = disliked ? bad : (liked ? Atlas.accent : Atlas.bone);
    return Semantics(
      button: true,
      label:
          '$label, ${disliked
              ? 'disliked'
              : liked
              ? 'liked'
              : 'not set'}',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: disliked
                ? bad.withValues(alpha: .14)
                : (liked
                      ? Atlas.accent.withValues(alpha: .16)
                      : Colors.transparent),
            border: Border.all(
              color: disliked
                  ? bad.withValues(alpha: .7)
                  : (liked
                        ? Atlas.accent.withValues(alpha: .6)
                        : Atlas.bone.withValues(alpha: .16)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (liked || disliked) ...[
                Icon(
                  liked ? Icons.check_rounded : Icons.block_rounded,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                  decoration: disliked ? TextDecoration.lineThrough : null,
                  decorationColor: bad,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    rated = e == null
        ? true
        : (e.status != EntryStatus.watched || e.rating != null);
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Cover(t.cover, width: 56, height: 80, radius: 8),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.display,
                              style: Theme.of(context).textTheme.titleLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              metaLine(t),
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text(
                        'Your rating',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (rated)
                        Text(
                          rating == rating.roundToDouble()
                              ? rating.toInt().toString()
                              : rating.toString(),
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w800,
                              ),
                        )
                      else
                        Text(
                          'not rated',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                    ],
                  ),
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
                  Text(
                    'What did you like — or not?',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Tap once to like, twice to dislike (struck through), again to clear. Dislikes work even on a show you loved — they steer future picks away from that tag.',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final g in genericReasons)
                        ReasonChip(
                          label: g.label,
                          state: reasonState(reasons, 'g:${g.key}'),
                          onTap: () => setState(
                            () => cycleReason(reasons, 'g:${g.key}'),
                          ),
                        ),
                    ],
                  ),
                  if (specific.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Specific to this title',
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: cs.primary),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final (key, label) in specific)
                          ReasonChip(
                            label: label,
                            state: reasonState(reasons, key),
                            onTap: () =>
                                setState(() => cycleReason(reasons, key)),
                          ),
                      ],
                    ),
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
            child: Row(
              children: [
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
                    app.rate(
                      widget.idx,
                      rating: rated ? rating : null,
                      reasons: reasons,
                      note: note.text.trim(),
                    );
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
