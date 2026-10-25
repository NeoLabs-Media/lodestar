import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'theme.dart';
import '../assistant/llm.dart';
import '../assistant/settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController url;
  String backupMsg = '';
  final keyCtl = TextEditingController();
  late final TextEditingController modelCtl;
  bool replacingKey = false, aiBusy = false;
  String aiMsg = '';
  bool aiOk = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    url = TextEditingController(text: app.catalogUrl);
    modelCtl = TextEditingController(text: app.ai.model);
  }

  @override
  void dispose() {
    url.dispose();
    keyCtl.dispose();
    modelCtl.dispose();
    super.dispose();
  }

  Widget _card(String title, IconData icon, List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: cs.primary),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final app = context.read<AppState>();
    final json = app.exportBackup();
    final bytes = Uint8List.fromList(utf8.encode(json));
    final name =
        'lodestar-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save backup',
      fileName: name,
      bytes: bytes,
    );
    if (path == null && !kIsWeb) return;
    if (kIsWeb) {
      setState(() => backupMsg = 'Downloaded ${app.entries.length} entries.');
      return;
    }
    try {
      final f = File(path!);
      if (!await f.exists() || await f.length() == 0)
        await f.writeAsBytes(bytes);
    } catch (_) {}
    setState(() => backupMsg = 'Saved ${app.entries.length} entries to $path');
  }

  Future<void> _restore() async {
    final app = context.read<AppState>();
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes =
        f.bytes ??
        (!kIsWeb && f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null || !mounted) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore backup'),
        content: const Text(
          'Merge adds the backup\'s entries to your current library (backup wins on conflicts). '
          'Replace wipes your current library first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            child: const Text('Replace'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'merge'),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (mode == null) return;
    try {
      final r = app.restoreBackup(
        utf8.decode(bytes),
        replace: mode == 'replace',
      );
      setState(
        () => backupMsg =
            'Restored ${r.entries.length} entries${r.unmatched.isEmpty ? '' : ' (${r.unmatched.length} not found in this database)'}.',
      );
    } catch (e) {
      setState(() => backupMsg = 'Could not restore: $e');
    }
  }

  Future<void> _pickDb() async {
    final app = context.read<AppState>();
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked == null || picked.files.single.path == null) return;
    await app.useCatalogFile(File(picked.files.single.path!));
  }

  void _saveKey(AppState app) {
    final k = keyCtl.text.trim();
    if (k.isEmpty) return;
    app.ai.saveKey(k);
    keyCtl.clear(); // never shown again
    app.resetAssistant();
    setState(() {
      replacingKey = false;
      aiMsg = 'Key saved.';
      aiOk = true;
    });
  }

  Future<void> _testAi(AppState app) async {
    app.ai.model = modelCtl.text;
    setState(() {
      aiBusy = true;
      aiMsg = 'Testing…';
    });
    final r = await app.providerFor().test(app.ai.model);
    if (!mounted) return;
    setState(() {
      aiBusy = false;
      aiOk = r.ok;
      aiMsg = r.message;
    });
  }

  Future<void> _loadModels(AppState app) async {
    setState(() {
      aiBusy = true;
      aiMsg = 'Loading models…';
    });
    List<ModelInfo> models = [];
    try {
      models = await app.providerFor().listModels();
      aiMsg = '${models.length} models with tool support (free ones first).';
      aiOk = true;
    } on LlmException catch (e) {
      aiMsg = e.message;
      aiOk = false;
    }
    if (!mounted) return;
    setState(() => aiBusy = false);
    if (models.isEmpty) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Choose a model'),
        children: [
          SizedBox(
            width: 420,
            height: 420,
            child: ListView(
              children: [
                for (final m in models.take(200))
                  ListTile(
                    dense: true,
                    title: Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      m.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: m.free
                        ? const Chip(
                            label: Text('FREE'),
                            visualDensity: VisualDensity.compact,
                          )
                        : null,
                    onTap: () => Navigator.pop(context, m.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null && mounted) {
      app.ai.model = picked;
      modelCtl.text = picked;
      setState(() {});
    }
  }

  Widget _aiCard(AppState app, ColorScheme cs) {
    final ai = app.ai;
    return _card('AI assistant (optional)', Icons.auto_awesome, [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Enable the assistant'),
        subtitle: const Text(
          'Off by default. Adds an Assistant tab where you can chat about what to watch.',
        ),
        value: ai.enabled,
        onChanged: (v) {
          ai.enabled = v;
          app.resetAssistant();
        },
      ),
      Text(
        'Provider: OpenRouter (bring your own key)',
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: cs.primary),
      ),
      const SizedBox(height: 8),
      if (ai.hasKey && !replacingKey)
        Row(
          children: [
            const Icon(Icons.check_circle, size: 18, color: Atlas.sage),
            const SizedBox(width: 8),
            const Expanded(child: Text('API key saved (hidden).')),
            TextButton(
              onPressed: () => setState(() => replacingKey = true),
              child: const Text('Replace'),
            ),
            TextButton(
              onPressed: () {
                ai.removeKey();
                app.resetAssistant();
                setState(() {
                  aiMsg = 'Key removed.';
                  aiOk = true;
                });
              },
              child: const Text('Remove key'),
            ),
          ],
        )
      else
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: keyCtl,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'OpenRouter API key',
                  isDense: true,
                ),
                onSubmitted: (_) => _saveKey(app),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _saveKey(app),
              child: const Text('Save'),
            ),
          ],
        ),
      const SizedBox(height: 14),
      TextField(
        controller: modelCtl,
        decoration: const InputDecoration(labelText: 'Model id', isDense: true),
        onChanged: (v) => ai.model = v,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (id, label) in AiSettings.presets)
            ActionChip(
              label: Text(label),
              onPressed: () {
                ai.model = id;
                modelCtl.text = id;
                setState(() {});
              },
            ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 10,
        runSpacing: 6,
        children: [
          OutlinedButton.icon(
            onPressed: aiBusy || !ai.hasKey ? null : () => _loadModels(app),
            icon: const Icon(Icons.list),
            label: const Text('Load models'),
          ),
          FilledButton.icon(
            onPressed: aiBusy || !ai.hasKey ? null : () => _testAi(app),
            icon: const Icon(Icons.bolt),
            label: const Text('Test connection'),
          ),
        ],
      ),
      if (aiMsg.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            aiMsg,
            style: TextStyle(color: aiOk ? cs.primary : cs.error),
          ),
        ),
      const Divider(height: 28),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Allow the assistant to read my library and ratings'),
        subtitle: const Text(
          'Needed for personalised picks, taste summaries and "why this?". Off by default.',
        ),
        value: ai.libraryAllowed,
        onChanged: (v) => setState(() => ai.libraryAllowed = v),
      ),
      const SizedBox(height: 6),
      Text(
        'Privacy: what you type, and the catalog results the assistant looks up (titles, short descriptions, scores), are sent to OpenRouter '
        'and the model you chose. With the switch above on, a compact summary of your taste and library (titles and ratings it asks for) is sent too. '
        'Nothing is sent while the assistant is off. Changes to your plan or ratings only happen after you confirm them. '
        '${kIsWeb ? 'In this web version the key is kept in this browser\'s localStorage (not encrypted, only on this device).' : 'The key is stored in this app\'s private storage on this device (not in your backups).'} '
        'It is only ever sent to openrouter.ai.',
        style: TextStyle(
          color: cs.onSurfaceVariant,
          fontSize: 12,
          height: 1.45,
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final checked = app.lastChecked;
    return CustomScrollView(
      slivers: [
        const SliverAppBar(floating: true, snap: true, title: Text('Settings')),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                child: Column(
                  children: [
                    _card('Not for me', Icons.thumb_down_outlined, [
                      const Text(
                        'When you press “Not for me”, ask what put you off so only those parts get pushed down.',
                        style: TextStyle(height: 1.35),
                      ),
                      const SizedBox(height: 10),
                      SegmentedButton<String>(
                        key: const ValueKey('ask-why'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'sheet', label: Text('Ask')),
                          ButtonSegment(
                            value: 'snackbar',
                            label: Text('Offer after'),
                          ),
                          ButtonSegment(value: 'never', label: Text('Never')),
                        ],
                        selected: {app.askWhyMode},
                        onSelectionChanged: (v) => app.setAskWhyMode(v.first),
                      ),
                    ]),
                    _card('Your data', Icons.save_alt, [
                      Text(
                        '${app.entries.length} entries (ratings, reasons, plan/skip/ignore lists). Everything is stored on this device; '
                        '${kIsWeb ? 'They live in this browser\'s local storage (not cookies) — export a backup to move them to another browser or device.' : 'a rolling daily backup is also kept in ${app.backupDir.path}.'}',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _export,
                            icon: const Icon(Icons.upload),
                            label: const Text('Export backup…'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _restore,
                            icon: const Icon(Icons.download),
                            label: const Text('Restore backup…'),
                          ),
                        ],
                      ),
                      if (app.backupError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            'Automatic backup problem: ${app.backupError}',
                            style: TextStyle(color: cs.error),
                          ),
                        ),
                      if (backupMsg.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            backupMsg,
                            style: TextStyle(color: cs.primary),
                          ),
                        ),
                    ]),
                    _aiCard(app, cs),
                    if (!kIsWeb)
                      _card('Catalog', Icons.storage, [
                        Text(
                          '${app.data.n} titles · built ${app.data.meta['built_at']} · source: ${{'bundled': 'bundled with the app', 'file': 'a file you chose', 'url': 'auto-update address'}[app.catalogSource]}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Swapping the database never touches your ratings — they are linked by title id.',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Replace the catalog, or apply an update file',
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(color: cs.primary),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 10,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: app.catalogBusy ? null : _pickDb,
                              icon: const Icon(Icons.folder_open),
                              label: const Text(
                                'Choose catalog or update file…',
                              ),
                            ),
                            if (app.catalogSource != 'bundled')
                              TextButton.icon(
                                onPressed: app.catalogBusy
                                    ? null
                                    : app.resetCatalog,
                                icon: const Icon(Icons.restore),
                                label: const Text('Back to bundled'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Or fetch from an address (stays up to date)',
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(color: cs.primary),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: url,
                          decoration: const InputDecoration(
                            hintText:
                                'https://example.com/catalog.db   (.db or .db.gz)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (v) => app.setCatalogUrl(v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text(
                            'Check for a new version every time the app starts',
                          ),
                          subtitle: const Text(
                            'Downloads only when the file changed on the server',
                          ),
                          value: app.autoCheck,
                          onChanged: (v) =>
                              app.setCatalogUrl(url.text, auto: v),
                        ),
                        Wrap(
                          spacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: app.catalogBusy
                                  ? null
                                  : () async {
                                      app.setCatalogUrl(url.text);
                                      await app.checkForUpdate(force: false);
                                    },
                              icon: const Icon(Icons.sync),
                              label: const Text('Save & check now'),
                            ),
                            OutlinedButton(
                              onPressed:
                                  app.catalogBusy || url.text.trim().isEmpty
                                  ? null
                                  : () async {
                                      app.setCatalogUrl(url.text);
                                      await app.checkForUpdate(force: true);
                                    },
                              child: const Text('Force re-download'),
                            ),
                          ],
                        ),
                        if (app.downloadProgress != null || app.catalogBusy)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: LinearProgressIndicator(
                              value: app.downloadProgress,
                            ),
                          ),
                        if (app.catalogStatus.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              app.catalogStatus,
                              style: TextStyle(color: cs.primary),
                            ),
                          ),
                        if (checked != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Last checked ${checked.substring(0, 16).replaceAll('T', ' ')}',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'The file must be a catalog.db produced by tools/export.py (schema 1). Anything else is rejected and the current database stays active.',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
