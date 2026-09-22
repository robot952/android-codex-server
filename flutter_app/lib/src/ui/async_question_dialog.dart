import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_controller.dart';
import '../domain/async_question_reply.dart';
import '../domain/models.dart';

// Presentation state survives leaving a Work page, but is bounded and never
// persisted with profiles or sent to the server when a question is dismissed.
final _questionPresentationProvider = ChangeNotifierProvider(
  (ref) => _QuestionPresentation(),
);

class _QuestionDraft {
  final answers = <String, String>{};
  final custom = <String, String>{};
  bool answered = false;
  bool skipped = false;
}

class _QuestionPresentation extends ChangeNotifier {
  final _seen = <String>{};
  final _drafts = <String, _QuestionDraft>{};

  bool observe(String id) {
    final added = _seen.add(id);
    while (_seen.length > 512) {
      _seen.remove(_seen.first);
    }
    return added;
  }

  _QuestionDraft draft(String id) {
    final value = _drafts.remove(id) ?? _QuestionDraft();
    _drafts[id] = value;
    while (_drafts.length > 128) {
      _drafts.remove(_drafts.keys.first);
    }
    return value;
  }

  bool answered(String id) => _drafts[id]?.answered ?? false;
  void changed() => notifyListeners();
}

String _scope(AppUiState state) => threadPreferenceKey(
  state.selectedProfileId ?? '',
  state.activeAgent,
  state.activeThread?.id ?? '',
);

String _identity(AppUiState state, TimelineEntry entry) =>
    '${_scope(state)}\u0000${entry.turnId}\u0000${entry.id}';

bool _canAnswer(AppUiState state) =>
    state.screen == AppScreen.work &&
    state.activeThread != null &&
    !state.isThreadReadOnly &&
    !state.loading &&
    state
            .agentConnectionStates[AgentConnectionKey(
              profileId: state.selectedProfileId ?? '',
              agent: state.activeAgent,
            )]
            ?.phase ==
        ConnectionPhase.connected;

/// Opens only newly delivered questions automatically. Restored/paged history
/// remains a compact button, independent of lazy transcript row lifetimes.
class AsyncQuestionPromptHost extends ConsumerStatefulWidget {
  const AsyncQuestionPromptHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AsyncQuestionPromptHost> createState() =>
      _AsyncQuestionPromptHostState();
}

class _AsyncQuestionPromptHostState
    extends ConsumerState<AsyncQuestionPromptHost> {
  DialogRoute<void>? _route;
  String? _routeScope;
  TimelineEntry? _routeEntry;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    if (!_initialized) {
      _initialized = true;
      final presentation = ref.read(_questionPresentationProvider);
      for (final entry in state.timeline.where((e) => e.questions.isNotEmpty)) {
        presentation.observe(_identity(state, entry));
      }
    }
    ref.listen(appControllerProvider, _onStateChanged);
    return widget.child;
  }

  void _onStateChanged(AppUiState? previous, AppUiState current) {
    final presentation = ref.read(_questionPresentationProvider);
    TimelineEntry? fresh;
    for (final entry in current.timeline.where((e) => e.questions.isNotEmpty)) {
      if (!presentation.observe(_identity(current, entry))) continue;
      if (previous != null &&
          _scope(previous) == _scope(current) &&
          !previous.loading &&
          !previous.olderTurnsLoading &&
          !current.olderTurnsLoading &&
          _canAnswer(current) &&
          current.running &&
          entry.turnId == current.activeTurnId) {
        fresh ??= entry;
      }
    }
    final candidate = fresh;
    if (candidate == null && _route == null) return;
    final scope = _scope(current);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(appControllerProvider);
      final entry = _routeEntry;
      final questionChanged =
          entry != null &&
          !state.timeline.any(
            (item) =>
                item.id == entry.id &&
                item.turnId == entry.turnId &&
                item.questions.length == entry.questions.length &&
                List.generate(
                  item.questions.length,
                  (i) => item.questions[i] == entry.questions[i],
                ).every((same) => same),
          );
      if (_route != null &&
          (_routeScope != _scope(state) ||
              questionChanged ||
              !_canAnswer(state) ||
              state.approval?.kind == ApprovalKind.userInput)) {
        if (questionChanged && _routeScope == _scope(state)) {
          final draft = presentation.draft(_identity(state, entry));
          draft.answers.clear();
          draft.custom.clear();
          draft.answered = false;
        }
        _removeRoute();
      }
      if (candidate != null && _scope(state) == scope) {
        _open(candidate, automatic: true);
      }
    });
  }

  void _open(TimelineEntry entry, {bool automatic = false}) {
    final state = ref.read(appControllerProvider);
    if (!_canAnswer(state) ||
        state.submitting ||
        _route != null ||
        state.approval?.kind == ApprovalKind.userInput ||
        ModalRoute.of(context)?.isCurrent != true ||
        !state.timeline.any(
          (e) => e.id == entry.id && e.turnId == entry.turnId,
        )) {
      return;
    }
    final presentation = ref.read(_questionPresentationProvider);
    final draft = presentation.draft(_identity(state, entry));
    if (automatic && (draft.answered || draft.skipped)) return;
    final scope = _scope(state);
    final controller = ref.read(appControllerProvider.notifier);
    FocusManager.instance.primaryFocus?.unfocus();
    late final DialogRoute<void> route;
    void close() {
      if (identical(_route, route)) _removeRoute();
    }

    route = DialogRoute<void>(
      context: context,
      builder: (_) => _AsyncQuestionDialog(
        entry: entry,
        draft: draft,
        onClose: close,
        onSkip: () {
          draft.skipped = true;
          presentation.changed();
          close();
        },
        onAnswer: (answers) async {
          if (!mounted ||
              _scope(ref.read(appControllerProvider)) != scope ||
              !_canAnswer(ref.read(appControllerProvider))) {
            throw StateError('会话已切换');
          }
          final accepted = await controller.answerAsyncQuestion(
            profileId: state.selectedProfileId!,
            agent: state.activeAgent,
            threadId: state.activeThread!.id,
            entry: entry,
            answers: answers,
          );
          if (!accepted) throw StateError('回答未发送');
          if (!mounted) return;
          draft.answered = true;
          draft.skipped = false;
          presentation.changed();
          close();
        },
      ),
    );
    _route = route;
    _routeScope = scope;
    _routeEntry = entry;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (identical(_route, route)) {
          _route = null;
          _routeScope = null;
          _routeEntry = null;
        }
      }),
    );
  }

  void _removeRoute() {
    final route = _route;
    _route = null;
    _routeScope = null;
    _routeEntry = null;
    if (route?.isActive == true) route!.navigator!.removeRoute(route);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator!.removeRoute(route);
      });
    }
    super.dispose();
  }
}

