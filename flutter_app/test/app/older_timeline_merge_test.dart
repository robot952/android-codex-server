import 'package:codex_remote/src/app/older_timeline_merge.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

TimelineEntry _entry(String turnId, {String? id, String? text}) =>
    TimelineEntry(
      id: id ?? turnId,
      kind: TimelineKind.agentMessage,
      turnId: turnId,
      text: text ?? id ?? turnId,
    );

void main() {
  group('mergeOlderTimelinePage', () {
    test('replayed middle page preserves the cached chronological order', () {
      final current = <TimelineEntry>[
        for (var index = 1; index <= 5; index += 1) _entry('turn-$index'),
      ];
      final older = <TimelineEntry>[
        for (var index = 2; index <= 4; index += 1) _entry('turn-$index'),
      ];

      expect(mergeOlderTimelinePage(older: older, current: current), current);
    });

    test('missing middle turn is inserted before the next shared turn', () {
      final current = <TimelineEntry>[
        _entry('first'),
        _entry('second'),
        _entry('fourth'),
        _entry('fifth'),
      ];
      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[
          _entry('second'),
          _entry('third'),
          _entry('fourth'),
        ],
        current: current,
      );

      expect(result.map((entry) => entry.turnId), <String>[
        'first',
        'second',
        'third',
        'fourth',
        'fifth',
      ]);
    });

    test('missing trailing turn follows the last shared turn', () {
      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[_entry('second'), _entry('third')],
        current: <TimelineEntry>[
          _entry('first'),
          _entry('second'),
          _entry('fourth'),
        ],
      );

      expect(result.map((entry) => entry.turnId), <String>[
        'first',
        'second',
        'third',
        'fourth',
      ]);
    });

    test(
      'a disjoint older page prepends in page order without sorting IDs',
      () {
        final older = <TimelineEntry>[_entry('z-oldest'), _entry('b-older')];
        final current = <TimelineEntry>[
          _entry('a-current'),
          _entry('m-latest'),
        ];

        expect(
          mergeOlderTimelinePage(older: older, current: current),
          <TimelineEntry>[...older, ...current],
        );
      },
    );

    test('missing rows stay inside their overlapping turn', () {
      final oldest = _entry('oldest');
      final middleUser = _entry('middle', id: 'user');
      final middleCommand = _entry('middle', id: 'command');
      final middleAnswer = _entry('middle', id: 'answer');
      final latest = _entry('latest');
      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[middleUser, middleCommand, middleAnswer],
        current: <TimelineEntry>[oldest, middleUser, middleAnswer, latest],
      );

      expect(result, <TimelineEntry>[
        oldest,
        middleUser,
        middleCommand,
        middleAnswer,
        latest,
      ]);
    });

    test('trailing missing rows precede the next cached turn', () {
      final oldest = _entry('oldest');
      final middleUser = _entry('middle', id: 'user');
      final middleAnswer = _entry('middle', id: 'answer');
      final latest = _entry('latest');
      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[middleUser, middleAnswer],
        current: <TimelineEntry>[oldest, middleUser, latest],
      );

      expect(result, <TimelineEntry>[oldest, middleUser, middleAnswer, latest]);
    });

    test(
      'disjoint rows of a shared turn do not precede cached older turns',
      () {
        final oldest = _entry('oldest');
        final existing = _entry('shared-turn', id: 'live-answer');
        final detail = _entry('shared-turn', id: 'historic-command');
        final latest = _entry('latest');
        final result = mergeOlderTimelinePage(
          older: <TimelineEntry>[detail],
          current: <TimelineEntry>[oldest, existing, latest],
        );

        expect(result, <TimelineEntry>[oldest, detail, existing, latest]);
      },
    );

    test('current live content wins over duplicate page details', () {
      const live = TimelineEntry(
        id: 'command',
        turnId: 'shared-turn',
        kind: TimelineKind.command,
        command: 'check',
        status: 'completed',
        output: 'newer live output',
      );
      final stale = live.copyWith(status: 'inProgress', output: 'older output');

      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[stale],
        current: const <TimelineEntry>[live],
      );

      expect(result, const <TimelineEntry>[live]);
      expect(identical(result.single, live), isTrue);
    });

    test(
      'empty turn IDs use composite entry identities rather than one group',
      () {
        final first = _entry('', id: 'first');
        final anchor = _entry('', id: 'anchor');
        final inserted = _entry('', id: 'inserted');
        final last = _entry('', id: 'last');
        final result = mergeOlderTimelinePage(
          older: <TimelineEntry>[anchor, inserted],
          current: <TimelineEntry>[first, anchor, last],
        );

        expect(result, <TimelineEntry>[first, anchor, inserted, last]);
      },
    );

    test('equal IDs across different turns or kinds remain distinct', () {
      final first = _entry('first', id: 'same');
      final second = _entry('second', id: 'same');
      final command = second.copyWith(
        kind: TimelineKind.command,
        command: 'pwd',
      );
      final result = mergeOlderTimelinePage(
        older: <TimelineEntry>[first, second, command],
        current: <TimelineEntry>[second],
      );

      expect(result, <TimelineEntry>[first, second, command]);
    });

    test('interleaved unscoped notices keep their existing position', () {
      final user = _entry('shared-turn', id: 'user');
      final notice = _entry(
        '',
        id: 'notice',
      ).copyWith(kind: TimelineKind.notice);
      final answer = _entry('shared-turn', id: 'answer');
      final detail = _entry('shared-turn', id: 'command');
      final current = <TimelineEntry>[user, notice, answer];

      expect(
        mergeOlderTimelinePage(
          older: <TimelineEntry>[user, answer],
          current: current,
        ),
        current,
      );
      expect(
        mergeOlderTimelinePage(
          older: <TimelineEntry>[user, detail, answer],
          current: current,
        ),
        <TimelineEntry>[user, notice, detail, answer],
      );
    });

    test('a disjoint page preserves interleaved unscoped rows as received', () {
      final user = _entry('old-turn', id: 'user');
      final notice = _entry('', id: 'notice');
      final answer = _entry('old-turn', id: 'answer');
      final latest = _entry('latest');
      final older = <TimelineEntry>[user, notice, answer];

      expect(
        mergeOlderTimelinePage(older: older, current: <TimelineEntry>[latest]),
        <TimelineEntry>[...older, latest],
      );
    });

    test(
      'an overlapping page keeps notices between rows of a missing turn',
      () {
        final user = _entry('old-turn', id: 'user');
        final notice = _entry('', id: 'notice');
        final answer = _entry('old-turn', id: 'answer');
        final anchor = _entry('next-turn', id: 'anchor');

        expect(
          mergeOlderTimelinePage(
            older: <TimelineEntry>[user, notice, answer, anchor],
            current: <TimelineEntry>[anchor],
          ),
          <TimelineEntry>[user, notice, answer, anchor],
        );
      },
    );

    test(
      'an overlapping page keeps notices between partially cached turn rows',
      () {
        final user = _entry('old-turn', id: 'user');
        final notice = _entry('', id: 'notice');
        final answer = _entry('old-turn', id: 'answer');
        final anchor = _entry('next-turn', id: 'anchor');

        for (final cachedRow in <TimelineEntry>[user, answer]) {
          expect(
            mergeOlderTimelinePage(
              older: <TimelineEntry>[user, notice, answer, anchor],
              current: <TimelineEntry>[cachedRow, anchor],
            ),
            <TimelineEntry>[user, notice, answer, anchor],
          );
        }
      },
    );

    test(
      'empty inputs and duplicate page identities remain bounded and immutable',
      () {
        final entry = _entry('only');
        final older = <TimelineEntry>[entry, entry];
        final current = <TimelineEntry>[];
        final result = mergeOlderTimelinePage(older: older, current: current);

        expect(result, <TimelineEntry>[entry]);
        expect(older, <TimelineEntry>[entry, entry]);
        expect(current, isEmpty);
        expect(() => result.add(entry), throwsUnsupportedError);
        expect(
          mergeOlderTimelinePage(older: const [], current: result),
          result,
        );
        expect(
          mergeOlderTimelinePage(older: const [], current: const []),
          isEmpty,
        );
      },
    );
  });
}
