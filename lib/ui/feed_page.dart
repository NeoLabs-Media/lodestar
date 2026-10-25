import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/categories.dart';
import '../engine/recommender.dart';
import 'detail_page.dart';
import 'filter_panel.dart';
import 'rating_sheet.dart';
import 'not_for_me.dart';
import 'theme.dart';
import 'widgets.dart';

class FeedPage extends StatelessWidget {
  final VoidCallback onGoLibrary;
  const FeedPage({super.key, required this.onGoLibrary});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final noSignal = app.ratedCount == 0 && app.entries.isEmpty;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pad = wide ? 56.0 : 20.0;
    final hero = app.feed.isEmpty ? null : app.feed.first;
    final rest = app.feed.length > 1 ? app.feed.sublist(1) : const <Rec>[];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(wide: wide, pad: pad),
        ),
        SliverToBoxAdapter(child: _CategoryStrip(pad: pad)),
        if (app.newTitlesNotice > 0)
          SliverToBoxAdapter(child: _NewTitlesNotice(pad: pad)),
        if (noSignal)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 22, pad, 0),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: Atlas.outline(radius: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: Atlas.accent,
                      size: 20,
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text(
                        'Tell me what you\'ve already watched — rate 5–10 titles and say why you liked them — '
                        'and I\'ll find what to watch next, including the obscure stuff.',
                        style: TextStyle(height: 1.45, color: Atlas.body),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: onGoLibrary,
                      child: const Text('Add titles'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (hero == null && app.computing)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (hero == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Nothing matches these filters.')),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: HeroCard(rec: hero, compact: !wide),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                pad,
                wide ? 44 : 28,
                pad,
                wide ? 26 : 16,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    'More for tonight',
                    style: Atlas.serif(size: wide ? 28 : 22),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    'DIVERSE ON PURPOSE',
                    style: Atlas.kicker.copyWith(
                      color: Atlas.faint,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 90),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: wide ? 290 : 220,
                mainAxisExtent: wide ? 570 : 475,
                mainAxisSpacing: wide ? 30 : 22,
                crossAxisSpacing: wide ? 28 : 14,
              ),
              itemCount: rest.length,
              itemBuilder: (_, i) => PosterCard(
                rec: rest[i],
                index: i + 2,
                key: ValueKey(rest[i].idx),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final bool wide;
  final double pad;
  const _Header({required this.wide, required this.pad});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final n = app.ratedCount;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, wide ? 42 : 22, pad, 0),
      child: Container(
        padding: EdgeInsets.only(bottom: wide ? 26 : 18),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Atlas.hair)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n > 0 ? 'TUNED ON $n TITLES' : 'GETTING TO KNOW YOU',
                    style: Atlas.kicker,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Picked for you',
                    style: Atlas.serif(size: wide ? 56 : 38, height: 1),
                  ),
                ],
              ),
            ),
            if (wide) ...[
              OutlinedButton(
                onPressed: () => showFilters(context),
                child: Text(
                  app.activeFilterCount > 0
                      ? 'Filters · ${app.activeFilterCount}'
                      : 'Filters',
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => _surprise(context),
                child: const Text('Surprise me'),
              ),
            ] else ...[
              _RoundIcon(
                Icons.casino_outlined,
                'Surprise me',
                filled: true,
                onTap: () => _surprise(context),
              ),
              const SizedBox(width: 8),
              _RoundIcon(
                app.activeFilterCount > 0 ? Icons.filter_alt : Icons.tune,
                'Filters (${app.activeFilterCount} active)',
                onTap: () => showFilters(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _surprise(BuildContext context) {
    final app = context.read<AppState>();
    final r = app.surprise();
    if (r == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: app,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SURPRISE PICK', style: Atlas.kicker),
              const SizedBox(height: 14),
              HeroCard(
                rec: r,
                compact: MediaQuery.sizeOf(context).width < 700,
                popOnAction: true,
                label: 'Off the beaten path',
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _surprise(context);
                  },
                  icon: const Icon(Icons.casino_outlined, size: 18),
                  label: const Text('Another one'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "N new titles" after a catalog update; dismissible.
class _NewTitlesNotice extends StatelessWidget {
  final double pad;
  const _NewTitlesNotice({required this.pad});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: Atlas.outline(radius: 12),
        child: Row(
          children: [
            const Icon(Icons.fiber_new_rounded, color: Atlas.accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${app.newTitlesNotice} new title${app.newTitlesNotice == 1 ? '' : 's'} added to the catalog',
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18),
              onPressed: app.dismissNewTitlesNotice,
            ),
          ],
        ),
      ),
    );
  }
}

/// One-tap broad categories (any-of); selection is saved with the other filters.
class _CategoryStrip extends StatelessWidget {
  final double pad;
  const _CategoryStrip({required this.pad});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = app.controls;
    return SizedBox(
      height: 62,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 14),
        children: [
          ...[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                showCheckmark: false,
                label: const Text('All media'),
                selected: c.kinds.isEmpty,
                onSelected: (_) {
                  c.kinds.clear();
                  app.setControls(c);
                },
              ),
            ),
            for (final k in mediaKinds)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: KindChip(
                  kind: k,
                  choice: true,
                  available: app.data.kinds.contains(k),
                  selected: c.kinds.length == 1 && c.kinds.contains(k),
                  onSelected: (_) {
                    c.kinds
                      ..clear()
                      ..add(k);
                    app.setControls(c);
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12, top: 6, bottom: 6),
              child: Container(width: 1, color: Atlas.hair),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('All'),
              selected: c.categories.isEmpty,
              onSelected: (_) {
                c.categories.clear();
                app.setControls(c);
              },
            ),
          ),
          for (final cat in categories.where(
            (k) => app.recommender.categoryCount(k.key, c.kinds) > 0,
          ))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(cat.label),
                selected: c.categories.contains(cat.key),
                onSelected: (v) {
                  v ? c.categories.add(cat.key) : c.categories.remove(cat.key);
                  app.setControls(c);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tip;
  final bool filled;
  final VoidCallback onTap;
  const _RoundIcon(
    this.icon,
    this.tip, {
    required this.onTap,
    this.filled = false,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: filled
            ? const BoxDecoration(shape: BoxShape.circle, color: Atlas.bone)
            : BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Atlas.bone.withValues(alpha: .22)),
              ),
        child: Icon(icon, size: 19, color: filled ? Atlas.ink : Atlas.bone),
      ),
    ),
  );
}

