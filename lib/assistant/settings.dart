import 'dart:convert';

import '../data/user_store.dart';
import '../engine/recommender.dart';

/// AI assistant settings, stored in the same app storage as every other setting
/// (user.db on native platforms, the browser's localStorage on web). The API key lives there too:
/// it is never exported in backups, never logged, and only ever sent to the provider.
class AiSettings {
  final UserStore _s;
  AiSettings(this._s);

  static const defaultModel = 'nvidia/nemotron-3.5-super-vl:free';

  /// Suggestions only (checked against OpenRouter's live model list on 25 Oct 2026; this list ages quickly,
  /// so "Load models" in Settings, which lists everything currently tool-capable newest-first, is the source of truth).
  static const presets = <(String id, String label)>[
    ('nvidia/nemotron-3.5-super-vl:free', 'Nemotron 3.5 Super (free)'),
    ('anthropic/claude-haiku-5.5', 'Claude Haiku 5.5 (cheap, fast)'),
    ('anthropic/claude-sonnet-5.5', 'Claude Sonnet 5.5'),
    ('openai/gpt-6.1-sol', 'GPT-6.1 Sol'),
    ('google/gemini-4-argon', 'Gemini 4 Argon'),
    ('moonshotai/kimi-k3.1-pro', 'Kimi K3.1 Pro'),
  ];

  bool get enabled => _s.setting('ai.enabled') == '1';
  set enabled(bool v) => _s.setSetting('ai.enabled', v ? '1' : '0');

  String get provider => _s.setting('ai.provider') ?? 'openrouter';

  String get model {
    final m = _s.setting('ai.model');
    return (m == null || m.trim().isEmpty) ? defaultModel : m.trim();
  }

  set model(String v) => _s.setSetting('ai.model', v.trim());

  /// Allow tools to read the library, ratings and taste profile (default off).
  bool get libraryAllowed => _s.setting('ai.library') == '1';
  set libraryAllowed(bool v) => _s.setSetting('ai.library', v ? '1' : '0');

  /// Spoiler switch (default off = spoiler-free). Enforced in the tools, not only in the prompt.
  bool get spoilers => _s.setting('ai.spoilers') == '1';
  set spoilers(bool v) => _s.setSetting('ai.spoilers', v ? '1' : '0');

  /// true (default): the chat uses the same filters as the For-you feed; false: it has its own.
  bool get useFeedFilters => _s.setting('ai.syncFilters') != '0';
  set useFeedFilters(bool v) => _s.setSetting('ai.syncFilters', v ? '1' : '0');

  /// The chat's own filters (used when [useFeedFilters] is off).
  Controls loadChatFilters() {
    try {
      final j = _s.setting('ai.filters');
      if (j != null && j.isNotEmpty)
        return Controls.fromJson(
          (jsonDecode(j) as Map).cast<String, dynamic>(),
        );
    } catch (_) {}
    return Controls();
  }

  void saveChatFilters(Controls c) =>
      _s.setSetting('ai.filters', jsonEncode(c.toJson()));

  String? get apiKey {
    final k = _s.setting('ai.key');
    return (k == null || k.isEmpty) ? null : k;
  }

  bool get hasKey => apiKey != null;

  void saveKey(String key) => _s.setSetting('ai.key', key.trim());
  void removeKey() => _s.setSetting('ai.key', '');

  /// Ready to chat: switched on and a key is saved.
  bool get ready => enabled && hasKey;
}
