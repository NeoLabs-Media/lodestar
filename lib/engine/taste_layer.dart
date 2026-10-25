import 'dart:convert';

import 'labels.dart';

enum RuleType { facet, dimension, exclude, conditional }

/// One accepted adjustment of the "AI taste layer". It sits on top of the learned weights and never
/// changes them; the user can switch, weaken or delete every rule on its own.
class LayerRule {
  final String id;
  final RuleType type;

  /// facet / exclude: the facet. conditional: the facet that is boosted or penalised when [ifKind]|[ifValue] is also present.
  final String kind, value;
  final String ifKind, ifValue; // conditional only
  final String dim; // dimension only
  final int dir; // +1 boost / high, -1 penalise / low
  final double magnitude; // 0..1 as proposed
  final double strength; // 0..1.5, the user's slider for this rule
  final bool enabled;
  final String why; // one sentence, cites the user's own titles
  final List<String> cites;
  final double confidence; // 0..1

  const LayerRule({
    required this.id,
    required this.type,
    this.kind = '',
    this.value = '',
    this.ifKind = '',
    this.ifValue = '',
    this.dim = '',
    this.dir = 1,
    this.magnitude = .5,
    this.strength = 1,
    this.enabled = true,
    this.why = '',
    this.cites = const [],
    this.confidence = .5,
  });

  LayerRule copyWith({double? strength, bool? enabled}) => LayerRule(
    id: id,
    type: type,
    kind: kind,
    value: value,
    ifKind: ifKind,
    ifValue: ifValue,
    dim: dim,
    dir: dir,
    magnitude: magnitude,
    strength: strength ?? this.strength,
    enabled: enabled ?? this.enabled,
    why: why,
    cites: cites,
    confidence: confidence,
  );

  /// Same rule regardless of its strength (used to show what changed between runs).
  String get signature =>
      '${type.name}|$kind|$value|$ifKind|$ifValue|$dim|$dir';

  /// Plain-words description, e.g. "Prefer slow-burn romance" or "If romance: penalise school setting".
  String get text {
    String f(String k, String v) => facetChipLabel(k, v).toLowerCase();
    final d = dim.replaceAll('_', ' ');
    return switch (type) {
      RuleType.facet => '${dir > 0 ? 'Prefer' : 'Avoid'} ${f(kind, value)}',
      RuleType.dimension => dir > 0 ? 'Prefer high $d' : 'Prefer low $d',
      RuleType.exclude => 'Never show ${f(kind, value)}',
      RuleType.conditional =>
        'When it has ${f(ifKind, ifValue)}: ${dir > 0 ? 'boost' : 'penalise'} ${f(kind, value)}',
    };
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    if (kind.isNotEmpty) 'kind': kind,
    if (value.isNotEmpty) 'value': value,
    if (ifKind.isNotEmpty) 'if_kind': ifKind,
    if (ifValue.isNotEmpty) 'if_value': ifValue,
    if (dim.isNotEmpty) 'dim': dim,
    'dir': dir,
    'magnitude': magnitude,
    'strength': strength,
    'enabled': enabled,
    'why': why,
    'cites': cites,
    'confidence': confidence,
  };

  static LayerRule? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = RuleType.values.where((t) => t.name == j['type']).firstOrNull;
    if (type == null) return null;
    String s(String k) => '${j[k] ?? ''}';
    double n(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    return LayerRule(
      id: s('id').isEmpty ? '${type.name}-${j.hashCode}' : s('id'),
      type: type,
      kind: s('kind'),
      value: s('value'),
      ifKind: s('if_kind'),
      ifValue: s('if_value'),
      dim: s('dim'),
      dir: (j['dir'] as num?)?.toInt() == -1 ? -1 : 1,
      magnitude: n('magnitude', .5).clamp(0.0, 1.0),
      strength: n('strength', 1).clamp(0.0, 1.5),
      enabled: j['enabled'] != false,
      why: s('why'),
      cites: [for (final c in (j['cites'] as List?) ?? const []) '$c'],
      confidence: n('confidence', .5).clamp(0.0, 1.0),
    );
  }
}

/// The whole layer: rules the user accepted, a global switch and strength, plus the model's summary,
/// the answers to its questions and a short note of what the last run changed.
class TasteLayer {
  final bool enabled;
  final double strength; // global 0..1.5
  final List<LayerRule> rules;
  final String summary;
  final List<(String question, String answer)> answers;
  final List<String> changes; // what the last accepted run added / removed
  final int updatedAt;

  const TasteLayer({
    this.enabled = true,
    this.strength = 1,
    this.rules = const [],
    this.summary = '',
    this.answers = const [],
    this.changes = const [],
    this.updatedAt = 0,
  });

  bool get isEmpty => rules.isEmpty && summary.isEmpty && answers.isEmpty;

  /// Is anything of it actually steering the ranking?
  bool get active => enabled && strength > 0.02 && rules.any((r) => r.enabled);

  TasteLayer copyWith({
    bool? enabled,
    double? strength,
    List<LayerRule>? rules,
    String? summary,
    List<(String, String)>? answers,
    List<String>? changes,
    int? updatedAt,
  }) => TasteLayer(
    enabled: enabled ?? this.enabled,
    strength: strength ?? this.strength,
    rules: rules ?? this.rules,
    summary: summary ?? this.summary,
    answers: answers ?? this.answers,
    changes: changes ?? this.changes,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'enabled': enabled,
    'strength': strength,
    'rules': [for (final r in rules) r.toJson()],
    'summary': summary,
    'answers': [
      for (final a in answers) {'q': a.$1, 'a': a.$2},
    ],
    'changes': changes,
    'updated_at': updatedAt,
  };

  String encode() => jsonEncode(toJson());

  static TasteLayer? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is! Map) return null;
      return TasteLayer(
        enabled: j['enabled'] != false,
        strength: ((j['strength'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.5),
        rules: [
          for (final r in (j['rules'] as List?) ?? const [])
            if (LayerRule.fromJson(r) case final x?) x,
        ],
        summary: '${j['summary'] ?? ''}',
        answers: [
          for (final a in (j['answers'] as List?) ?? const [])
            if (a is Map) ('${a['q']}', '${a['a']}'),
        ],
        changes: [for (final c in (j['changes'] as List?) ?? const []) '$c'],
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Lines describing what differs from [old] (rules added, removed, re-weighted).
  List<String> diffFrom(TasteLayer? old) {
    final before = {
      for (final r in old?.rules ?? const <LayerRule>[]) r.signature: r,
    };
    final after = {for (final r in rules) r.signature: r};
    return [
      for (final e in after.entries)
        if (!before.containsKey(e.key)) 'Added: ${e.value.text}',
      for (final e in before.entries)
        if (!after.containsKey(e.key)) 'Removed: ${e.value.text}',
      for (final e in after.entries)
        if (before[e.key] != null &&
            (before[e.key]!.strength - e.value.strength).abs() > .05)
          'Changed strength: ${e.value.text}',
    ];
  }
}
