import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../assistant/session.dart';
import '../assistant/tools.dart';
import 'chat_markdown.dart';
import 'detail_page.dart';
import 'filter_panel.dart';
import 'improve_flow.dart';
import 'not_for_me.dart';
import 'theme.dart';
import 'widgets.dart';

/// Optional chat assistant. Off by default: explains how to enable it instead of failing.
class AssistantPage extends StatelessWidget {
  final VoidCallback onOpenSettings;
  const AssistantPage({super.key, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pad = wide ? 56.0 : 20.0;
    if (!app.ai.ready) {
      return Padding(
        padding: EdgeInsets.fromLTRB(pad, wide ? 42 : 22, pad, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('OPTIONAL', style: Atlas.kicker),
            const SizedBox(height: 10),
            Text(
              'Assistant',
              style: Atlas.serif(size: wide ? 48 : 36, height: 1),
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: Atlas.outline(radius: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.ai.enabled
                          ? 'The assistant is switched on but has no API key yet.'
                          : 'Ask for recommendations in plain language — "something like Monster but lighter", "a movie for tonight under two hours".',
                      style: const TextStyle(height: 1.5, color: Atlas.body),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'It is off by default. To use it, add your own OpenRouter API key in Settings → AI assistant. '
                      'It searches this catalog with tools and uses the app\'s own recommender; it never invents titles, and it only reads your library if you allow that.',
                      style: TextStyle(
                        height: 1.5,
                        color: Atlas.muted,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: onOpenSettings,
                      child: const Text('Open settings'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _Chat(session: app.assistant, pad: pad, wide: wide);
  }
}

class _Chat extends StatefulWidget {
  final AssistantSession session;
  final double pad;
  final bool wide;
  const _Chat({required this.session, required this.pad, required this.wide});
  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final input = TextEditingController();
  final scroll = ScrollController();

  AssistantSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant _Chat old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onChange);
      widget.session.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    s.removeListener(_onChange);
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients)
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
    });
  }

  void _send([String? text]) {
    final t = (text ?? input.text).trim();
    if (t.isEmpty || s.busy) return;
    input.clear();
    s.send(t);
  }

  Future<void> _editFilters() async {
    final app = context.read<AppState>();
    if (app.ai.useFeedFilters) {
      await showFilters(
        context,
        title: 'Assistant filters · shared with For you',
      );
    } else {
      await showFilters(
        context,
        controls: app.chatControls,
        onChanged: app.setChatControls,
        title: 'Assistant filters',
      );
    }
    s.syncState();
  }

  static const examples = [
    'Something like Monster but lighter',
    'Hidden gems that fit my taste',
    'A movie for tonight, under 2 hours',
    'Short anime I can finish this week',
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            widget.pad,
            widget.wide ? 34 : 18,
            widget.pad,
            8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.ai.model.toUpperCase(),
                      style: Atlas.kicker,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Assistant',
                      style: Atlas.serif(
                        size: widget.wide ? 40 : 30,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: app.ai.spoilers
                    ? 'Spoilers on: plot, endings and character fates may be discussed'
                    : 'Spoilers off: plot twists, deaths and endings stay hidden',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      app.ai.spoilers
                          ? Icons.visibility
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color: Atlas.muted,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Spoilers',
                      style: TextStyle(fontSize: 12.5, color: Atlas.muted),
                    ),
                    Switch(
                      key: const ValueKey('spoiler-switch'),
                      value: app.ai.spoilers,
                      onChanged: app.setSpoilers,
                    ),
                  ],
                ),
              ),
              if (s.usageLine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 6),
                  child: Text(
                    s.usageLine,
                    style: const TextStyle(fontSize: 12, color: Atlas.muted),
                  ),
                ),
              IconButton(
                key: const ValueKey('assistant-improve'),
                tooltip: 'Improve my taste profile',
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: app.canImproveProfile
                    ? () => startImprove(context)
                    : null,
              ),
              IconButton(
                tooltip: 'Clear conversation',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: s.messages.isEmpty && s.pending.isEmpty
                    ? null
                    : s.clear,
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: s.messages.isEmpty
                  ? Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.pad > 30 ? 0 : 20,
                        vertical: 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ask for something to watch. It searches the catalog and uses the recommender — and only suggests titles that exist here.',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final e in examples)
                                ActionChip(
                                  label: Text(e),
                                  onPressed: () => _send(e),
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      controller: scroll,
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.pad > 30 ? 0 : 16,
                        vertical: 16,
                      ),
                      children: [
                        for (final m in s.messages) _Bubble(m),
                        for (final a in s.pending) _ConfirmCard(a, s),
                        if (s.busy)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                widget.pad > 30 ? 0 : 16,
                4,
                widget.pad > 30 ? 0 : 16,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FilterBar(onEdit: _editFilters),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton.outlined(
                        key: const ValueKey('chat-filter-button'),
                        tooltip: 'Filters for the assistant',
                        onPressed: _editFilters,
                        icon: Badge(
                          isLabelVisible:
                              app.assistantControls.activeCount(
                                multiKindCatalog: app.data.kinds.length > 1,
                              ) >
                              0,
                          label: Text(
                            '${app.assistantControls.activeCount(multiKindCatalog: app.data.kinds.length > 1)}',
                          ),
                          child: const Icon(Icons.tune_rounded),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Ask for a recommendation…',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      s.busy
                          ? IconButton.outlined(
                              tooltip: 'Stop',
                              onPressed: s.stop,
                              icon: const Icon(Icons.stop_rounded),
                            )
                          : IconButton.filled(
                              tooltip: 'Send',
                              onPressed: _send,
                              icon: const Icon(Icons.arrow_upward_rounded),
                            ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final UiMessage m;
  const _Bubble(this.m);

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final cs = Theme.of(context).colorScheme;
    final user = m.role == 'user';
    final color = switch (m.role) {
      'error' => cs.error,
      'info' => Atlas.muted,
      _ => Atlas.bone,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: user
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 560),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: user
                ? BoxDecoration(
                    color: Atlas.accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  )
                : null,
            child: m.role == 'assistant'
                ? ChatMarkdown(m.text)
                : SelectableText(
                    m.text,
                    style: TextStyle(
                      color: color,
                      height: 1.5,
                      fontSize: 14.5,
                      fontStyle: m.role == 'info' ? FontStyle.italic : null,
                    ),
                  ),
          ),
          if (m.role == 'assistant')
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: TextButton.icon(
                key: const ValueKey('copy-message'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Atlas.muted,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () =>
                    copyText(context, m.plain ?? m.text, what: 'message'),
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('Copy'),
              ),
            ),
          for (final id in m.cited)
            if (app.data.idToIdx[id] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _TitleCard(app.data.idToIdx[id]!),
              ),
          if (m.trace.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 14),
              child: Text(
                'used tools: ${m.trace.join(' → ')}',
                style: const TextStyle(fontSize: 11.5, color: Atlas.faint),
              ),
            ),
        ],
      ),
    );
  }
}

