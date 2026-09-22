import 'dart:convert';

import 'models.dart';

String asyncQuestionItemId(TimelineEntry entry, int index) {
  // The parser may discard a malformed question. Keep the original wire index.
  final prefix = 'async:${entry.id}:';
  final id = entry.questions[index].id;
  final wireIndex = id.startsWith(prefix)
      ? int.tryParse(id.substring(prefix.length)) ?? index
      : index;
  return jsonEncode(['request_user_input_async', entry.id, wireIndex]);
}

typedef AsyncQuestionReply = ({String id, String question, String answer});

/// Only recognizes the complete structured message. Ordinary user text and
/// malformed envelopes are preserved verbatim by the presentation layer.
List<AsyncQuestionReply> parseAsyncQuestionReplies(String text) {
  const start = '<send_user_message_question_reply>';
  const end = '</send_user_message_question_reply>';
  final value = text.trim();
  if (value.length > 512 * 1024 ||
      !value.startsWith(start) ||
      !value.endsWith(end)) {
    return const [];
  }
  try {
    final decoded = jsonDecode(
      value.substring(start.length, value.length - end.length),
    );
    if (decoded is! List || decoded.isEmpty || decoded.length > 16) {
      return const [];
    }
    final replies = <AsyncQuestionReply>[];
    for (final item in decoded) {
      if (item is! Map ||
          item['questionItemId'] is! String ||
          item['question'] is! String ||
          item['answer'] is! String) {
        return const [];
      }
      final id = item['questionItemId'] as String;
      final identity = jsonDecode(id);
      if (identity is! List ||
          identity.length != 3 ||
          identity[0] != 'request_user_input_async' ||
          identity[1] is! String ||
          identity[2] is! int ||
          (identity[2] as int) < 0) {
        return const [];
      }
      replies.add((
        id: id,
        question: item['question'] as String,
        answer: item['answer'] as String,
      ));
    }
    return replies;
  } on FormatException {
    return const [];
  }
}
