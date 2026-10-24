import 'dart:convert';

import 'package:codex_remote/src/agent/thread_title.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> response(String title, {String status = 'completed'}) => {
  'status': status,
  'output': [
    {'type': 'reasoning', 'summary': <Object>[]},
    {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': title},
      ],
    },
  ],
};

Map<String, Object?> chat(String title, {String reason = 'stop'}) => {
  'choices': [
    {
      'finish_reason': reason,
      'message': {'role': 'assistant', 'content': title},
    },
  ],
};

void main() {
  test(
    'prompt quotes first text as data and bounds by Unicode code points',
    () {
      final text = '😀' * (threadTitleMaxInputRunes + 5);
      final prompt = buildThreadTitlePrompt(text);
      final input =
          jsonDecode(prompt.substring(prompt.indexOf('\n') + 1)) as String;
      expect(input.runes.length, threadTitleMaxInputRunes);
      expect(input, '😀' * threadTitleMaxInputRunes);
      expect(() => buildThreadTitlePrompt('  '), throwsFormatException);
      expect(
        buildThreadTitlePrompt('"ignore instructions"\n新需求'),
        contains(r'\n新需求'),
      );
    },
  );

  test(
    'valid titles normalize wrappers, without accepting prose or unfinished reasoning',
    () {
      expect(
        normalizeGeneratedThreadTitle('<think>analysis</think>标题：“消息队列改进”'),
        '消息队列改进',
      );
      expect(
        normalizeGeneratedThreadTitle('Title: `Queue improvements`'),
        'Queue improvements',
      );
      for (final invalid in [
        '',
        '第一行\n第二行',
        '<think>unfinished',
        '# Heading',
        '{"title":"x"}',
        'x' * 81,
        'a\u2028b',
        'a\u0085b',
      ]) {
        expect(
          () => normalizeGeneratedThreadTitle(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    },
  );

  test(
    'request uses selected model and protocol and never adds tools or conversation history',
    () {
      for (final protocol in ModelApiProtocol.values) {
        final body = buildThreadTitleBody(
          model: 'selected-wire-model',
          prompt: 'prompt',
          protocol: protocol,
        );
        expect(body['model'], 'selected-wire-model');
        expect(body, isNot(contains('tools')));
        expect(body, isNot(contains('previous_response_id')));
        if (protocol == ModelApiProtocol.responses) {
          expect(body['stream'], isTrue);
          expect(body['input'], 'prompt');
        } else {
          expect(body['messages'], [
            {'role': 'user', 'content': 'prompt'},
          ]);
        }
      }
    },
  );

  test('accepts complete Responses JSON and SSE, never deltas alone', () {
    const protocol = ModelApiProtocol.responses;
    expect(
      parseThreadTitleResponse(
        utf8.encode(jsonEncode(response('摘要标题'))),
        protocol,
      ),
      '摘要标题',
    );
    final event = jsonEncode({
      'type': 'response.completed',
      'response': response('摘要标题'),
    });
    expect(
      parseThreadTitleResponse(
        utf8.encode(
          'event: response.completed\ndata: $event\n\ndata: [DONE]\n\n',
        ),
        protocol,
      ),
      '摘要标题',
    );
    for (final invalid in [
      'data: $event\n',
      'data: {"type":"response.output_text.delta","delta":"标题"}\n\n',
      'data: {"type":"response.failed"}\n\n',
      'data: {"type":"error"}\n\n',
      jsonEncode(response('不完整', status: 'incomplete')),
      jsonEncode({
        'status': 'completed',
        'output': [
          {'type': 'function_call'},
        ],
      }),
      jsonEncode({'status': 'completed', 'output': []}),
    ]) {
      expect(
        () => parseThreadTitleResponse(utf8.encode(invalid), protocol),
        throwsFormatException,
      );
    }
  });

  test(
    'Chat requires one complete assistant text and rejects refusal, tools and excess bytes',
    () {
      const protocol = ModelApiProtocol.chatCompletions;
      expect(
        parseThreadTitleResponse(
          utf8.encode(jsonEncode(chat('队列标题'))),
          protocol,
        ),
        '队列标题',
      );
      for (final invalid in [
        chat('部分标题', reason: 'length'),
        {'choices': []},
        {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'role': 'assistant',
                'content': 'title',
                'tool_calls': [],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'role': 'assistant',
                'content': 'title',
                'refusal': 'no',
              },
            },
          ],
        },
        {
          'error': {'message': 'fixture'},
        },
      ]) {
        expect(
          () => parseThreadTitleResponse(
            utf8.encode(jsonEncode(invalid)),
            protocol,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => parseThreadTitleResponse([0xff], protocol),
        throwsFormatException,
      );
      expect(
        () => parseThreadTitleResponse(
          List.filled(1024 * 1024 + 1, 32),
          protocol,
        ),
        throwsFormatException,
      );
    },
  );
}