// ---------------------------------------------------------------- cards

class _Match extends StatelessWidget {
  final double match;
  final double size;
  const _Match(this.match, {required this.size});
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '${match.round()}',
        style: Atlas.serif(size: size, height: .9, color: Atlas.accent),
      ),
      Text(
        '%',
        style: TextStyle(fontSize: size * .24, color: Atlas.muted),
      ),
    ],
  );
}

class _TextAct extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool strong;
  final TextAlign align;
  const _TextAct(
    this.label,
    this.onTap, {
    this.strong = false,
    this.align = TextAlign.center,
  });
  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      hoverColor: Atlas.accent.withValues(alpha: .08),
      child: SizedBox(
        height: 40,
        child: Align(
          alignment: align == TextAlign.left
              ? Alignment.centerLeft
              : align == TextAlign.right
              ? Alignment.centerRight
              : Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                color: strong ? Atlas.bone : Atlas.muted,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The top pick: poster, big match numeral, serif title and the full explanation.
class HeroCard extends StatelessWidget {
  final Rec rec;
  final bool compact;
  final bool popOnAction;
  final String? label;
  const HeroCard({
    super.key,
    required this.rec,
    this.compact = false,
    this.popOnAction = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.data.titles[rec.idx];
    void done() {
      if (popOnAction) Navigator.pop(context);
    }

    final actions = Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton(
          onPressed: () {
            done();
            showRatingSheet(context, rec.idx);
          },
          child: const Text('I\'ve watched this'),
        ),
        OutlinedButton(
          onPressed: () {
            app.setStatus(rec.idx, EntryStatus.planned);
            done();
          },
          child: const Text('Plan to watch'),
        ),
        TextButton(
          onPressed: () {
            done();
            notForMe(context, rec.idx);
          },
          child: const Text('Not for me', style: TextStyle(color: Atlas.muted)),
        ),
        TextButton(
          onPressed: () {
            app.setStatus(rec.idx, EntryStatus.ignored);
            done();
          },
          child: const Text('Ignore', style: TextStyle(color: Atlas.muted)),
        ),
      ],
    );
    final why = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'WHY   ',
            style: TextStyle(
              fontFamily: 'Inter',
              fontStyle: FontStyle.normal,
              fontSize: 11,
              letterSpacing: 2,
              color: Atlas.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(text: rec.why),
        ],
      ),
      style: Atlas.serif(
        size: compact ? 15.5 : 18,
        height: 1.5,
        italic: true,
        color: const Color(0xFFE8E2D4),
      ),
    );
    final meta = Text(
      '${metaLine(t).replaceAll(' · ', '  ·  ')}${t.meanScore != null ? '  ·  ${(t.meanScore! / 10).toStringAsFixed(1)} avg' : ''}',
      style: TextStyle(
        fontSize: compact ? 12 : 13.5,
        color: Atlas.muted,
        letterSpacing: .3,
      ),
    );
    final poster = Hero(
      tag: 'cover${rec.idx}',
      child: Cover(
        t.cover,
        width: compact ? 112 : 250,
        height: compact ? 168 : 375,
        radius: 4,
      ),
    );
    final blurb = Text(
      t.oneliner.isNotEmpty ? t.oneliner : t.pitch,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 16.5, height: 1.6, color: Atlas.body),
    );
    return Card(
      margin: EdgeInsets.zero,
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(),
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => DetailPage(idx: rec.idx))),
        onLongPress: () => copyText(context, t.display),
        onSecondaryTap: () => copyText(context, t.display),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: compact ? 22 : 44),
          decoration: popOnAction
              ? null
              : const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Atlas.hair)),
                ),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        poster,
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (rec.match > 0) _Match(rec.match, size: 54),
                              const SizedBox(height: 10),
                              Text(
                                t.display,
                                style: Atlas.serif(size: 22, height: 1.1),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              meta,
                              if (rec.gem)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: GemBadge(
                                    'hidden gem · ${members(t.popularity)}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    why,
                    const SizedBox(height: 16),
                    actions,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    poster,
                    const SizedBox(width: 56),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 375),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                if (rec.match > 0) _Match(rec.match, size: 96),
                                const SizedBox(width: 14),
                                Flexible(
                                  child: Text(
                                    'MATCH  ·  ${(label ?? 'YOUR TOP PICK').toUpperCase()}${app.data.kinds.length > 1 ? '  ·  ${kindLabel(t.kind).toUpperCase()}' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Atlas.kicker,
                                  ),
                                ),
                                if (rec.gem) ...[
                                  const SizedBox(width: 14),
                                  GemBadge(
                                    'hidden gem · ${members(t.popularity)}',
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 18),
                            SelectableText(
                              t.display,
                              style: Atlas.serif(size: 42, height: 1.05),
                              maxLines: 2,
                            ),
                            const SizedBox(height: 10),
                            meta,
                            const SizedBox(height: 18),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 660),
                              child: blurb,
                            ),
                            const SizedBox(height: 18),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 660),
                              child: why,
                            ),
                            const SizedBox(height: 26),
                            actions,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Flat poster card: cover, index + match numeral, serif title, why-line, hairline text actions.
