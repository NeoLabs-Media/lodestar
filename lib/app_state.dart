import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:http/http.dart' as http;

import 'assistant/llm.dart';
import 'assistant/openrouter.dart';
import 'assistant/session.dart';
import 'assistant/taste_ai.dart';
import 'assistant/settings.dart';
import 'assistant/tools.dart';
import 'data/backup.dart';
import 'data/crunchyroll.dart';
import 'platform/web_bridge.dart';
import 'data/user_store.dart';
import 'engine/catalog_data.dart';
import 'engine/catalog_loader.dart';
import 'engine/catalog_update.dart';
import 'platform/sql.dart' as sql;
import 'engine/recommender.dart';
import 'engine/taste_layer.dart';
import 'engine/search.dart';

class AppState extends ChangeNotifier {
  late CatalogStore store;
  late CatalogData data;
  late Recommender recommender;
  TitleSearch? _search;

  /// Built on first use (indexing ~30k titles is not needed to show the first screen).
  TitleSearch get search => _search ??= TitleSearch(data);

  /// What the loading screen says while the catalog is being opened.
  String loadStage = 'Starting…';

  Future<void> _stage(String text) async {
    loadStage = text;
    notifyListeners();
    await Future<void>.delayed(
      const Duration(milliseconds: 16),
    ); // let the screen paint it
  }

  late UserStore users;

  // ---- optional AI assistant ----
  late AiSettings ai = AiSettings(users);

  /// Replaced in tests to avoid any real network access.
  LlmProvider Function(String key) providerFactory = (key) =>
      OpenRouterProvider(key);
  AssistantSession? _assistant;
  Controls? _chatControls;

  /// The chat's own filters (used when "use my feed filters" is off), loaded from the saved settings.
  Controls get chatControls => _chatControls ??= ai.loadChatFilters();

  /// The filters the assistant must obey right now.
  Controls get assistantControls => ai.useFeedFilters ? controls : chatControls;

  void setChatControls(Controls c) {
    _chatControls = c;
    ai.saveChatFilters(c);
    notifyListeners();
    _assistant?.syncState();
  }

  void setUseFeedFilters(bool v) {
    ai.useFeedFilters = v;
    notifyListeners();
    _assistant?.syncState();
  }

  void setSpoilers(bool v) {
    ai.spoilers = v;
    notifyListeners();
    _assistant?.syncState();
  }

  LlmProvider providerFor() => providerFactory(ai.apiKey ?? '');

  /// The (lazily created) assistant chat; rebuilt only by [resetAssistant].
  AssistantSession get assistant => _assistant ??= AssistantSession(
    providerOf: providerFor,
    tools: AssistantTools(
      AssistantContext(
        store: store,
        rec: recommender,
        search: search,
        controls: () => assistantControls,
        entries: () => entries.values.toList(),
        libraryAllowed: () => ai.libraryAllowed,
        spoilers: () => ai.spoilers,
      ),
    ),
    liveState: () => {
      'spoilers': ai.spoilers ? 'on' : 'off',
      'filters': assistantControls.describe(),
    },
    model: () => ai.model,
    systemPrompt: () => buildSystemPrompt(
      titleCount: data.n,
      kinds: data.kinds,
      filters: assistantControls.describe(),
      libraryAllowed: ai.libraryAllowed,
      spoilers: ai.spoilers,
      now: DateTime.now(),
    ),
    runAction: _runAssistantAction,
  );

  void resetAssistant() {
    _assistant?.dispose();
    _assistant = null;
    notifyListeners();
  }

  void _runAssistantAction(PendingAction a) {
    switch (a.type) {
      case 'plan':
        setStatus(a.idx, EntryStatus.planned);
      case 'watched':
        rate(a.idx, rating: a.rating);
      default:
        skip(a.idx, reasons: a.reasons);
    }
  }

  bool ready = false;
  String? error;

