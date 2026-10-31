import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../engine/labels.dart';
import 'rating_sheet.dart';
import 'widgets.dart';

/// Guided pass through every watched-but-unrated title (e.g. right after a Crunchyroll import):
/// one title per screen, tap a number, tap what you liked, Enter for next. Progress is saved
/// per title, so the tour can be left and resumed any time.
class RatingTourPage extends StatefulWidget {
  const RatingTourPage({super.key});
  @override
  State<RatingTourPage> createState() => _RatingTourPageState();
}

class _RatingTourPageState extends State<RatingTourPage> {
  late final List<int> queue;
  int pos = 0;
  int ratedInTour = 0;
  double? rating;
  bool half = false;
  Set<String> reasons = {};
  List<(String, String)> specific = [];
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    queue = app.unratedWatched();
    _load();
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void _load() {
    if (pos >= queue.length) return;
    final app = context.read<AppState>();
    final e = app.entryOf(queue[pos]);
    rating = e?.rating;
    half = rating != null && rating != rating!.roundToDouble();
    reasons = {...(e?.reasons ?? <String>{})};
    specific = specificReasonsFor(app.data, queue[pos], max: 12);
  }

  void _finish() {
    context.read<AppState>().recomputeNow();
    Navigator.pop(context);
  }

  void _next({bool save = true}) {
    final app = context.read<AppState>();
    if (save && rating != null) {
      app.rate(queue[pos], rating: rating, reasons: reasons, recompute: false);
      ratedInTour++;
    }
    setState(() {
      pos++;
      _load();
    });
    if (pos >= queue.length) app.recomputeNow();
  }

  void _setRating(int n) =>
      setState(() => rating = (half && n < 10) ? n + 0.5 : n.toDouble());

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (queue.isEmpty || pos >= queue.length) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rating tour')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.celebration_outlined, size: 56, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  queue.isEmpty
                      ? 'Nothing left to rate'
                      : 'All done — rated $ratedInTour titles',
                  style: tt.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your recommendations are being updated with everything you just told me.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _finish,
                  child: const Text('See my recommendations'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final idx = queue[pos];
    final t = app.data.titles[idx];
    final wide = MediaQuery.sizeOf(context).width >= 800;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          t.display,
          style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(metaLine(t), style: TextStyle(color: cs.onSurfaceVariant)),
        if (app.importHints[idx] != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.history, size: 16),
              label: Text(app.importHints[idx]!),
            ),
          ),
        const SizedBox(height: 10),
        Text(
          t.oneliner.isNotEmpty ? t.oneliner : t.pitch,
          style: const TextStyle(height: 1.4),
        ),
      ],
    );

    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Your rating', style: tt.titleMedium),
            const Spacer(),
            FilterChip(
              label: const Text('+ ½'),
              selected: half,
              onSelected: (v) => setState(() {
                half = v;
                if (rating != null) {
                  final base = rating!.floor();
                  rating = (v && base < 10) ? base + 0.5 : base.toDouble();
                }
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var n = 1; n <= 10; n++)
              ChoiceChip(
                showCheckmark: false,
                label: SizedBox(
                  width: 22,
                  child: Center(
                    child: Text(
                      '$n',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                selected: rating != null && rating!.floor() == n,
                onSelected: (_) => _setRating(n),
              ),
          ],
        ),
        if (rating != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '= $rating / 10',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'What did you like — or not? (tap once = like, twice = dislike)',
          style: tt.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final g in genericReasons)
              ReasonChip(
                label: g.label,
                state: reasonState(reasons, 'g:${g.key}'),
                onTap: () => setState(() => cycleReason(reasons, 'g:${g.key}')),
              ),
          ],
        ),
        if (specific.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Specific to this title',
            style: tt.labelLarge?.copyWith(color: cs.primary),
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
                  onTap: () => setState(() => cycleReason(reasons, key)),
                ),
            ],
          ),
        ],
      ],
    );

    return CallbackShortcuts(
      bindings: {
        for (var n = 1; n <= 9; n++)
          SingleActivator(LogicalKeyboardKey(0x30 + n)): () => _setRating(n),
        const SingleActivator(LogicalKeyboardKey.digit0): () => _setRating(10),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (rating != null) _next();
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _next(save: false),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          if (pos > 0) {
            setState(() {
              pos--;
              _load();
            });
          }
        },
      },
      child: Focus(
        autofocus: true,
        focusNode: focus,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Rating tour · ${pos + 1} / ${queue.length}'),
            actions: [
              TextButton(onPressed: _finish, child: const Text('Finish later')),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: LinearProgressIndicator(
                value: pos / queue.length,
                minHeight: 4,
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Previous',
                    onPressed: pos == 0
                        ? null
                        : () => setState(() {
                            pos--;
                            _load();
                          }),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      app.removeQuiet(idx);
                      queue.removeAt(pos);
                      setState(_load);
                      if (queue.isEmpty || pos >= queue.length)
                        app.recomputeNow();
                    },
                    icon: const Icon(Icons.visibility_off_outlined),
                    label: const Text('Didn\'t really watch'),
                  ),
                  TextButton(
                    onPressed: () => _next(save: false),
                    child: const Text('Skip'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: rating == null ? null : _next,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Save & next'),
                  ),
                ],
              ),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Cover(
                                t.cover,
                                width: 170,
                                height: 245,
                                radius: 14,
                              ),
                              const SizedBox(width: 24),
                              Expanded(child: info),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Cover(
                                t.cover,
                                width: 100,
                                height: 145,
                                radius: 12,
                              ),
                              const SizedBox(width: 14),
                              Expanded(child: info),
                            ],
                          ),
                    const SizedBox(height: 22),
                    controls,
                    const SizedBox(height: 8),
                    Text(
                      'Keys: 1–9 and 0 (=10) rate · Enter saves · → skips · ← back',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
