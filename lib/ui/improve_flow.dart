import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../assistant/llm.dart';
import '../assistant/taste_ai.dart';
import '../engine/recommender.dart';
import '../engine/taste_layer.dart';
import 'theme.dart';

/// "Improve my taste profile" / the cold-start interview. Steps: show exactly what will be sent -> Send ->
/// test the proposal on the user's own ratings -> review (accept / reject / edit) -> apply as the AI taste layer.
/// Nothing is sent before the Send tap.
Future<void> startImprove(BuildContext context) async {
  final app = context.read<AppState>();
  if (!app.canImproveProfile) return;
  final req = app.tasteRequest();
  final send = await showDialog<bool>(
    context: context,
    builder: (_) => _PreviewDialog(req: req, model: app.ai.model),
  );
  if (send != true || !context.mounted) return;

  final nav = Navigator.of(context);
  final status = ValueNotifier<String>('Asking ${app.ai.model}…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: status,
                builder: (_, s, _) => Text(s),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  TasteProposal? proposal;
  LayerEval? eval;
  String? error;
  try {
    proposal = await app.sendTasteRequest(req);
    if (!proposal.interview && proposal.rules.isNotEmpty) {
      status.value = 'Testing it on your own ratings…';
      eval = await app.evaluateRules(proposal.rules);
    }
  } on LlmException catch (e) {
    error = e.message;
  } on TasteAiException catch (e) {
    error = e.message;
  } catch (_) {
    error = 'Something went wrong. Nothing was changed.';
  }
  nav.pop(); // progress dialog
  if (!context.mounted) return;
  if (error != null) {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Could not improve the profile'),
        content: Text(error!),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: app,
        child: ReviewPage(proposal: proposal!, eval: eval ?? LayerEval.none),
      ),
    ),
  );
}