  final Map<int, UserEntry> entries = {}; // by catalog idx
  List<CrSeries>?
  pendingCrSeries; // from the web bookmarklet, awaiting the user's OK
  final Map<int, String> importHints =
      {}; // transient, shown in the rating tour
  Controls controls = Controls();
  TasteModel? model;
  List<Rec> feed = [];
  bool computing = false;
  int _seq = 0;

  /// Bumped on every shuffle so the same state doesn't give an identical feed after "refresh".
  int feedEpoch = 0;
  Timer? _debounce;

  late Directory dir;
  String catalogSource = 'bundled'; // bundled | file | url
  String catalogUrl = '';
  bool autoCheck = true;
  bool catalogBusy = false;
  double? downloadProgress;
  String catalogStatus = '';
  String backupError = '';
  String lastAutoBackup = '';

  File get _customFile =>
      File(p.join(dir.path, 'catalog_custom.db')); // native only

  Future<void> init({String? supportDirOverride}) async {
    try {
      if (kIsWeb) {
        users = UserStore.open('');
        catalogSource = 'bundled';
        await _stage('Downloading the catalog…');
        final bytes = await rootBundle.load('catalog.db');
        await _stage(
          'Opening ${(bytes.lengthInBytes / 1e6).round()} MB of titles…',
        );
        final opened = await CatalogStore.openBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        await _stage('Getting your picks ready…');
        _attach(opened);
        _loadControls();
        try {
          final pending = takePendingImport();
          if (pending != null)
            pendingCrSeries = parseBookmarkletPayload(pending);
        } catch (_) {}
        ready = true;
        notifyListeners();
        await refresh();
        return;
      }
      dir = supportDirOverride != null
          ? Directory(supportDirOverride)
          : await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      users = UserStore.open(p.join(dir.path, 'user.db'));
      catalogSource = users.setting('catalog_source') ?? 'bundled';
      catalogUrl = users.setting('catalog_url') ?? '';
      autoCheck = (users.setting('catalog_autocheck') ?? '1') == '1';
      CatalogStore? opened;
      if (catalogSource != 'bundled' && await _customFile.exists()) {
        try {
          opened = CatalogStore.open(_customFile.path);
        } catch (e) {
          catalogStatus =
              'Custom database could not be opened ($e) — using the bundled one.';
          catalogSource = 'bundled';
          users.setSetting('catalog_source', 'bundled');
        }
      } else {
        catalogSource = 'bundled';
      }
      await _stage('Opening your catalog…');
      opened ??= await _openBundled();
      await _stage('Getting your picks ready…');
      _attach(opened);
      _loadControls();
      ready = true;
      notifyListeners();
      _dailyBackup();
      if (catalogUrl.isNotEmpty && autoCheck) unawaited(checkForUpdate());
      await refresh();
    } catch (e, st) {
      error = '$e\n$st';
      notifyListeners();
    }
  }

  Future<CatalogStore> _openBundled() async {
    final version = (await rootBundle.loadString('catalog.version')).trim();
    final dbFile = File(p.join(dir.path, 'catalog.db'));
    final verFile = File(p.join(dir.path, 'catalog.version'));
    if (!await dbFile.exists() ||
        !await verFile.exists() ||
        (await verFile.readAsString()).trim() != version) {
      final bytes = await rootBundle.load('catalog.db');
      await dbFile.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      await verFile.writeAsString(version);
    }
    return CatalogStore.open(dbFile.path);
  }

  /// Makes [s] the active catalog and re-links the user's entries to it (ids are stable).
  void _attach(CatalogStore s) {
    _assistant?.dispose(); // its tools hold the previous catalog
    _assistant = null;
    _chatControls = null;
    store = s;
    data = s.data;
    recommender = Recommender(data);
    _search = null;
    importHints.clear();
    _reloadEntries();
  }

  // ---- AI taste layer (separate from the learned weights; see engine/taste_layer.dart) ----
  TasteLayer layer = const TasteLayer();
  TasteLayer? layerPrev; // one undo step

