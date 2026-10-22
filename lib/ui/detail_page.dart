import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/catalog_data.dart';
import '../engine/labels.dart';
import '../engine/recommender.dart';
import 'rating_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

class DetailPage extends StatefulWidget {
  final int idx;
  const DetailPage({super.key, required this.idx});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  bool spoilers = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = app.data;
    final t = c.titles[widget.idx];
    final d = app.detail(widget.idx);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final entry = app.entryOf(widget.idx);
    final why = app.explainFor(widget.idx);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    Widget head = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Hero(tag: 'cover${widget.idx}', child: Cover(t.cover, width: wide ? 180 : 120, height: wide ? 260 : 175, radius: 14)),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(t.display, style: Atlas.serif(size: 34, height: 1.1)),
          if (t.titleEn != null && t.titleEn != t.title)
            SelectableText(t.title, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text(metaLine(t) + (d['dur'] != null ? ' · ${d['dur']} min' : ''),
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (t.meanScore != null)
              Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.star_rounded, size: 16, color: Colors.amber.shade600),
                  label: Text('${(t.meanScore! / 10).toStringAsFixed(1)} avg')),
            Chip(visualDensity: VisualDensity.compact, label: Text('${members(t.popularity)} members')),
            if (t.ending != null) Chip(visualDensity: VisualDensity.compact, label: Text('${t.ending} ending')),
            if (t.tier == 'deep') Chip(visualDensity: VisualDensity.compact, label: const Text('deep profile')),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final g in t.genres.take(6))
              Text(g, style: TextStyle(color: cs.primary, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    ]);

    final overview = <Widget>[
      if (why != null && app.model?.hasSignal == true)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Why you might like it: ', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
            TextSpan(text: why.why),
          ])),
        ),
      _Section(
        title: 'Premise',
        trailing: FilterChip(
          label: const Text('Spoilers'),
          avatar: Icon(spoilers ? Icons.visibility : Icons.visibility_off, size: 16),
          selected: spoilers,
          onSelected: (v) => setState(() => spoilers = v),
        ),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((d['sf'] as String?)?.isNotEmpty == true ? d['sf'] : t.pitch, style: const TextStyle(height: 1.4)),
            if (spoilers) ...[
              const SizedBox(height: 12),
              Text('Full story', style: tt.labelLarge?.copyWith(color: cs.error)),
              const SizedBox(height: 4),
              Text(d['full'] ?? '', style: const TextStyle(height: 1.4)),
              if ((d['endd'] as String?)?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text('Ending: ${d['endd']}', style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
              ],
            ] else if (t.ending != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Ending type: ${t.ending}', style: TextStyle(color: cs.onSurfaceVariant)),
              ),
          ]),
        ),
      ),
      if ((d['love'] as List?)?.isNotEmpty == true || (d['hate'] as List?)?.isNotEmpty == true)
        _Section(
          title: 'Is it for you?',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in (d['love'] as List? ?? []).cast<String>().take(2))
              _Bullet(Icons.thumb_up_alt_outlined, 'You\'ll love it if $s', const Color(0xFF9ED8B5)),
            for (final s in (d['hate'] as List? ?? []).cast<String>().take(2))
              _Bullet(Icons.thumb_down_alt_outlined, 'Skip it if $s', cs.error),
          ]),
        ),
      if ((d['cw'] as List?)?.isNotEmpty == true)
        _Section(
          title: 'Content warnings',
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final w in (d['cw'] as List).cast<String>())
              Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.warning_amber_rounded, size: 16),
                  label: Text(w)),
          ]),
        ),
      _Section(title: 'Franchise', child: _Franchise(idx: widget.idx, watchNote: d['watch'] as String?)),
    ];

    final deep = <Widget>[
      _Section(title: 'Profile', child: _DimView(idx: widget.idx)),
      if ((d['chars'] as List?)?.isNotEmpty == true)
        _Section(
          title: 'Characters',
          child: Column(children: [
            for (final ch in (d['chars'] as List).cast<Map<String, dynamic>>().take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 16, backgroundColor: cs.primaryContainer, child: Text('${ch['n']}'.substring(0, 1))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(text: '${ch['n']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: '  ${(ch['a'] as List? ?? []).join(' · ')}', style: TextStyle(color: cs.primary, fontSize: 12.5)),
                      ])),
                      Text('${ch['m'] ?? ''}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, height: 1.3)),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
      if ((d['rels'] as List?)?.isNotEmpty == true)
        _Section(
          title: 'Key relationships',
          child: Column(children: [
            for (final r in (d['rels'] as List).cast<Map<String, dynamic>>())
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (r['rom'] == true) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.favorite, size: 14, color: Colors.pinkAccent)),
                    Expanded(child: Text('${r['a']} & ${r['b']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
                  Text([...(r['t'] as List? ?? []), ...(r['d'] as List? ?? [])].join(' · '),
                      style: TextStyle(color: cs.primary, fontSize: 12.5)),
                  if ((r['e'] as String?)?.isNotEmpty == true)
                    Text(r['e'], style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, height: 1.3)),
                ]),
              ),
          ]),
        ),
      if ((d['sim'] as List?)?.isNotEmpty == true) _Section(title: 'Similar titles', child: _Similar(sim: (d['sim'] as List).cast<Map<String, dynamic>>())),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(t.display, overflow: TextOverflow.ellipsis),
        actions: [IconButton(tooltip: 'Copy title', icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => copyText(context, copyableTitle(t)))],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => showRatingSheet(context, widget.idx),
                icon: Icon(entry?.status == EntryStatus.watched ? Icons.edit : Icons.check_circle_outline),
                label: Text(entry?.status == EntryStatus.watched
                    ? 'Watched${entry?.rating != null ? ' · ${entry!.rating}' : ''} — edit'
                    : 'I\'ve watched this'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Plan to watch',
              onPressed: () => app.setStatus(widget.idx, EntryStatus.planned),
              icon: Icon(entry?.status == EntryStatus.planned ? Icons.bookmark : Icons.bookmark_add_outlined),
            ),
            IconButton.filledTonal(
              tooltip: 'Ignore (hide, no taste signal)',
              onPressed: () {
                app.setStatus(widget.idx, EntryStatus.ignored);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.visibility_off_outlined),
            ),
            IconButton.filledTonal(
              tooltip: 'Not interested',
              onPressed: () {
                app.setStatus(widget.idx, EntryStatus.notInterested);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.thumb_down_outlined),
            ),
          ]),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              head,
              const SizedBox(height: 16),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(children: overview)),
                  const SizedBox(width: 24),
                  Expanded(child: Column(children: deep)),
                ])
              else ...[...overview, ...deep],
            ]),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Section({required this.title, required this.child, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Bullet(this.icon, this.text, this.color);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(height: 1.3))),
        ]),
      );
}

