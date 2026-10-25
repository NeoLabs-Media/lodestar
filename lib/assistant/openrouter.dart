import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm.dart';

/// OpenRouter (https://openrouter.ai), OpenAI-compatible. Calls go straight from the app to
/// openrouter.ai; the key is only ever sent there, in the Authorization header.
class OpenRouterProvider implements LlmProvider {
  static const base = 'https://openrouter.ai/api/v1';
  static const referer = 'https://neolabs-media.github.io/lodestar/';
  static const title = 'Lodestar';

  final String apiKey;
  final http.Client _http;
  OpenRouterProvider(this.apiKey, {http.Client? client})
    : _http = client ?? http.Client();

  @override
  String get id => 'openrouter';
  @override
  String get label => 'OpenRouter';

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'HTTP-Referer': referer,
    'X-Title': title,
  };

  LlmException _statusError(http.Response r) {
    String detail = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      detail =
          '${(j['error'] is Map ? j['error']['message'] : j['error']) ?? ''}';
    } catch (_) {}
    detail = redact(detail, apiKey);
    switch (r.statusCode) {
      case 401:
      case 403:
        return const LlmException(
          LlmErrorKind.auth,
          'OpenRouter rejected the API key. Check it in Settings → AI assistant.',
        );
      case 402:
        return const LlmException(
          LlmErrorKind.credits,
          'Not enough OpenRouter credits for this model. Add credits or pick a free model.',
        );
      case 429:
        return const LlmException(
          LlmErrorKind.rateLimit,
          'Rate limit reached (free models are limited). Wait a moment or try another model.',
        );
      case 400:
        final noTools = detail.toLowerCase().contains('tool');
        return LlmException(
          noTools ? LlmErrorKind.unsupported : LlmErrorKind.badRequest,
          noTools
              ? 'This model does not support tool calling. Pick another model.'
              : 'OpenRouter could not process the request${detail.isEmpty ? '' : ': $detail'}.',
        );
      case 404:
        return const LlmException(
          LlmErrorKind.badRequest,
          'That model was not found on OpenRouter. Check the model id.',
        );
      default:
        return LlmException(
          LlmErrorKind.server,
          'OpenRouter had a problem (HTTP ${r.statusCode}). Try again shortly.',
        );
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const LlmException(
        LlmErrorKind.network,
        'OpenRouter did not answer in time. Check your connection and try again.',
      );
    } catch (e) {
      if (e is LlmException) rethrow;
      throw const LlmException(
        LlmErrorKind.network,
        'Could not reach OpenRouter. Check your internet connection.',
      );
    }
  }

  @override
  Future<LlmResponse> chat({
    required String model,
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    if (apiKey.isEmpty)
      throw const LlmException(LlmErrorKind.noKey, 'No API key set.');
    final body = {
      'model': model,
      'messages': [for (final m in messages) m.toJson()],
      if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toJson()],
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      'temperature': 0.4,
      'usage': {'include': true},
    };
    final r = await _send(
      () => _http.post(
        Uri.parse('$base/chat/completions'),
        headers: _headers,
        body: jsonEncode(body),
      ),
    );
    if (r.statusCode != 200) throw _statusError(r);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (j['error'] != null) {
        // OpenRouter sometimes returns 200 with an error object (upstream provider failure)
        final msg = redact(
          '${(j['error'] as Map)['message'] ?? 'upstream error'}',
          apiKey,
        );
        throw LlmException(
          LlmErrorKind.server,
          'The model provider reported an error: $msg',
        );
      }
      final msg =
          (j['choices'] as List).first['message'] as Map<String, dynamic>;
      final calls = [
        for (final t in (msg['tool_calls'] as List?) ?? const [])
          ToolCall(
            '${t['id']}',
            '${t['function']['name']}',
            '${t['function']['arguments'] ?? '{}'}',
          ),
      ];
      final u = (j['usage'] as Map?) ?? const {};
      return LlmResponse(
        ChatMessage('assistant', msg['content'] as String?, toolCalls: calls),
        Usage(
          promptTokens: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
          completionTokens: (u['completion_tokens'] as num?)?.toInt() ?? 0,
          cost: (u['cost'] as num?)?.toDouble(),
        ),
      );
    } on LlmException {
      rethrow;
    } catch (_) {
      throw const LlmException(
        LlmErrorKind.badRequest,
        'Unexpected answer from OpenRouter. Try again or pick another model.',
      );
    }
  }

  @override
  Future<List<ModelInfo>> listModels() async {
    final r = await _send(
      () => _http.get(
        Uri.parse('$base/models'),
        headers: apiKey.isEmpty
            ? {'Content-Type': 'application/json'}
            : _headers,
      ),
    );
    if (r.statusCode != 200) throw _statusError(r);
    final data = (jsonDecode(utf8.decode(r.bodyBytes))['data'] as List)
        .cast<Map<String, dynamic>>();
    final out = <ModelInfo>[];
    for (final m in data) {
      final params = ((m['supported_parameters'] as List?) ?? const [])
          .cast<String>();
      if (!params.contains('tools')) continue;
      final p = (m['pricing'] as Map?) ?? const {};
      final free =
          '${p['prompt']}' == '0' && '${p['completion']}' == '0' ||
          '${m['id']}'.endsWith(':free');
      out.add(
        ModelInfo(
          '${m['id']}',
          '${m['name'] ?? m['id']}',
          free: free,
          contextLength: (m['context_length'] as num?)?.toInt(),
          created: (m['created'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.sort((a, b) {
      if (a.free != b.free) return a.free ? -1 : 1;
      return b.created != a.created
          ? b.created.compareTo(a.created)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<ConnectionResult> test(String model) async {
    if (apiKey.isEmpty)
      return const ConnectionResult(false, 'Enter an API key first.');
    try {
      final r = await _send(
        () => _http.get(Uri.parse('$base/auth/key'), headers: _headers),
      );
      if (r.statusCode != 200)
        return ConnectionResult(false, _statusError(r).message);
      final models = await listModels();
      final found = models.where((m) => m.id == model);
      if (found.isEmpty) {
        return ConnectionResult(
          false,
          'Key works, but "$model" is not a tool-capable model on OpenRouter. Use “Load models” to pick one.',
        );
      }
      return ConnectionResult(
        true,
        'Connected. Key works and ${found.first.name} supports tools${found.first.free ? ' (free model, rate-limited)' : ''}.',
      );
    } on LlmException catch (e) {
      return ConnectionResult(false, e.message);
    }
  }
}
