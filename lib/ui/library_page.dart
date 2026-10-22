import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../data/importers.dart';
import '../engine/recommender.dart';
import '../engine/search.dart';
import 'crunchyroll_page.dart';
import 'detail_page.dart';
import 'rating_tour.dart';
import 'rating_sheet.dart';
import 'widgets.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _ctl = TextEditingController();
  List<SearchHit> hits = [];
  EntryStatus tab = EntryStatus.watched;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    final app = context.read<AppState>();
    setState(() => hits = q.trim().length < 2 ? [] : app.search.search(q, limit: 10));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final list = app.byStatus(tab);
    return CustomScrollView(slivers: [
      SliverAppBar(
        floating: true,
        snap: true,
        title: const Text('Library'),
        actions: [
          IconButton(
              tooltip: 'Copy this list as text',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: list.isEmpty
                  ? null
                  : () => copyText(
                      context,
                      [
                        for (final e in list)
                          '${app.data.titles[e.key].display}${e.value.rating != null ? ' - ${e.value.rating == e.value.rating!.roundToDouble() ? e.value.rating!.toInt() : e.value.rating}' : ''}'
                      ].join('\n'),
                      what: '${list.length} titles')),
          IconButton(tooltip: 'Paste a list of titles', icon: const Icon(Icons.content_paste), onPressed: () => _pasteDialog(context)),
          IconButton(tooltip: 'Import Crunchyroll / MyAnimeList export', icon: const Icon(Icons.upload_file), onPressed: () => _importDialog(context)),
        ],
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchBar(
            controller: _ctl,
            hintText: 'Search any title to add it (romaji, English, synonyms)…',
            leading: const Icon(Icons.search),
            trailing: [
              if (_ctl.text.isNotEmpty)
                IconButton(icon: const Icon(Icons.close), onPressed: () {
                  _ctl.clear();
                  _onQuery('');
                })
            ],
            onChanged: _onQuery,
          ),
        ),
      ),
      if (hits.isEmpty && app.unratedWatched().isNotEmpty)
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .55), borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              const Icon(Icons.rate_review_outlined),
              const SizedBox(width: 12),
              Expanded(child: Text('${app.unratedWatched().length} watched titles have no rating yet. Rate them quickly, one after another — it makes your recommendations much sharper.')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => _startTour(context), child: const Text('Start rating tour')),
            ]),
          ),
        ),
      if (hits.isNotEmpty)
        SliverList.builder(
          itemCount: hits.length,
          itemBuilder: (_, i) {
            final t = app.data.titles[hits[i].idx];
            final e = app.entryOf(t.idx);
            return ListTile(
              leading: Cover(t.cover, width: 40, height: 56, radius: 6),
              title: Text(t.display, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([metaLine(t), if (t.titleEn != null && t.titleEn != t.title) t.title].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: e == null
                  ? FilledButton.tonal(onPressed: () => showRatingSheet(context, t.idx), child: const Text('Add'))
                  : Chip(label: Text(e.status == EntryStatus.watched ? '✓ ${e.rating ?? ''}' : e.status.name)),
              onTap: () => showRatingSheet(context, t.idx),
            );
          },
        )
      else ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<EntryStatus>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: EntryStatus.watched, label: Text('Watched ${app.byStatus(EntryStatus.watched).length}')),
                ButtonSegment(value: EntryStatus.planned, label: Text('Plan ${app.byStatus(EntryStatus.planned).length}')),
                ButtonSegment(value: EntryStatus.notInterested, label: Text('Skipped ${app.byStatus(EntryStatus.notInterested).length}')),
                ButtonSegment(value: EntryStatus.ignored, label: Text('Ignored ${app.byStatus(EntryStatus.ignored).length}')),
              ],
              selected: {tab},
              onSelectionChanged: (s) => setState(() => tab = s.first),
            ),
          ),
        ),
        if (list.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    tab == EntryStatus.watched
                        ? 'Nothing here yet.\nSearch above, paste a list, or import your history.'
                        : 'Nothing here yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  if (tab == EntryStatus.watched) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _importDialog(context),
                      icon: const Icon(Icons.play_circle_outline),
                      label: Text(kIsWeb ? 'Import from a file' : 'Import from Crunchyroll or a file'),
                    ),
                  ],
                ]),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final idx = list[i].key;
              final e = list[i].value;
              final t = app.data.titles[idx];
              return Dismissible(
                key: ValueKey('lib$idx'),
                background: Container(color: cs.errorContainer, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 20), child: const Icon(Icons.delete_outline)),
                secondaryBackground: Container(color: cs.errorContainer, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_outline)),
                onDismissed: (_) => app.remove(idx),
                child: ListTile(
                  leading: Cover(t.cover, width: 40, height: 56, radius: 6),
                  title: Text(t.display, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      e.reasons.isEmpty ? metaLine(t) : '${metaLine(t)} · ${e.reasons.length} reason${e.reasons.length == 1 ? '' : 's'}',
                      maxLines: 1),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (e.status == EntryStatus.watched)
                      (e.rating != null
                          ? Text(e.rating == e.rating!.roundToDouble() ? e.rating!.toInt().toString() : '${e.rating}',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w800))
                          : TextButton(onPressed: () => showRatingSheet(context, idx), child: const Text('Rate')))
                    else if (e.status == EntryStatus.ignored)
                      TextButton.icon(
                        onPressed: () => app.remove(idx),
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Restore'),
                      )
                    else
                      IconButton(
                          tooltip: 'Mark as watched',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: () => showRatingSheet(context, idx)),
                    if (e.status != EntryStatus.ignored)
                      TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () {
                          app.setStatus(idx, EntryStatus.ignored);
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(SnackBar(
                              content: Text('Ignored ${t.display}'),
                              action: SnackBarAction(label: 'Undo', onPressed: () => app.setStatus(idx, e.status)),
                            ));
                        },
                        icon: const Icon(Icons.visibility_off_outlined, size: 18),
                        label: MediaQuery.sizeOf(context).width < 520 ? const SizedBox.shrink() : const Text('Ignore'),
                      ),
                  ]),
                  onTap: () => e.status == EntryStatus.watched
                      ? showRatingSheet(context, idx)
                      : Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(idx: idx))),
                  onLongPress: () => showModalBottomSheet(
                    context: context,
                    builder: (_) => SafeArea(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        ListTile(
                            leading: const Icon(Icons.copy_rounded),
                            title: const Text('Copy title'),
                            subtitle: Text(copyableTitle(t), maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.pop(context);
                              copyText(context, copyableTitle(t));
                            }),
                        ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: const Text('Open details'),
                            onTap: () {
                              Navigator.pop(context);
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(idx: idx)));
                            }),
                      ]),
                    ),
                  ),
                ),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    ]);
  }

  Future<void> _pasteDialog(BuildContext context) async {
    final app = context.read<AppState>();
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Paste your list'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('One title per line. Add a rating at the end if you like:\n"Monster - 10", "Mushishi, 9.5".',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            TextField(controller: ctl, maxLines: 12, minLines: 8, decoration: const InputDecoration(border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Import')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    final res = parsePastedList(text, app.data, app.search);
    app.addMany(res.entries);
    if (context.mounted) _report(context, res);
  }

  void _startTour(BuildContext context) {
    final app = context.read<AppState>();
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ChangeNotifierProvider.value(value: app, child: const RatingTourPage()),
    ));
  }

  Future<void> _importDialog(BuildContext context) async {
    final app = context.read<AppState>();
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Import your watch history'),
        children: [
          if (!kIsWeb)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'cr'),
            child: const ListTile(
              leading: Icon(Icons.play_circle_outline),
              title: Text('Connect Crunchyroll'),
              subtitle: Text('Log in inside the app, import your whole history in one tap'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'file'),
            child: const ListTile(
              leading: Icon(Icons.upload_file),
              title: Text('From a file'),
              subtitle: Text('MyAnimeList / AniList / Kitsu export, CSV or a title list'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'paste'),
            child: const ListTile(
              leading: Icon(Icons.content_paste),
              title: Text('Paste a list'),
              subtitle: Text('One title per line, optional rating'),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'cr':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(value: app, child: const CrunchyrollPage()),
        ));
      case 'file':
        _importMal(context);
      case 'paste':
        _pasteDialog(context);
    }
  }

  Future<void> _importMal(BuildContext context) async {
    final app = context.read<AppState>();
    final picked = await FilePicker.pickFiles(type: FileType.any, withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes ?? (!kIsWeb && f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null || !context.mounted) return;
    try {
      final res = parseAnyImport(bytes, app.data, app.search);
      app.addMany(res.entries);
      if (context.mounted) _report(context, res);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read that file: $e')));
      }
    }
  }

  void _report(BuildContext context, ImportResult res) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Imported ${res.matched} titles'),
        content: SizedBox(
          width: 460,
          child: res.unmatched.isEmpty
              ? const Text('Everything was matched.')
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${res.unmatched.length} not found in the catalog (shorts/specials may be missing, or adult titles):'),
                  const SizedBox(height: 8),
                  Flexible(child: SingleChildScrollView(child: Text(res.unmatched.take(60).join('\n'), style: const TextStyle(fontSize: 12.5)))),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          if (context.read<AppState>().unratedWatched().isNotEmpty)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _startTour(context);
              },
              child: const Text('Rate them now'),
            ),
        ],
      ),
    );
  }
}