class _Franchise extends StatelessWidget {
  final int idx;
  final String? watchNote;
  const _Franchise({required this.idx, this.watchNote});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final c = app.data;
    final rel = c.relations[idx].where((r) => const {'PREQUEL', 'SEQUEL', 'PARENT', 'SIDE_STORY', 'SPIN_OFF', 'ALTERNATIVE', 'SUMMARY', 'FULL_STORY'}.contains(r.$2)).toList();
    final cs = Theme.of(context).colorScheme;
    if (rel.isEmpty && (watchNote == null || watchNote!.isEmpty)) {
      return Text('Standalone as far as the catalog knows.', style: TextStyle(color: cs.onSurfaceVariant));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (watchNote != null && watchNote!.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(watchNote!, style: const TextStyle(height: 1.35))),
      for (final (o, type) in rel)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Cover(c.titles[o].cover, width: 32, height: 46, radius: 6),
          title: Text(c.titles[o].display, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${type.toLowerCase().replaceAll('_', ' ')} · ${metaLine(c.titles[o])}'),
          trailing: app.entryOf(o)?.status == EntryStatus.watched ? const Icon(Icons.check_circle, size: 18, color: Color(0xFF9ED8B5)) : null,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(idx: o))),
        ),
    ]);
  }
}

class _Similar extends StatelessWidget {
  final List<Map<String, dynamic>> sim;
  const _Similar({required this.sim});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final cs = Theme.of(context).colorScheme;
    // resolve names against the catalog
    final resolved = <(String, String, int?)>[];
    for (final s in sim) {
      final name = '${s['t']}';
      final hits = app.search.search(name, limit: 1);
      final idx = (hits.isNotEmpty && hits.first.raw >= 90 - 1) ? hits.first.idx : null;
      resolved.add((name, '${s['w']}', idx));
    }
    return Column(children: [
      for (final (name, why, idx) in resolved)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: idx == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(idx: idx))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (idx != null) Padding(padding: const EdgeInsets.only(right: 10), child: Cover(app.data.titles[idx].cover, width: 36, height: 52, radius: 6)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(name, style: TextStyle(fontWeight: FontWeight.w700, color: idx != null ? cs.primary : null))),
                    if (idx != null && app.entryOf(idx)?.status == EntryStatus.watched)
                      const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.check_circle, size: 14, color: Color(0xFF9ED8B5))),
                  ]),
                  Text(why, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.3)),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