class PosterCard extends StatelessWidget {
  final Rec rec;
  final int index;
  const PosterCard({super.key, required this.rec, required this.index});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.data.titles[rec.idx];
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => DetailPage(idx: rec.idx))),
      onLongPress: () => copyText(context, t.display),
      onSecondaryTap: () => copyText(context, t.display),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: wide ? 300 : 230,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: 'cover${rec.idx}',
                  child: Cover(
                    t.cover,
                    width: double.infinity,
                    height: double.infinity,
                    radius: 4,
                  ),
                ),
                if (rec.gem)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: GemBadge('Hidden gem · ${members(t.popularity)}'),
                  ),
                if (app.data.kinds.length > 1)
                  Positioned(left: 10, top: 10, child: KindBadge(t.kind)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                index.toString().padLeft(2, '0'),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 2.2,
                  color: Atlas.faint,
                ),
              ),
              const Spacer(),
              _Match(rec.match, size: wide ? 24 : 19),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t.display,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Atlas.serif(size: wide ? 21 : 17, height: 1.15),
          ),
          const SizedBox(height: 4),
          Text(
            '${metaLine(t)}${t.meanScore != null ? ' · ${(t.meanScore! / 10).toStringAsFixed(1)}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Atlas.muted),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Text(
              rec.why,
              maxLines: wide ? 5 : 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.55,
                color: Color(0xFFA9A395),
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Atlas.hair)),
            ),
            child: Row(
              children: [
                _TextAct(
                  'Watched',
                  () => showRatingSheet(context, rec.idx),
                  strong: true,
                  align: TextAlign.left,
                ),
                _TextAct(
                  'Plan',
                  () => app.setStatus(rec.idx, EntryStatus.planned),
                ),
                _TextAct('Pass', () => notForMe(context, rec.idx)),
                _TextAct(
                  'Ignore',
                  () => app.setStatus(rec.idx, EntryStatus.ignored),
                  align: TextAlign.right,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
