import 'dart:convert';
import 'dart:io';

import 'package:lodestar/app_state.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // allow a real localhost server in tests
  filterPersistenceTest();

  Future<AppState> fresh(Directory d) async {
    final a = AppState();
    await a.init(supportDirOverride: d.path);
    return a;
  }

  test('backup round-trips and merge/replace work', () async {
    final d = Directory.systemTemp.createTempSync('atlas_bk');
    addTearDown(() => d.deleteSync(recursive: true));
    final a = await fresh(d);
    a.rate(
      3,
      rating: 9,
      reasons: {'g:romance', 'f:ending_types|bittersweet'},
      note: 'great',
    );
    a.setStatus(5, EntryStatus.ignored);
    final json = a.exportBackup();
    expect(jsonDecode(json)['entries'].length, 2);
    a.remove(3);
    a.remove(5);
    expect(a.entries, isEmpty);
    final r = a.restoreBackup(json, replace: true);
    expect(r.entries.length, 2);
    expect(a.entries[3]!.rating, 9);
    expect(a.entries[3]!.reasons, {'g:romance', 'f:ending_types|bittersweet'});
    expect(a.entries[5]!.status, EntryStatus.ignored);
    expect(
      () => a.restoreBackup('{"format":"nope"}', replace: false),
      throwsFormatException,
    );
  });

  test(
    'catalog: URL auto-update (ETag), gzip, bad file rejected, reset',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final d = Directory.systemTemp.createTempSync('atlas_cat');
      addTearDown(() => d.deleteSync(recursive: true));
      final a = await fresh(d);
      a.rate(3, rating: 8);
      final bundled = File('catalog.db');
      final gzipped = gzip.encode(
        await bundled.readAsBytes(),
      ); // compress once; the big file is served several times
      var conditional = 0;
      final server = await HttpServer.bind('127.0.0.1', 0);
      String serving = 'good';
      server.listen((req) async {
        if (serving == 'bad') {
          req.response
            ..headers.set('etag', '"bad"')
            ..add(utf8.encode('this is not sqlite'));
        } else if (req.headers.value('if-none-match') == '"v1"') {
          conditional++;
          req.response.statusCode = 304;
        } else {
          req.response.headers.set('etag', '"v1"');
          req.response.add(gzipped); // served gzipped
        }
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/catalog.db.gz';
      a.setCatalogUrl(url);
      await a.checkForUpdate();
      expect(a.catalogSource, 'url', reason: a.catalogStatus);
      expect(a.data.n, greaterThan(1000));
      expect(
        a.entries[3]?.rating,
        8,
        reason: 'user data survives a catalog swap',
      );
      await a.checkForUpdate(); // unchanged -> 304, no download
      expect(conditional, 1);
      expect(a.catalogStatus, contains('up to date'));

      // restart picks the custom catalog up again
      a.users.close();
      final b = await fresh(d);
      expect(b.catalogSource, 'url');
      // the start-up auto-check runs in the background; let it finish before the next explicit check
      while (b.catalogBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // a broken file is rejected and the old catalog keeps working
      serving = 'bad';
      await b.checkForUpdate(force: true);
      expect(b.catalogStatus, contains('Could not update'));
      expect(b.data.n, greaterThan(1000));

      // choose-a-file path
      await b.useCatalogFile(bundled);
      expect(b.catalogSource, 'file');
      await b.resetCatalog();
      expect(b.catalogSource, 'bundled');
      expect(b.entries[3]?.rating, 8);
      await server.close();
    },
  );
}

void filterPersistenceTest() {
  test('filters persist across restarts', () async {
    final d = Directory.systemTemp.createTempSync('atlas_flt');
    addTearDown(() => d.deleteSync(recursive: true));
    final a = AppState();
    await a.init(supportDirOverride: d.path);
    a.setControls(
      a.controls
        ..formats = {'TV'}
        ..maxEpisodes = 26
        ..moods = {'cozy'}
        ..excludeWarnings = {'gore'}
        ..minYear = 2010
        ..obscurity = 0.9,
    );
    expect(a.activeFilterCount, 5);
    a.users.close();
    final b = AppState();
    await b.init(supportDirOverride: d.path);
    expect(b.controls.formats, {'TV'});
    expect(b.controls.maxEpisodes, 26);
    expect(b.controls.moods, {'cozy'});
    expect(b.controls.excludeWarnings, {'gore'});
    expect(b.controls.minYear, 2010);
    expect(b.controls.obscurity, 0.9);
  });
}