  void _loadLayer() {
    layer =
        TasteLayer.decode(users.setting('taste_layer')) ?? const TasteLayer();
    layerPrev = TasteLayer.decode(users.setting('taste_layer_prev'));
    recommender.layer = layer;
  }

  void _saveLayer() {
    users.setSetting('taste_layer', layer.isEmpty ? '' : layer.encode());
    users.setSetting(
      'taste_layer_prev',
      layerPrev == null || layerPrev!.isEmpty ? '' : layerPrev!.encode(),
    );
    recommender.layer = layer;
    _changed();
  }

  /// "Improve my taste profile" needs the assistant switched on, a key and the library-access consent.
  bool get canImproveProfile => ai.ready && ai.libraryAllowed;

  TasteRequest tasteRequest() =>
      buildTasteRequest(data, entries.values.toList(), summary(), layer);

  /// Only ever called after the user saw [tasteRequest]'s preview and tapped Send.
  Future<TasteProposal> sendTasteRequest(TasteRequest req) async {
    if (!canImproveProfile)
      throw const TasteAiException(
        'Switch on the assistant and allow it to read your library first (Settings → AI assistant).',
      );
    return requestProposal(providerFor(), ai.model, req, data);
  }

  Future<LayerEval> evaluateRules(List<LayerRule> rules) =>
      recommender.evaluateLayer(entries.values.toList(), rules);

