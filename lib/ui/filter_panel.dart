import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/categories.dart';
import '../engine/recommender.dart';
import 'theme.dart';
import 'widgets.dart';

/// Opens the filter sheet. By default it edits the For-you feed's filters; the assistant passes its own
/// [controls] (and a save callback) so the same sheet edits the chat's filters instead.
Future<void> showFilters(
  BuildContext context, {
  Controls? controls,
  void Function(Controls)? onChanged,
  String title = 'Filters',
}) {
  final app = context.read<AppState>();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: app,
      child: FilterPanel(
        controls: controls,
        onChanged: onChanged,
        title: title,
      ),
    ),
  );
}

const _kindNames = {'anime': 'Anime', 'movie': 'Movies', 'tv': 'TV'};

/// Filter sheet whose sections depend on the selected media kind: common filters for "All", plus the
/// kind's own filters (anime: format/episodes/studio/source, movies: runtime/decade/director/…,
/// TV: seasons/status/network/…). Each kind remembers its own choices.
class FilterPanel extends StatelessWidget {
  final Controls? controls;
  final void Function(Controls)? onChanged;
  final String title;
  const FilterPanel({
    super.key,
    this.controls,
    this.onChanged,
    this.title = 'Filters',
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = controls ?? app.controls;
    void save(Controls x) =>
        onChanged != null ? onChanged!(x) : app.setControls(x);
    final d = app.data;
    final cs = Theme.of(context).colorScheme;
    final scope = c.scope;
    final f = c.active;
    // data options come from the selected kind(s) only
    final kinds = c.kinds;
    Map<String, int> opts(String field) => d.optionCounts(field, kinds);
    // a filter is only offered when the catalog really has data for it (>= 5 % of the selected titles, at least 10)
    final total = d.idsOfKinds(kinds).length;
    bool has(String field) =>
        d.countWith(field, kinds) >= (total * 0.05).clamp(10, 1e9);
    void upd(void Function() fn) {
      fn();
      save(c);
    }

    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: cs.primary),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );

    Widget chips<T>(
      Iterable<T> values,
      String Function(T) label,
      bool Function(T) selected,
      void Function(T, bool) on,
    ) => Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final v in values)
          FilterChip(
            label: Text(label(v)),
            selected: selected(v),
            onSelected: (s) => upd(() => on(v, s)),
          ),
      ],
    );

    Widget picker(String title, String field, Set<String> selected) {
      final o = opts(field);
      if (o.isEmpty) return const SizedBox.shrink();
      return section(
        title,
        OptionPicker(counts: o, selected: selected, onChanged: () => save(c)),
      );
    }

    Widget rangeSection(
      String title,
      String field, {
      required int? lo,
      required int? hi,
      required void Function(int?, int?) set,
      String unit = '',
      num? floor,
      num? ceil,
    }) {
      final r = d.numericRange(field, kinds);
      if (r == null) return const SizedBox.shrink();
      final min = (floor ?? r.$1).toDouble(), max = (ceil ?? r.$2).toDouble();
      if (max <= min) return const SizedBox.shrink();
      final cur = RangeValues(
        (lo ?? min).clamp(min, max).toDouble(),
        (hi ?? max).clamp(min, max).toDouble(),
      );
      final on = lo != null || hi != null;
      return section(
        '$title${on ? ' · ${lo ?? min.round()}–${hi ?? max.round()}$unit' : ''}',
        Row(
          children: [
            Expanded(
              child: RangeSlider(
                values: cur,
                min: min,
                max: max,
                divisions: (max - min).round().clamp(1, 120),
                onChanged: (v) => upd(
                  () => set(
                    v.start.round() <= min ? null : v.start.round(),
                    v.end.round() >= max ? null : v.end.round(),
                  ),
                ),
              ),
            ),
            if (on)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => upd(() => set(null, null)),
              ),
          ],
        ),
      );
    }

    final moods =
        (opts('mood').entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(18)
            .map((e) => e.key)
            .toList();
    final warns =
        (opts('warning').entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(16)
            .map((e) => e.key)
            .toList();
    final cats = categories
        .where((k) => app.recommender.categoryCount(k.key, kinds) > 0)
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (scope != 'all') ...[
                const SizedBox(width: 10),
                Chip(
                  label: Text(_kindNames[scope] ?? scope),
                  visualDensity: VisualDensity.compact,
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: () => upd(() => c.active.clear()),
                child: Text(
                  scope == 'all' ? 'Reset' : 'Reset ${_kindNames[scope]}',
                ),
              ),
            ],
          ),
          section(
            'Discovery',
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Popular picks')),
                ButtonSegment(value: 1, label: Text('Balanced')),
                ButtonSegment(value: 2, label: Text('Deep cuts')),
              ],
              selected: {
                c.obscurity < .25
                    ? 0
                    : c.obscurity > .7
                    ? 2
                    : 1,
              },
              onSelectionChanged: (s) {
                c.obscurity = const [0.08, 0.45, 0.92][s.first];
                save(c);
              },
            ),
          ),
          section(
            'Media',
            Wrap(
              spacing: 8,
              children: [
                for (final k in mediaKinds)
                  KindChip(
                    kind: k,
                    available: d.kinds.contains(k),
                    selected: c.kinds.contains(k),
                    onSelected: (v) =>
                        upd(() => v ? c.kinds.add(k) : c.kinds.remove(k)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              d.kinds.length < 3
                  ? 'Greyed-out types are not in your catalog yet. Update the catalog (Settings → Catalog) to get them.'
                  : scope == 'all'
                  ? 'Pick a single media type to see its own filters. Each type remembers its choices.'
                  : 'Showing ${_kindNames[scope]} filters. Other types keep their own settings.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),

          // ---------- common ----------
          if (cats.isNotEmpty)
            section(
              'Category (any of)',
              chips(
                cats,
                (k) => k.label,
                (k) => f.categories.contains(k.key),
                (k, s) =>
                    s ? f.categories.add(k.key) : f.categories.remove(k.key),
              ),
            ),
          if (moods.isNotEmpty)
            section(
              'Mood (any of)',
              chips(
                moods,
                (m) => m,
                f.moods.contains,
                (m, s) => s ? f.moods.add(m) : f.moods.remove(m),
              ),
            ),
          if (warns.isNotEmpty)
            section(
              'Exclude content',
              chips(
                warns,
                (w) => w,
                f.excludeWarnings.contains,
                (w, s) =>
                    s ? f.excludeWarnings.add(w) : f.excludeWarnings.remove(w),
              ),
            ),
          rangeSection(
            'Year',
            'year',
            lo: f.yearMin,
            hi: f.yearMax,
            set: (a, b) {
              f.yearMin = a;
              f.yearMax = b;
            },
          ),
          if (has('score'))
            section(
              f.minScore == null
                  ? 'Minimum score'
                  : 'Minimum score · ${f.minScore!.toStringAsFixed(1)}',
              Slider(
                value: f.minScore ?? 0,
                min: 0,
                max: 9,
                divisions: 18,
                onChanged: (v) => upd(() => f.minScore = v < 0.5 ? null : v),
              ),
            ),

          // ---------- anime ----------
          if (scope == 'anime') ...[
            section(
              'Format',
              chips(
                const ['TV', 'MOVIE', 'OVA', 'SHORT'],
                (x) => {
                  'TV': 'TV',
                  'MOVIE': 'Movie',
                  'OVA': 'OVA / ONA / Special',
                  'SHORT': 'Short',
                }[x]!,
                f.formats.contains,
                (x, s) => s ? f.formats.add(x) : f.formats.remove(x),
              ),
            ),
            section(
              'Max episodes',
              chips<int?>(
                const [null, 13, 26, 52, 100],
                (n) => n == null ? 'Any' : '≤ $n',
                (n) => f.maxEpisodes == n,
                (n, s) => f.maxEpisodes = n,
              ),
            ),
            if (has('studio')) picker('Studio', 'studio', f.studios),
            if (has('source')) picker('Source material', 'source', f.sources),
          ],

          // ---------- movies ----------
          if (scope == 'movie') ...[
            if (has('runtime'))
              rangeSection(
                'Runtime',
                'runtime',
                lo: f.runtimeMin,
                hi: f.runtimeMax,
                unit: ' min',
                floor: 60,
                ceil: 210,
                set: (a, b) {
                  f.runtimeMin = a;
                  f.runtimeMax = b;
                },
              ),
            if (opts('decade').isNotEmpty)
              section(
                'Decade',
                chips(
                  (opts('decade').keys.toList()..sort()).reversed,
                  (x) => x,
                  f.decades.contains,
                  (x, s) => s ? f.decades.add(x) : f.decades.remove(x),
                ),
              ),
            if (has('country')) picker('Country', 'country', f.countries),
            if (has('language')) picker('Language', 'language', f.languages),
            if (has('rating')) picker('Content rating', 'rating', f.ratings),
            if (has('director')) picker('Director', 'director', f.directors),
          ],

          // ---------- TV ----------
          if (scope == 'tv') ...[
            if (has('seasons'))
              section(
                'Max seasons',
                chips<int?>(
                  const [null, 1, 2, 3, 5],
                  (n) => n == null ? 'Any' : '≤ $n',
                  (n) => f.maxSeasons == n,
                  (n, s) => f.maxSeasons = n,
                ),
              ),
            if (opts('status').isNotEmpty)
              section(
                'Status',
                chips(
                  opts('status').keys.toList()..sort(),
                  (x) => x[0].toUpperCase() + x.substring(1),
                  f.statuses.contains,
                  (x, s) => s ? f.statuses.add(x) : f.statuses.remove(x),
                ),
              ),
            if (has('country')) picker('Country', 'country', f.countries),
            if (has('language')) picker('Language', 'language', f.languages),
            if (has('rating')) picker('Content rating', 'rating', f.ratings),
            if (has('creator'))
              picker('Creator / network', 'creator', f.creators),
          ],
        ],
      ),
    );
  }
}

