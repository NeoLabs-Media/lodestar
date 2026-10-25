/// Provider-agnostic chat + tool-calling types. OpenRouter is the only provider today
/// (openrouter.dart); another OpenAI-compatible provider only needs to implement [LlmProvider].
library;

class ToolCall {
  final String id, name;
  final String arguments; // raw JSON text as sent by the model
  const ToolCall(this.id, this.name, this.arguments);
}

class ChatMessage {
  final String role; // system | user | assistant | tool
  final String? content;
  final List<ToolCall> toolCalls;
  final String? toolCallId; // for role == tool
  const ChatMessage(
    this.role,
    this.content, {
    this.toolCalls = const [],
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
    'role': role,
    if (content != null || toolCalls.isEmpty) 'content': content ?? '',
    if (toolCalls.isNotEmpty)
      'tool_calls': [
        for (final t in toolCalls)
          {
            'id': t.id,
            'type': 'function',
            'function': {'name': t.name, 'arguments': t.arguments},
          },
      ],
    if (toolCallId != null) 'tool_call_id': toolCallId,
  };
}

class ToolSpec {
  final String name, description;
  final Map<String, dynamic> parameters; // JSON schema
  const ToolSpec(this.name, this.description, this.parameters);
  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

class Usage {
  final int promptTokens, completionTokens;
  final double? cost; // USD when the provider reports it
  const Usage({this.promptTokens = 0, this.completionTokens = 0, this.cost});
  Usage operator +(Usage o) => Usage(
    promptTokens: promptTokens + o.promptTokens,
    completionTokens: completionTokens + o.completionTokens,
    cost: (cost == null && o.cost == null) ? null : (cost ?? 0) + (o.cost ?? 0),
  );
  int get total => promptTokens + completionTokens;
}

class LlmResponse {
  final ChatMessage message;
  final Usage usage;
  const LlmResponse(this.message, this.usage);
}

class ModelInfo {
  final String id, name;
  final bool free;
  final int? contextLength;
  final int created; // unix seconds, newest first in listings
  const ModelInfo(
    this.id,
    this.name, {
    this.free = false,
    this.contextLength,
    this.created = 0,
  });
}

enum LlmErrorKind {
  noKey,
  auth,
  credits,
  rateLimit,
  network,
  badRequest,
  server,
  unsupported,
}

/// Failure with a message that is safe to show (never contains the API key).
class LlmException implements Exception {
  final LlmErrorKind kind;
  final String message;
  const LlmException(this.kind, this.message);
  @override
  String toString() => message;
}

class ConnectionResult {
  final bool ok;
  final String message;
  const ConnectionResult(this.ok, this.message);
}

abstract class LlmProvider {
  String get id;
  String get label;

  /// One chat completion. [tools] empty = plain answer. Throws [LlmException].
  Future<LlmResponse> chat({
    required String model,
    required List<ChatMessage> messages,
    List<ToolSpec> tools = const [],
  });

  /// Models that support tool calling: free ones first, newest first within each group.
  Future<List<ModelInfo>> listModels();

  /// Validates the key and that [model] supports tools.
  Future<ConnectionResult> test(String model);
}

/// Removes every occurrence of [secret] from [text] (used on anything that could be logged or shown).
String redact(String text, String? secret) {
  if (secret == null || secret.length < 4) return text;
  return text.replaceAll(secret, '[key]');
}
