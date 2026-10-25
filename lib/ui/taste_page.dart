import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/labels.dart';
import '../engine/recommender.dart';
import 'improve_flow.dart';

class TastePage extends StatelessWidget {
  const TastePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = app.summary();
    return CustomScrollView(
      slivers: [
        const SliverAppBar(
          floating: true,
          snap: true,
          title: Text('Your taste'),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                child: s.rated == 0
                    ? Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'Rate a few titles and this page will explain, in plain words, what you reward and what you avoid.',
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                          ),
                          const TasteLayerCard(),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _headline(context, s),
                          if (s.likes.isNotEmpty) ...[
                            _h(context, 'What you reward'),
                            for (final d in s.likes) _DimBar(d, positive: true),
                          ],
                          if (s.avoids.isNotEmpty) ...[
                            _h(context, 'What you avoid'),
                            for (final d in s.avoids)
                              _DimBar(d, positive: false),
                          ],
                          if (s.facetLikes.isNotEmpty) ...[
                            _h(
                              context,
                              'Specific things that keep coming up in your favourites',
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final f in _dedupe(s.facetLikes))
                                  Chip(
                                    avatar: const Icon(
                                      Icons.favorite,
                                      size: 14,
                                      color: Color(0xFF9ED8B5),
                                    ),
                                    label: Text(
                                      facetChipLabel(f.kind, f.value),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (s.facetAvoids.isNotEmpty) ...[
                            _h(context, 'Things that sink a show for you'),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final f in _dedupe(s.facetAvoids))
                                  Chip(
                                    avatar: Icon(
                                      Icons.heart_broken,
                                      size: 14,
                                      color: cs.error,
                                    ),
                                    label: Text(
                                      facetChipLabel(f.kind, f.value),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (s.dislikedTags.isNotEmpty ||
                              s.dislikedAspects.isNotEmpty) ...[
                            _h(context, 'Tags you flagged as dislikes'),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final f in s.dislikedTags)
                                  Chip(
                                    avatar: Icon(
                                      Icons.block_rounded,
                                      size: 14,
                                      color: cs.error,
                                    ),
                                    label: Text(
                                      facetChipLabel(f.kind, f.value),
                                    ),
                                  ),
                                for (final a in s.dislikedAspects)
                                  Chip(
                                    avatar: Icon(
                                      Icons.block_rounded,
                                      size: 14,
                                      color: cs.error,
                                    ),
                                    label: Text(a),
                                  ),
                              ],
                            ),
                          ],
                          if (s.reasonCounts.isNotEmpty) ...[
                            _h(context, 'What you say you like most'),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final e
                                    in (s.reasonCounts.entries.toList()..sort(
                                          (a, b) => b.value.compareTo(a.value),
                                        ))
                                        .take(14))
                                  Chip(label: Text('${e.key} × ${e.value}')),
                              ],
                            ),
                          ],
                          const TasteLayerCard(),
                          const SizedBox(height: 24),
                          Text(
                            'Model: ${app.model!.nSignals} signals → ${app.model!.nSignals < 8
                                ? 'centroid weights (cold start)'
                                : app.model!.nSignals < 18
                                ? 'blend of centroid and ridge regression'
                                : 'ridge regression over dimensions + facets'} · catalog: ${app.catalogInfo}',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<FacetPref> _dedupe(List<FacetPref> l) {
    final seen = <String>{};
    return [
      for (final f in l)
        if (seen.add(facetChipLabel(f.kind, f.value))) f,
    ];
  }

  Widget _h(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 8),
    child: Text(
      t,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  Widget _headline(BuildContext context, TasteSummary s) {
    final cs = Theme.of(context).colorScheme;
    String phrase(List<DimPref> l, bool pos) {
      final p = <String>[];
      for (final d in l.take(3)) {
        final ph = dimPhrases[d.name];
        if (ph != null) p.add(ph.$1);
      }
      return p.isEmpty
          ? ''
          : p.length == 1
          ? p.first
          : '${p.sublist(0, p.length - 1).join(', ')} and ${p.last}';
    }

    final likes = phrase(s.likes, true), avoids = phrase(s.avoids, false);
    final b = StringBuffer(
      'Across ${s.rated} titles you rate (avg ${s.meanRating.toStringAsFixed(1)}), ',
    );
    if (likes.isNotEmpty) b.write('you are drawn to $likes');
    if (likes.isNotEmpty && avoids.isNotEmpty)
      b.write(', and you steer away from ');
    if (likes.isEmpty && avoids.isNotEmpty) b.write('you steer away from ');
    if (avoids.isNotEmpty) b.write(avoids);
    b.write('.');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.surfaceContainerHigh],
        ),
      ),
      child: Text(
        b.toString(),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.4),
      ),
    );
  }
}

class _DimBar extends StatelessWidget {
  final DimPref d;
  final bool positive;
  const _DimBar(this.d, {required this.positive});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mag = (d.z.abs() / 2.0).clamp(0.05, 1.0);
    final ph = dimPhrases[d.name];
    final color = positive ? const Color(0xFF9ED8B5) : cs.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text(
              dimTitle(d.name) + (ph != null ? '' : ''),
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: mag,
                minHeight: 10,
                color: color,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
          ),
          SizedBox(
            width: 76,
            child: Text(
              positive
                  ? 'avg ${d.likedAvg.toStringAsFixed(1)}/10'
                  : 'avg ${d.likedAvg.toStringAsFixed(1)}/10',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
