// Explicitly disliked tags/aspects in the rating sheet: tri-state chips, the model avoids them,
// the taste summary lists them, backups keep them.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/data/backup.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/catalog_data.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';
import 'package:lodestar/ui/rating_sheet.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

void main() {
  Cover.offline = true;
  final c = CatalogStore.open('catalog.db').data;
  final rec = Recommender(c);

  List<UserEntry> fan(Set<String> reasonsOnFirst) {
    // a handful of well-known, popular romance/drama titles
    final search = TitleSearch(c);
    final names = [
      'Clannad After Story',
      'Violet Evergarden',
      'Toradora!',
      'Kimi ni Todoke',
      'Nana',
      'Your lie in April',
    ];
    final out = <UserEntry>[];
    for (var i = 0; i < names.length; i++) {
      final idx = search.bestMatch(names[i])!;
      out.add(
        UserEntry(
          id: c.titles[idx].id,
          status: EntryStatus.watched,
          rating: 9,
          reasons: i == 0 ? reasonsOnFirst : const {},
        ),
      );
    }
    return out;
  }

  int count(List<Rec> r, int fid) => r
      .where((x) => c.facetsOf(x.idx).any((e) => e.$1 == fid && e.$2 >= 4))
      .length;

  test(
    'a disliked tag disappears from the feed even though the show it came from was loved',
    () {
      final base = rec.recommend(rec.fit(fan({})), Controls(), count: 40);
      final first = c.idToIdx[fan({}).first.id]!;
      // candidate tags: facets of the loved show that are common in the baseline feed
      FacetDef? pick;
      var best = 0;
      for (final (fid, w) in c.facetsOf(first)) {
        final f = c.vocab[fid];
        if (!const {
              'anilist_tag',
              'themes',
              'moods',
              'archetypes',
            }.contains(f.kind) ||
            w < 6)
          continue;
        final n = count(base, fid);
        if (n > best) {
          best = n;
          pick = f;
        }
      }
      expect(pick, isNotNull);
      expect(
        best,
        greaterThanOrEqualTo(4),
        reason: 'need a tag that is common in the baseline feed',
      );
      final key = '${pick!.kind}|${pick.value}';
      final avoided = rec.recommend(
        rec.fit(fan({'x:$key'})),
        Controls(),
        count: 40,
      );
      final after = count(avoided, pick.fid);
      // ignore: avoid_print
      print('disliked "$key": ${best}x in the baseline top 40 -> ${after}x');
      expect(
        after,
        lessThanOrEqualTo((best * 0.4).floor()),
        reason: 'dislike must strongly suppress the tag',
      );
      expect(avoided.length, 40, reason: 'feed still full');
      // liking the same tag instead does the opposite
      final liked = rec.recommend(
        rec.fit(fan({'f:$key'})),
        Controls(),
        count: 40,
      );
      expect(count(liked, pick.fid), greaterThanOrEqualTo(best));
    },
  );

  test('a disliked aspect (humor) lowers comedy in the feed', () {
    double comedy(List<Rec> r) {
      final d = c.dimIndex('comedy');
      return r.map((x) => c.dim(x.idx, d)).reduce((a, b) => a + b) / r.length;
    }

    final base = comedy(rec.recommend(rec.fit(fan({})), Controls(), count: 40));
    final disliked = comedy(
      rec.recommend(rec.fit(fan({'n:humor'})), Controls(), count: 40),
    );
    final liked = comedy(
      rec.recommend(rec.fit(fan({'g:humor'})), Controls(), count: 40),
    );
    // ignore: avoid_print
    print('comedy avg: disliked $disliked < base $base < liked $liked');
    expect(disliked, lessThan(base));
    expect(liked, greaterThan(base));
  });

  test('summary lists flagged tags and aspects; backups keep the reasons', () {
    final entries = fan({'x:anilist_tag|school', 'n:humor', 'f:themes|grief'});
    final m = rec.fit(entries);
    final s = rec.summarize(m);
    expect(s.dislikedTags.map((f) => f.value), contains('school'));
    expect(s.dislikedAspects, contains('Humor'));
    expect(
      s.reasonCounts.keys.any((k) => k.toLowerCase().contains('grief')),
      isTrue,
    );
    final json = buildBackup(entries, c);
    final back = parseBackup(json, c, TitleSearch(c));
    expect(back.entries.first.reasons, {
      'x:anilist_tag|school',
      'n:humor',
      'f:themes|grief',
    });
  });

  test('reason state cycles like -> dislike -> none', () {
    final r = <String>{};
    expect(reasonState(r, 'f:themes|grief'), 0);
    cycleReason(r, 'f:themes|grief');
    expect(r, {'f:themes|grief'});
    expect(reasonState(r, 'f:themes|grief'), 1);
    cycleReason(r, 'f:themes|grief');
    expect(r, {'x:themes|grief'});
    expect(reasonState(r, 'f:themes|grief'), 2);
    cycleReason(r, 'f:themes|grief');
    expect(r, isEmpty);
    cycleReason(r, 'g:humor');
    cycleReason(r, 'g:humor');
    expect(r, {'n:humor'});
  });

  testWidgets('rating sheet: tap a tag twice to dislike it, and it is saved', (
    t,
  ) async {
    final dir = Directory.systemTemp.createTempSync('lodestar_dis');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('test/fixtures/mixed_v2.db').copySync('${dir.path}/catalog_custom.db');
    final u = UserStore.open('${dir.path}/user.db')
      ..setSetting('catalog_source', 'file');
    u.close();
    final app = AppState();
    await t.runAsync(() => app.init(supportDirOverride: dir.path));
    final idx = app.data.idToIdx[102]!; // movie with keyword tags
    final chips = specificReasonsFor(app.data, idx);
    expect(chips, isNotEmpty);
    final (key, label) = chips.first;

    t.view.physicalSize = const Size(900, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: Atlas.theme(),
          home: Scaffold(body: RatingPanel(idx: idx)),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.text(label));
    await t.pump();
    await t.tap(find.text(label));
    await t.pump();
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pump(const Duration(milliseconds: 400));
    expect(app.entries[idx]!.reasons, {'x:${key.substring(2)}'});
    await t.pump(const Duration(seconds: 1)); // flush the debounce timer
  });
}