class _DimView extends StatelessWidget {
  final int idx;
  const _DimView({required this.idx});
  @override
  Widget build(BuildContext context) {
    final c = context.read<AppState>().data;
    final cs = Theme.of(context).colorScheme;
    final D = CatalogData.dimCount;
    // the dimensions in which this title is most distinctive
    final order = List<int>.generate(D, (i) => i)
      ..sort((a, b) => c.dimZ[idx * D + b].abs().compareTo(c.dimZ[idx * D + a].abs()));
    final top = order.take(8).toList();
    final radarVals = [for (final d in top) c.dim(idx, d) / 10];
    final radarLabels = [for (final d in top) dimTitle(c.dimNames[d])];
    return Column(children: [
      SizedBox(
        height: 250,
        child: CustomPaint(
          painter: _RadarPainter(radarVals, radarLabels, cs.primary, cs.outlineVariant, cs.onSurfaceVariant),
          size: Size.infinite,
        ),
      ),
      const SizedBox(height: 8),
      for (final d in order.take(12))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 150, child: Text(dimTitle(c.dimNames[d]), style: const TextStyle(fontSize: 12.5))),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: c.dim(idx, d) / 10,
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            SizedBox(width: 34, child: Text(c.dim(idx, d).toStringAsFixed(1), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
          ]),
        ),
    ]);
  }
}

class _RadarPainter extends CustomPainter {
  final List<double> vals;
  final List<String> labels;
  final Color fill, grid, text;
  _RadarPainter(this.vals, this.labels, this.fill, this.grid, this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - 42;
    final n = vals.length;
    Offset pt(int i, double f) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      return center + Offset(math.cos(a), math.sin(a)) * (r * f);
    }

    final gridPaint = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke;
    for (final f in [.25, .5, .75, 1.0]) {
      final path = Path()..moveTo(pt(0, f).dx, pt(0, f).dy);
      for (var i = 1; i < n; i++) {
        path.lineTo(pt(i, f).dx, pt(i, f).dy);
      }
      canvas.drawPath(path..close(), gridPaint);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(center, pt(i, 1), gridPaint);
    }
    final poly = Path()..moveTo(pt(0, vals[0]).dx, pt(0, vals[0]).dy);
    for (var i = 1; i < n; i++) {
      poly.lineTo(pt(i, vals[i]).dx, pt(i, vals[i]).dy);
    }
    poly.close();
    canvas.drawPath(poly, Paint()..color = fill.withValues(alpha: .28));
    canvas.drawPath(poly, Paint()..color = fill..style = PaintingStyle.stroke..strokeWidth = 2);
    for (var i = 0; i < n; i++) {
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: TextStyle(fontSize: 11, color: text)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 110);
      final p = pt(i, 1.0) + (pt(i, 1.0) - center) / r * 14;
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => old.vals != vals;
}