class _PreviewDialog extends StatelessWidget {
  final TasteRequest req;
  final String model;
  const _PreviewDialog({required this.req, required this.model});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        req.interview ? 'Taste interview' : 'Improve my taste profile',
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This exact text will be sent to OpenRouter (model $model) using your own key. Nothing is sent until you tap Send.'
              '${req.interview ? ' You have few ratings yet, so the assistant will interview you instead.' : ''}',
              style: const TextStyle(height: 1.4),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                key: const ValueKey('improve-preview'),
                padding: const EdgeInsets.all(10),
                decoration: Atlas.outline(radius: 8),
                child: SingleChildScrollView(
                  child: SelectableText(
                    req.preview,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11.5,
                      height: 1.35,
                      color: Atlas.body,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${req.preview.length} characters',
              style: const TextStyle(fontSize: 12, color: Atlas.faint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('improve-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('improve-send'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class ReviewPage extends StatefulWidget {
  final TasteProposal proposal;
  final LayerEval eval;
  const ReviewPage({super.key, required this.proposal, required this.eval});
  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late final Map<String, bool> accepted = {
    for (final r in widget.proposal.rules)
      r.id:
          widget.eval.perRule[r.id]?.$1 != LayerVerdict.worse &&
          widget.eval.verdict != LayerVerdict.worse,
  };
  late final Map<String, double> strength = {
    for (final r in widget.proposal.rules) r.id: 1.0,
  };
  final Map<int, int> chosen = {}; // question -> option
  final Map<int, TextEditingController> typed = {};

  @override
  void dispose() {
    for (final c in typed.values) {
      c.dispose();
    }
    super.dispose();
  }

  Color _verdictColor(LayerVerdict v) => switch (v) {
    LayerVerdict.helps => const Color(0xFF9ED8B5),
    LayerVerdict.worse => const Color(0xFFE08A7A),
    _ => Atlas.muted,
  };

  void _apply() {
    final app = context.read<AppState>();
    final p = widget.proposal;
    final byId = {for (final r in app.layer.rules) r.signature: r};
    for (final r in p.rules) {
      if (accepted[r.id] == true)
        byId[r.signature] = r.copyWith(strength: strength[r.id]);
    }
    final answers = [...app.layer.answers];
    for (var qi = 0; qi < p.questions.length; qi++) {
      final q = p.questions[qi];
      final o = chosen[qi];
      final text = typed[qi]?.text.trim() ?? '';
      if (o != null) {
        final opt = q.options[o];
        answers.add((q.text, opt.label));
        final r = opt.rule;
        if (r != null) byId[r.signature] = r;
      } else if (text.isNotEmpty) {
        answers.add((q.text, text));
      }
    }
    app.applyLayer(
      app.layer.copyWith(
        enabled: true,
        rules: byId.values.toList(),
        summary: p.summary.isEmpty ? app.layer.summary : p.summary,
        answers: answers,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final ev = widget.eval;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.interview ? 'Taste interview' : 'Review the proposal'),
        leading: const CloseButton(),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Nothing changes your ranking until you apply.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Discard'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('review-apply'),
                onPressed: _apply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (p.summary.isNotEmpty) ...[
            const Text('SUMMARY', style: Atlas.kicker),
            const SizedBox(height: 6),
            Text(p.summary, style: const TextStyle(height: 1.45)),
            const SizedBox(height: 16),
          ],
          if (!p.interview && p.rules.isNotEmpty)
            Container(
              key: const ValueKey('gate-verdict'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _verdictColor(ev.verdict).withValues(alpha: .6),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ev.verdict == LayerVerdict.worse
                        ? Icons.warning_amber_rounded
                        : Icons.science_outlined,
                    size: 18,
                    color: _verdictColor(ev.verdict),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${ev.text}${ev.verdict == LayerVerdict.worse ? ' Not recommended: these are off by default.' : ''}',
                      style: const TextStyle(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          if (p.rules.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('PROPOSED ADJUSTMENTS', style: Atlas.kicker),
            const SizedBox(height: 8),
            for (final r in p.rules) _ruleCard(r),
          ],
          if (p.contradictions.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('THINGS THAT DON\'T ADD UP', style: Atlas.kicker),
            const SizedBox(height: 6),
            for (final c in p.contradictions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $c', style: const TextStyle(height: 1.4)),
              ),
          ],
          if (p.questions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              p.interview ? 'QUESTIONS' : 'QUESTIONS THAT WOULD SHARPEN IT',
              style: Atlas.kicker,
            ),
            const SizedBox(height: 8),
            for (var qi = 0; qi < p.questions.length; qi++)
              _question(qi, p.questions[qi]),
          ],
        ],
      ),
    );
  }

  Widget _ruleCard(LayerRule r) {
    final v = widget.eval.perRule[r.id];
    final on = accepted[r.id] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: Atlas.outline(radius: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(r.text, style: Atlas.serif(size: 17))),
              if (v != null && v.$1 == LayerVerdict.worse)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text(
                    'NOT RECOMMENDED',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      color: Color(0xFFE08A7A),
                    ),
                  ),
                ),
              Switch(
                key: ValueKey('rule-accept-${r.id}'),
                value: on,
                onChanged: (x) => setState(() => accepted[r.id] = x),
              ),
            ],
          ),
          if (r.why.isNotEmpty)
            Text(r.why, style: const TextStyle(height: 1.4, color: Atlas.body)),
          if (r.cites.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Based on: ${r.cites.join(', ')}',
                style: const TextStyle(fontSize: 12.5, color: Atlas.muted),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Confidence ${(r.confidence * 100).round()}%${v == null ? '' : ' · on your ratings: ${switch (v.$1) {
                      LayerVerdict.helps => 'helps',
                      LayerVerdict.worse => 'hurts',
                      _ => 'no measurable change',
                    }}'}',
              style: TextStyle(
                fontSize: 12.5,
                color: v == null ? Atlas.muted : _verdictColor(v.$1),
              ),
            ),
          ),
          if (on)
            Row(
              children: [
                const Text(
                  'Strength',
                  style: TextStyle(fontSize: 12.5, color: Atlas.muted),
                ),
                Expanded(
                  child: Slider(
                    key: ValueKey('rule-strength-${r.id}'),
                    value: strength[r.id]!,
                    min: .1,
                    max: 1.5,
                    onChanged: (x) => setState(() => strength[r.id] = x),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _question(int qi, TasteQuestion q) {
    final ctl = typed.putIfAbsent(qi, TextEditingController.new);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: Atlas.outline(radius: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            q.text,
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (var oi = 0; oi < q.options.length; oi++)
                ChoiceChip(
                  key: ValueKey('q-opt-$qi-$oi'),
                  label: Text(q.options[oi].label),
                  selected: chosen[qi] == oi,
                  onSelected: (s) =>
                      setState(() => s ? chosen[qi] = oi : chosen.remove(qi)),
                ),
            ],
          ),
          if (!widget.proposal.interview)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: ctl,
                decoration: const InputDecoration(
                  hintText: 'Or answer in your own words (optional)',
                  isDense: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The "AI taste layer" card on the taste page: global switch + strength, every rule on its own, undo, reset.
class TasteLayerCard extends StatelessWidget {
  const TasteLayerCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = app.layer;
    final cs = Theme.of(context).colorScheme;
    final rated = app.entries.values
        .where((e) => e.status == EntryStatus.watched && e.rating != null)
        .length;
    final interview = rated < interviewBelow;
    final why = !app.ai.enabled || !app.ai.hasKey
        ? 'Switch on the assistant and add your OpenRouter key in Settings → AI assistant.'
        : !app.ai.libraryAllowed
        ? 'Allow the assistant to read your library in Settings → AI assistant. It is off by default.'
        : null;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: Atlas.outline(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('AI TASTE LAYER', style: Atlas.kicker),
          const SizedBox(height: 6),
          l.isEmpty || l.summary.isEmpty
              ? Text(
                  l.isEmpty
                      ? 'An optional, separate layer on top of what the app learns from your ratings. An AI reads your ratings, reasons and notes and proposes adjustments you can accept or reject. Nothing is sent until you approve it.'
                      : 'Your accepted adjustments sit on top of the learned weights.',
                  style: const TextStyle(height: 1.45, color: Atlas.body),
                )
              : Text(
                  l.summary,
                  style: const TextStyle(height: 1.45, color: Atlas.body),
                ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('improve-button'),
                onPressed: why == null ? () => startImprove(context) : null,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: Text(
                  interview
                      ? 'Start taste interview'
                      : 'Improve my taste profile',
                ),
              ),
              if (app.layerPrev != null)
                OutlinedButton(
                  key: const ValueKey('layer-undo'),
                  onPressed: app.undoLayer,
                  child: const Text('Undo last change'),
                ),
              if (!l.isEmpty)
                OutlinedButton(
                  key: const ValueKey('layer-reset'),
                  onPressed: app.resetLayer,
                  child: const Text('Reset'),
                ),
            ],
          ),
          if (why != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                why,
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
            ),
          if (l.rules.isNotEmpty) ...[
            const SizedBox(height: 12),
            SwitchListTile(
              key: const ValueKey('layer-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Use the AI layer in my recommendations'),
              value: l.enabled,
              onChanged: (v) => app.updateLayer(l.copyWith(enabled: v)),
            ),
            Row(
              children: [
                const Text(
                  'Overall strength',
                  style: TextStyle(fontSize: 12.5, color: Atlas.muted),
                ),
                Expanded(
                  child: Slider(
                    key: const ValueKey('layer-strength'),
                    value: l.strength,
                    min: 0,
                    max: 1.5,
                    onChanged: l.enabled
                        ? (v) => app.updateLayer(l.copyWith(strength: v))
                        : null,
                  ),
                ),
              ],
            ),
            for (final r in l.rules)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.text,
                            style: TextStyle(
                              color: r.enabled && l.enabled
                                  ? null
                                  : Atlas.faint,
                            ),
                          ),
                        ),
                        Switch(
                          key: ValueKey('layer-rule-${r.id}'),
                          value: r.enabled,
                          onChanged: l.enabled
                              ? (v) => app.updateLayer(
                                  l.copyWith(
                                    rules: [
                                      for (final x in l.rules)
                                        x.id == r.id
                                            ? x.copyWith(enabled: v)
                                            : x,
                                    ],
                                  ),
                                )
                              : null,
                        ),
                        IconButton(
                          tooltip: 'Delete rule',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => app.updateLayer(
                            l.copyWith(
                              rules: [
                                for (final x in l.rules)
                                  if (x.id != r.id) x,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (r.why.isNotEmpty)
                      Text(
                        r.why,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Atlas.muted,
                          height: 1.35,
                        ),
                      ),
                  ],
                ),
              ),
            if (l.changes.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('CHANGED IN THE LAST RUN', style: Atlas.kicker),
              const SizedBox(height: 4),
              for (final c in l.changes)
                Text(
                  '• $c',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Atlas.muted,
                    height: 1.4,
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
