import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';

/// Owns only its question route. Server resolution, disconnect or navigation
/// removes that route, never an unrelated settings or image route above it.
class UserInputPromptHost extends ConsumerStatefulWidget {
  const UserInputPromptHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UserInputPromptHost> createState() =>
      _UserInputPromptHostState();
}

class _UserInputPromptHostState extends ConsumerState<UserInputPromptHost> {
  DialogRoute<void>? _route;
  Object? _identity;
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(appControllerProvider);
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) _sync();
      });
    }
    return widget.child;
  }

  void _sync() {
    final state = ref.read(appControllerProvider);
    final prompt = state.approval;
    final visible =
        (state.screen == AppScreen.work ||
            state.screen == AppScreen.agentWork) &&
        prompt?.kind == ApprovalKind.userInput &&
        state.activeThread != null &&
        (prompt!.threadId.isEmpty || prompt.threadId == state.activeThread!.id);
    final identity = visible
        ? (
            state.selectedProfileId,
            state.activeAgent,
            state.activeThread!.id,
            prompt,
          )
        : null;
    if (identity == _identity) return;
    _removeRoute();
    _identity = identity;
    if (!visible) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final controller = ref.read(appControllerProvider.notifier);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UserInputDialog(
        prompt: prompt,
        onAnswer: (accept, answers) async {
          await controller.answerApproval(
            accept,
            answers: answers,
            expectedPrompt: prompt,
          );
          if (!mounted) return;
          final current = ref.read(appControllerProvider);
          if (current.approval == prompt && current.error != null) {
            throw StateError(current.error!);
          }
        },
      ),
    );
    _route = route;
    unawaited(Navigator.of(context, rootNavigator: true).push(route));
  }

  void _removeRoute() {
    final route = _route;
    _route = null;
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

class UserInputDialog extends StatefulWidget {
  const UserInputDialog({
    super.key,
    required this.prompt,
    required this.onAnswer,
  });
  final ApprovalPrompt prompt;
  final Future<void> Function(bool accept, Map<String, String> answers)
  onAnswer;

  @override
  State<UserInputDialog> createState() => _UserInputDialogState();
}

class _UserInputDialogState extends State<UserInputDialog> {
  final Map<String, String> _answers = {};
  final Map<String, TextEditingController> _fields = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _answer(bool accept) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAnswer(accept, accept ? Map.of(_answers) : const {});
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '回复失败，请检查连接后重试';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.prompt.questions;
    final complete =
        questions.isNotEmpty &&
        questions.every((q) => _answers[q.id]?.trim().isNotEmpty == true);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('user-input-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        title: const Text('需要你的回答'),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (questions.isEmpty) Text(widget.prompt.detail),
              for (var index = 0; index < questions.length; index++) ...[
                if (index > 0) const Divider(height: 28),
                if (questions.length > 1)
                  Text(
                    '问题 ${index + 1} / ${questions.length}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                _question(questions[index]),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _answer(false),
            child: const Text('跳过'),
          ),
          FilledButton(
            key: const Key('submit-user-input'),
            onPressed: _busy || !complete ? null : () => _answer(true),
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('提交回答'),
          ),
        ],
      ),
    );
  }

  Widget _question(InputQuestion question) {
    final field = _fields.putIfAbsent(question.id, TextEditingController.new);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question.header.isNotEmpty)
          Text(question.header, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(question.question),
        const SizedBox(height: 8),
        for (final option in question.options)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _answers[question.id] == option.label && field.text.isEmpty
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(option.label),
            subtitle: option.description.isEmpty
                ? null
                : Text(option.description),
            selected:
                _answers[question.id] == option.label && field.text.isEmpty,
            enabled: !_busy,
            onTap: () => setState(() {
              field.clear();
              _answers[question.id] = option.label;
            }),
          ),
        if (question.options.isEmpty || question.isOther)
          TextField(
            key: ValueKey('answer-${question.id}'),
            controller: field,
            enabled: !_busy,
            obscureText: question.isSecret,
            autocorrect: !question.isSecret,
            enableSuggestions: !question.isSecret,
            maxLines: question.isSecret ? 1 : 3,
            minLines: 1,
            maxLength: 16384,
            onChanged: (value) => setState(() {
              _answers[question.id] = value;
            }),
            decoration: InputDecoration(
              labelText: question.options.isEmpty ? '你的回答' : '其他回答',
              counterText: '',
            ),
          ),
      ],
    );
  }
}
