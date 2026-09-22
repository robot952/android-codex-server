import 'dart:convert';

import 'package:codex_remote/src/domain/async_question_reply.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:codex_remote/src/ui/work_content.dart';
import 'package:flutter_test/flutter_test.dart';

String _envelope(Object replies) =>
    '<send_user_message_question_reply>\n${jsonEncode(replies)}\n'
    '</send_user_message_question_reply>';

void main() {
  test(
    'question identity retains the wire index after malformed filtering',
    () {
      const entry = TimelineEntry(
        id: 'question:item',
        kind: TimelineKind.agentMessage,
        questions: [
          InputQuestion(
            id: 'async:question:item:2',
            header: '',
            question: '范围',
          ),
        ],
      );
      expect(jsonDecode(asyncQuestionItemId(entry, 0)), [
        'request_user_input_async',
        'question:item',
        2,
      ]);
    },
  );

  test(
    'structured answers display titles and text without changing raw history',
    () {
      final raw = _envelope([
        {
          'questionItemId': '["request_user_input_async","q",0]',
          'question': '范围',
          'answer': '只审查',
        },
        {
          'questionItemId': '["request_user_input_async","q",1]',
          'question': '位置',
          'answer': '/tmp/a.pdf',
        },
      ]);
      final entry = TimelineEntry(
        id: 'reply',
        kind: TimelineKind.userMessage,
        text: raw,
      );
      expect(parseAsyncQuestionReplies(raw).length, 2);
      expect(
        normalizeTimelineEntriesForDisplay([entry]).single.text,
        '范围\n只审查\n\n位置\n/tmp/a.pdf',
      );
      expect(entry.text, raw);
    },
  );

  test('malformed envelopes and ordinary text are preserved verbatim', () {
    final samples = [
      '普通回复',
      '<send_user_message_question_reply>{broken}</send_user_message_question_reply>',
      _envelope([
        {'questionItemId': 'broken', 'question': '范围', 'answer': '回答'},
      ]),
      _envelope([
        {'questionItemId': '["other","q",0]', 'question': '范围', 'answer': '回答'},
      ]),
      _envelope([
        {
          'questionItemId': '["request_user_input_async","q",-1]',
          'question': '范围',
          'answer': '回答',
        },
      ]),
      _envelope([
        {
          'questionItemId': '["request_user_input_async","q",0]',
          'question': '范围',
          'answer': 123,
        },
      ]),
    ];
    for (final text in samples) {
      expect(parseAsyncQuestionReplies(text), isEmpty);
      final entry = TimelineEntry(
        id: 'u',
        kind: TimelineKind.userMessage,
        text: text,
      );
      expect(normalizeTimelineEntriesForDisplay([entry]).single.text, text);
    }
  });
}