class AsyncQuestionButton extends ConsumerWidget {
  const AsyncQuestionButton({super.key, required this.entry});
  final TimelineEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final presentation = ref.watch(_questionPresentationProvider);
    final host = context
        .findAncestorStateOfType<_AsyncQuestionPromptHostState>();
    final replied = state.timeline
        .where(
          (item) =>
              item.kind == TimelineKind.userMessage &&
              !item.id.startsWith('local-user-'),
        )
        .expand((item) => parseAsyncQuestionReplies(item.text))
        .map((reply) => reply.id)
        .toSet();
    final answered =
        presentation.answered(_identity(state, entry)) ||
        List.generate(
          entry.questions.length,
          (i) => asyncQuestionItemId(entry, i),
        ).every(replied.contains);
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: Key('answer-async-question-${entry.id}'),
        onPressed: _canAnswer(state) && !state.submitting && host != null
            ? () => host._open(entry)
            : null,
        icon: const Icon(Icons.chat_bubble_outline, size: 16),
        label: Text(answered ? '已回答' : '回答问题'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFB5B5B5),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
    );
  }
}

class _AsyncQuestionDialog extends StatefulWidget {
  const _AsyncQuestionDialog({
    required this.entry,
    required this.draft,
    required this.onAnswer,
    required this.onClose,
    required this.onSkip,
  });

  final TimelineEntry entry;
  final _QuestionDraft draft;
  final Future<void> Function(Map<String, String>) onAnswer;
  final VoidCallback onClose;
  final VoidCallback onSkip;

  @override
  State<_AsyncQuestionDialog> createState() => _AsyncQuestionDialogState();
}

class _AsyncQuestionDialogState extends State<_AsyncQuestionDialog> {
  final _fields = <String, TextEditingController>{};
  bool _busy = false;
  String? _error;

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAnswer(Map.of(widget.draft.answers));
    } catch (_) {
      if (mounted) setState(() => _error = '回复失败，请检查连接后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.entry.questions;
    final complete = questions.every(
      (q) => widget.draft.answers[q.id]?.trim().isNotEmpty == true,
    );
    return AlertDialog(
      key: const Key('async-question-dialog'),
      backgroundColor: const Color(0xFF303030),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      scrollable: true,
      title: Row(
        children: [
          const Icon(Icons.chat_bubble_outline, size: 18),
          const SizedBox(width: 10),
          const Expanded(child: Text('问题')),
          IconButton(
            key: const Key('close-async-question'),
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < questions.length; i++) ...[
              if (i > 0) const Divider(height: 28),
              Text(
                questions[i].question,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ..._choices(questions[i]),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('skip-async-question'),
          onPressed: _busy ? null : widget.onSkip,
          child: const Text('跳过'),
        ),
        FilledButton(
          key: const Key('submit-async-question'),
          onPressed: _busy || !complete ? null : _send,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('发送'),
        ),
      ],
    );
  }

  List<Widget> _choices(InputQuestion question) {
    final draft = widget.draft;
    final field = _fields.putIfAbsent(
      question.id,
      () => TextEditingController(text: draft.custom[question.id] ?? ''),
    );
    return [
      for (final option in question.options)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            draft.answers[question.id] == option.label && field.text.isEmpty
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(option.label),
          subtitle: option.description.isEmpty
              ? null
              : Text(option.description),
          enabled: !_busy,
          onTap: () => setState(() {
            field.clear();
            draft.custom.remove(question.id);
            draft.answers[question.id] = option.label;
          }),
        ),
      TextField(
        key: ValueKey('async-answer-${question.id}'),
        controller: field,
        enabled: !_busy,
        minLines: 1,
        maxLines: 3,
        maxLength: 16384,
        decoration: const InputDecoration(hintText: '或自行撰写回复', counterText: ''),
        onChanged: (value) => setState(() {
          draft.custom[question.id] = value;
          draft.answers[question.id] = value;
        }),
      ),
    ];
  }
}