/// Top options as chips, plus a searchable "More…" list when there are many (studios, directors…).
class OptionPicker extends StatefulWidget {
  final Map<String, int> counts;
  final Set<String> selected;
  final VoidCallback onChanged;
  const OptionPicker({
    super.key,
    required this.counts,
    required this.selected,
    required this.onChanged,
  });
  @override
  State<OptionPicker> createState() => _OptionPickerState();
}

class _OptionPickerState extends State<OptionPicker> {
  static const shown = 14;

  @override
  Widget build(BuildContext context) {
    final sorted = widget.counts.entries.toList()
      ..sort(
        (a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key),
      );
    // selected values always stay visible
    final top = <String>[
      ...widget.selected,
      ...sorted
          .map((e) => e.key)
          .where((k) => !widget.selected.contains(k))
          .take(shown),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final v in top)
          FilterChip(
            label: Text(v),
            selected: widget.selected.contains(v),
            onSelected: (s) {
              setState(
                () => s ? widget.selected.add(v) : widget.selected.remove(v),
              );
              widget.onChanged();
            },
          ),
        if (sorted.length > shown)
          ActionChip(
            avatar: const Icon(Icons.search, size: 16),
            label: Text('More (${sorted.length})'),
            onPressed: () => _more(context, sorted),
          ),
      ],
    );
  }

  Future<void> _more(
    BuildContext context,
    List<MapEntry<String, int>> sorted,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MoreDialog(
        sorted: sorted,
        selected: widget.selected,
        onChanged: () {
          setState(() {});
          widget.onChanged();
        },
      ),
    );
  }
}

class _MoreDialog extends StatefulWidget {
  final List<MapEntry<String, int>> sorted;
  final Set<String> selected;
  final VoidCallback onChanged;
  const _MoreDialog({
    required this.sorted,
    required this.selected,
    required this.onChanged,
  });
  @override
  State<_MoreDialog> createState() => _MoreDialogState();
}

class _MoreDialogState extends State<_MoreDialog> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.sorted
        .where((e) => e.key.toLowerCase().contains(q.toLowerCase()))
        .take(80)
        .toList();
    return AlertDialog(
      title: TextField(
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search…',
          prefixIcon: Icon(Icons.search),
          isDense: true,
        ),
        onChanged: (v) => setState(() => q = v),
      ),
      content: SizedBox(
        width: 380,
        height: 380,
        child: ListView(
          children: [
            for (final e in list)
              CheckboxListTile(
                dense: true,
                value: widget.selected.contains(e.key),
                title: Text(e.key),
                secondary: Text(
                  '${e.value}',
                  style: const TextStyle(color: Atlas.muted),
                ),
                onChanged: (v) {
                  setState(
                    () => v == true
                        ? widget.selected.add(e.key)
                        : widget.selected.remove(e.key),
                  );
                  widget.onChanged();
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