  /// Replaces the layer with [next]; the old one stays as the undo step and the differences are recorded.
  void applyLayer(TasteLayer next) {
    final stamped = next.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      changes: next.diffFrom(layer),
    );
    if (!layer.isEmpty) layerPrev = layer;
    layer = stamped;
    _saveLayer();
  }

  void undoLayer() {
    final prev = layerPrev;
    if (prev == null) return;
    layerPrev = layer.isEmpty ? null : layer; // undo of the undo
    layer = prev;
    _saveLayer();
  }

  void resetLayer() {
    if (!layer.isEmpty) layerPrev = layer;
    layer = const TasteLayer();
    _saveLayer();
  }

  void updateLayer(TasteLayer next) {
    layer = next;
    _saveLayer();
  }

  void _reloadEntries() {
    _loadLayer();
    entries.clear();
    final backfill = <UserEntry>[];
    for (var e in users.all()) {
      var i = data.idToIdx[e.id];
      if (i == null && e.key != null) {
        // the catalog was renumbered: find the title again by its stable key
        final j = data.keyToIdx[e.key];
        if (j != null && !entries.containsKey(j)) {
          users.relink(e.id, data.titles[j].id);
          e = e.withKey(e.key, id: data.titles[j].id);
          i = j;
        }
      }
      if (i == null) continue;
      if (e.key == null) {
        e = e.withKey(data.titles[i].key);
        backfill.add(e);
      }
      entries[i] = e;
    }
    if (backfill.isNotEmpty) users.putAll(backfill);
  }

  // --- catalog configuration ----------------------------------------------------
  void _status(String s, {double? progress}) {
    catalogStatus = s;
    downloadProgress = progress;
    notifyListeners();
  }

  /// Validates [candidate] (must be a catalog.db built by tools/export.py), then makes it the
  /// active catalog. The user's data is untouched.
  Future<void> _installCatalog(File candidate, String source) async {
    final test = CatalogStore.open(
      candidate.path,
    ); // throws when it is not a valid catalog
    final schema = int.tryParse(test.data.meta['schema'] ?? '') ?? 0;
    final n = test.data.n;
    test.close();
    if (schema < 1 || schema > supportedSchema)
      throw FormatException('Unsupported catalog schema "$schema".');
    if (n == 0) throw const FormatException('The catalog contains no titles.');
    final old = store;
    await candidate.rename(_customFile.path);
    final fresh = CatalogStore.open(_customFile.path);
    _attach(fresh);
    if (!identical(old, fresh)) old.close();
    catalogSource = source;
    users.setSetting('catalog_source', source);
    await refresh();
  }

  /// Number of titles added by the last catalog update (shown as a dismissible notice).
  int newTitlesNotice = 0;
  List<int> newTitleIds = const [];

  void dismissNewTitlesNotice() {
    newTitlesNotice = 0;
    notifyListeners();
  }

  bool _isDeltaFile(File f) {
    final db = sql.openFile(f.path, readOnly: true);
    try {
      return isDeltaDb(db);
    } finally {
      db.dispose();
    }
  }

  /// Applies an incoming file: a catalog update (delta) is merged into the installed catalog,
  /// anything else is validated and installed as the new catalog. Returns a status message.
  Future<String> _installOrMerge(File incoming, String source) async {
    if (_isDeltaFile(incoming)) {
      final res = await _applyDelta(incoming);
      await incoming.delete();
      return res.applied ? 'Catalog updated: ${res.message}' : res.message;
    }
    await _installCatalog(incoming, source);
    return 'Now using the new catalog: ${data.n} titles, built ${data.meta['built_at']}.';
  }

  /// Merges a catalog_delta into the installed catalog file (the user's data is never touched).
  Future<DeltaResult> _applyDelta(File deltaFile) async {
    final path = catalogSource == 'bundled'
        ? p.join(dir.path, 'catalog.db')
        : _customFile.path;
    store.close(); // release the read handle before writing
    DeltaResult? res;
    Object? failure;
    final target = sql.openFile(path);
    final delta = sql.openFile(deltaFile.path, readOnly: true);
    try {
      res = mergeDelta(target, delta);
    } catch (e) {
      failure = e;
    } finally {
      target.dispose();
      delta.dispose();
    }
    _attach(CatalogStore.open(path));
    if (failure != null) throw failure;
    if (res!.applied) {
      newTitlesNotice = res.added;
      newTitleIds = res.newIds;
      await refresh();
    }
    return res;
  }

  /// Applies a catalog_delta file chosen by the user.
  Future<String> applyDeltaFile(File picked) async {
    final tmp = File(p.join(dir.path, 'catalog_incoming.db'));
    await _copyMaybeGzip(picked, tmp);
    return _installOrMerge(tmp, 'file');
  }

  Future<void> useCatalogFile(File picked) async {
    if (kIsWeb) return;
    catalogBusy = true;
    _status('Checking the file…');
    try {
      final tmp = File(p.join(dir.path, 'catalog_incoming.db'));
      await _copyMaybeGzip(picked, tmp);
      _status(await _installOrMerge(tmp, 'file'));
    } catch (e) {
      _status('That file was not accepted: $e');
    } finally {
      catalogBusy = false;
      notifyListeners();
    }
  }

  Future<void> _copyMaybeGzip(File from, File to) async {
    final head = await from
        .openRead(0, 2)
        .fold<List<int>>([], (a, b) => a..addAll(b));
    if (head.length == 2 && head[0] == 0x1f && head[1] == 0x8b) {
      await from.openRead().transform(gzip.decoder).pipe(to.openWrite());
    } else {
      await from.copy(to.path);
    }
  }

  void setCatalogUrl(String url, {bool? auto}) {
    catalogUrl = url.trim();
    if (auto != null) autoCheck = auto;
    users.setSetting('catalog_url', catalogUrl);
    users.setSetting('catalog_autocheck', autoCheck ? '1' : '0');
    users.setSetting('catalog_etag', '');
    users.setSetting('catalog_lastmod', '');
    users.setSetting('catalog_len', '');
    notifyListeners();
  }

  /// Fetches [catalogUrl]; downloads only when the server says it changed (ETag / Last-Modified /
  /// size). [force] always downloads.
  Future<void> checkForUpdate({bool force = false}) async {
    if (kIsWeb || catalogUrl.isEmpty || catalogBusy) return;
    final uri = Uri.tryParse(catalogUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _status('The address must start with http:// or https://');
      return;
    }
    catalogBusy = true;
    _status('Checking for a new database…');
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      final etag = users.setting('catalog_etag') ?? '',
          lastmod = users.setting('catalog_lastmod') ?? '';
      if (!force) {
        if (etag.isNotEmpty) req.headers['If-None-Match'] = etag;
        if (lastmod.isNotEmpty) req.headers['If-Modified-Since'] = lastmod;
      }
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      users.setSetting('catalog_checked', DateTime.now().toIso8601String());
      if (resp.statusCode == 304) {
        _status('Database is up to date (checked just now).');
        return;
      }
      if (resp.statusCode != 200) {
        _status('The server answered HTTP ${resp.statusCode}.');
        return;
      }
      final len = resp.contentLength;
      final newEtag = resp.headers['etag'] ?? '',
          newMod = resp.headers['last-modified'] ?? '';
      if (!force &&
          newEtag.isEmpty &&
          newMod.isEmpty &&
          len != null &&
          '$len' == (users.setting('catalog_len') ?? '')) {
        await resp.stream.listen(null).cancel();
        _status('Database is up to date (same size as the installed one).');
        return;
      }
      final raw = File(p.join(dir.path, 'catalog_download.tmp'));
      final sink = raw.openWrite();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        _status(
          'Downloading… ${(got / 1e6).toStringAsFixed(1)} MB',
          progress: len == null || len == 0 ? null : got / len,
        );
      }
      await sink.close();
      final tmp = File(p.join(dir.path, 'catalog_incoming.db'));
      await _copyMaybeGzip(raw, tmp);
      await raw.delete();
      final outcome = await _installOrMerge(tmp, 'url');
      users.setSetting('catalog_etag', newEtag);
      users.setSetting('catalog_lastmod', newMod);
      users.setSetting('catalog_len', len == null ? '' : '$len');
      _status(outcome);
    } catch (e) {
      _status('Could not update: $e');
    } finally {
      client.close();
      catalogBusy = false;
      downloadProgress = null;
      notifyListeners();
    }
  }

  Future<void> resetCatalog() async {
    if (kIsWeb) return;
    catalogBusy = true;
    _status('Switching back to the bundled database…');
    try {
      final old = store;
      final fresh = await _openBundled();
      _attach(fresh);
      old.close();
      if (await _customFile.exists()) await _customFile.delete();
      catalogSource = 'bundled';
      users.setSetting('catalog_source', 'bundled');
      setCatalogUrl('');
      await refresh();
      _status(
        'Using the bundled database: ${data.n} titles, built ${data.meta['built_at']}.',
      );
    } catch (e) {
      _status('Could not reset: $e');
    } finally {
      catalogBusy = false;
      notifyListeners();
    }
  }

  String? get lastChecked => users.setting('catalog_checked');

  // --- backup -------------------------------------------------------------------
  String exportBackup() => buildBackup(
    users.all(),
    data,
    settings: {
      'obscurity': controls.obscurity.toStringAsFixed(3),
      if (!layer.isEmpty) 'taste_layer': layer.encode(),
      if (layerPrev != null && !layerPrev!.isEmpty)
        'taste_layer_prev': layerPrev!.encode(),
    },
  );

  /// Restores a backup file's content. [replace] wipes the current library first.
  RestoreResult restoreBackup(String json, {required bool replace}) {
    final res = parseBackup(json, data, search);
    if (replace) users.clear();
    users.putAll(res.entries);
    final ob = double.tryParse(res.settings['obscurity'] ?? '');
    if (ob != null) {
      controls.obscurity = ob;
      users.setSetting('obscurity', ob.toStringAsFixed(3));
    }
    if (replace) {
      users.setSetting('taste_layer', '');
      users.setSetting('taste_layer_prev', '');
    }
    for (final k in const ['taste_layer', 'taste_layer_prev']) {
      final v = res.settings[k];
      if (v != null && TasteLayer.decode(v) != null) users.setSetting(k, v);
    }
    _reloadEntries();
    _changed();
    return res;
  }

  Directory get backupDir =>
      kIsWeb ? Directory('') : Directory(p.join(dir.path, 'backups'));

  /// One rolling backup per day (last 14 kept) so a mistake never loses a library.
  void _dailyBackup() {
    if (kIsWeb) return;
    try {
      if (users.all().isEmpty) return;
      backupDir.createSync(recursive: true);
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final f = File(p.join(backupDir.path, 'auto-backup-$day.json'));
      if (!f.existsSync()) f.writeAsStringSync(exportBackup());
      lastAutoBackup = day;
      final all =
          backupDir
              .listSync()
              .whereType<File>()
              .where((x) => x.path.contains('auto-backup-'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final old in all.take(all.length > 14 ? all.length - 14 : 0)) {
        old.deleteSync();
      }
    } catch (e) {
      backupError = '$e';
    }
  }

  // --- views over entries ---
  List<MapEntry<int, UserEntry>> byStatus(EntryStatus s) {
    final l = entries.entries.where((e) => e.value.status == s).toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return l;
  }

  UserEntry? entryOf(int idx) => entries[idx];
  int get watchedCount =>
      entries.values.where((e) => e.status == EntryStatus.watched).length;
  int get ratedCount => entries.values
      .where((e) => e.status == EntryStatus.watched && e.rating != null)
      .length;

  // --- mutations ---
  void rate(
    int idx, {
    double? rating,
    Set<String> reasons = const {},
    String note = '',
    bool recompute = true,
  }) {
    final e = UserEntry(
      id: data.titles[idx].id,
      key: data.titles[idx].key,
      status: EntryStatus.watched,
      rating: rating,
      reasons: reasons,
      note: note,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    entries[idx] = e;
    users.put(e);
    if (recompute) {
      _changed();
    } else {
      notifyListeners();
    }
  }

  /// Watched titles still without a rating (e.g. after an import), most popular first.
  List<int> unratedWatched() {
    final l =
        [
          for (final e in entries.entries)
            if (e.value.status == EntryStatus.watched && e.value.rating == null)
              e.key,
        ]..sort(
          (a, b) =>
              data.titles[b].popularity.compareTo(data.titles[a].popularity),
        );
    return l;
  }

  void removeQuiet(int idx) {
    entries.remove(idx);
    users.remove(data.titles[idx].id);
    notifyListeners();
  }

  void recomputeNow() => _changed();

  void setStatus(int idx, EntryStatus s) {
    final old = entries[idx];
    final e = UserEntry(
      id: data.titles[idx].id,
      key: data.titles[idx].key,
      status: s,
      rating: s == EntryStatus.watched ? old?.rating : null,
      reasons: s == EntryStatus.watched ? (old?.reasons ?? {}) : {},
      note: old?.note ?? '',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    entries[idx] = e;
    users.put(e);
    _changed();
  }

  /// "Ask why when I press Not for me": sheet (default) | snackbar | never.
  String get askWhyMode {
    final v = users.setting('ask_why');
    return const {'sheet', 'snackbar', 'never'}.contains(v) ? v! : 'sheet';
  }

  void setAskWhyMode(String v) {
    users.setSetting('ask_why', v);
    notifyListeners();
  }

  /// Marks a title "not for me". With [reasons] (`n:aspect`, `x:kind|value`, `h:content_warnings|value`) the
  /// ranking pushes down exactly those parts instead of the whole title. Also edits an existing skip.
  void skip(int idx, {Set<String> reasons = const {}, String note = ''}) {
    final e = UserEntry(
      id: data.titles[idx].id,
      key: data.titles[idx].key,
      status: EntryStatus.notInterested,
      reasons: {
        for (final r in reasons)
          if (r.startsWith('n:') || r.startsWith('x:') || r.startsWith('h:')) r,
      },
      note: note.trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    entries[idx] = e;
    users.put(e);
    _changed();
  }

  void remove(int idx) {
    entries.remove(idx);
    users.remove(data.titles[idx].id);
    _changed();
  }

  /// Bulk add (imports): no refresh storm, one recompute at the end.
  void addMany(List<UserEntry> list) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final toSave = <UserEntry>[];
    for (final e in list) {
      final i = data.idToIdx[e.id];
      if (i == null) continue;
      final old = entries[i];
      if (old != null && old.status == EntryStatus.ignored)
        continue; // ignored stays ignored on re-import
      if (old != null &&
          old.status == EntryStatus.watched &&
          e.status == EntryStatus.watched &&
          old.rating != null &&
          e.rating == null) {
        continue; // never overwrite a real rating with "unrated"
      }
      final ne = UserEntry(
        id: e.id,
        key: data.titles[i].key,
        status: e.status,
        rating: e.rating,
        reasons: e.reasons,
        note: e.note,
        updatedAt: now,
      );
      entries[i] = ne;
      toSave.add(ne);
    }
    users.putAll(toSave);
    _changed();
  }

  void setControls(Controls c, {bool persist = true}) {
    controls = c;
    if (persist) saveControls();
    if (ai.useFeedFilters) _assistant?.syncState();
    _changed(debounced: true);
  }

  /// Filters survive restarts (stored as JSON in the settings table).
  void saveControls() {
    users.setSetting('filters', jsonEncode(controls.toJson()));
    users.setSetting('obscurity', controls.obscurity.toStringAsFixed(3));
  }

  void _loadControls() {
    final saved = users.setting('obscurity');
    if (saved != null)
      controls.obscurity = double.tryParse(saved) ?? controls.obscurity;
    final raw = users.setting('filters');
    if (raw == null) return;
    try {
      controls = Controls.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {}
  }

  int get activeFilterCount =>
      controls.activeCount(multiKindCatalog: data.kinds.length > 1);

  void _changed({bool debounced = false}) {
    notifyListeners();
    _debounce?.cancel();
    if (debounced) {
      _debounce = Timer(const Duration(milliseconds: 250), refresh);
    } else {
      refresh();
    }
  }

  Future<void> refresh({bool reshuffle = false}) async {
    if (!ready) return;
    final seq = ++_seq;
    computing = true;
    notifyListeners();
    await Future<void>.delayed(
      const Duration(milliseconds: 16),
    ); // let the UI paint first
    recommender.alwaysHideWarnings = {
      for (final e in entries.values)
        if (e.status == EntryStatus.notInterested)
          for (final r in e.reasons)
            if (r.startsWith('h:content_warnings|'))
              r.substring('h:content_warnings|'.length),
    };
    model = recommender.fit([for (final e in entries.values) e]);
    final result = recommender.recommend(model!, controls, count: 60);
    if (seq != _seq) return;
    feed = result;
    computing = false;
    notifyListeners();
  }

  TasteSummary summary() =>
      recommender.summarize(model ?? recommender.fit(entries.values.toList()));

  Rec? surprise() {
    final m = model;
    if (m == null) return null;
    return recommender.surprise(
      m,
      controls,
      seed: DateTime.now().microsecondsSinceEpoch,
    );
  }

  Rec? explainFor(int idx) {
    final m = model;
    if (m == null) return null;
    final (why, anchor, tags) = recommender.explain(idx, m);
    return Rec(idx, 0, 0, why, anchor, false, tags);
  }

  /// Detail JSON for the detail screen.
  Map<String, dynamic> detail(int idx) => store.detail(idx);

  String get catalogInfo =>
      '${data.n} titles · built ${data.meta['built_at']} · ${data.meta['model']}';

  /// Export of the user's data (for backup).
  String exportJson() => jsonEncode([
    for (final e in entries.values)
      {
        'id': e.id,
        'status': e.status.name,
        'rating': e.rating,
        'reasons': e.reasons.toList(),
        'note': e.note,
      },
  ]);
}