class _TitleCard extends StatelessWidget {
  final int idx;
  const _TitleCard(this.idx);
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.data.titles[idx];
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => DetailPage(idx: idx))),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        padding: const EdgeInsets.all(8),
        decoration: Atlas.outline(radius: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Cover(t.cover, width: 40, height: 58, radius: 3),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Atlas.serif(size: 16),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      kindLabel(t.kind),
                      metaLine(t),
                    ].where((x) => x.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 12, color: Atlas.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right, size: 18, color: Atlas.muted),
          ],
        ),
      ),
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  final PendingAction a;
  final AssistantSession s;
  const _ConfirmCard(this.a, this.s);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Atlas.accent.withValues(alpha: .6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 18, color: Atlas.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The assistant asks to: ${a.label}.',
              style: const TextStyle(height: 1.4),
            ),
          ),
          TextButton(
            onPressed: () => s.dismiss(a),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              final app = context.read<AppState>();
              if (a.type == 'skip' && !a.asked && app.askWhyMode == 'sheet') {
                final r = await showNotForMeSheet(context, a.idx);
                if (r != null) s.confirm(a, reasons: r.reasons);
              } else {
                s.confirm(a);
              }
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}

/// Active filters as removable chips, plus the choice between the feed's filters and the chat's own.
class _FilterBar extends StatelessWidget {
  final VoidCallback onEdit;
  const _FilterBar({required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = app.assistantControls;
    final chips = c.chips(multiKindCatalog: app.data.kinds.length > 1);
    void changed() =>
        app.ai.useFeedFilters ? app.setControls(c) : app.setChatControls(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              key: const ValueKey('filter-source'),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text(
                    'My feed filters',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(
                    'Chat filters only',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              selected: {app.ai.useFeedFilters},
              onSelectionChanged: (v) => app.setUseFeedFilters(v.first),
            ),
            if (chips.isEmpty)
              const Text(
                'No filters',
                style: TextStyle(fontSize: 12, color: Atlas.faint),
              ),
            for (final (label, remove) in chips)
              InputChip(
                key: ValueKey('chip-$label'),
                label: Text(label, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                onPressed: onEdit,
                onDeleted: () {
                  remove();
                  changed();
                },
              ),
          ],
        ),
      ],
    );
  }
}
