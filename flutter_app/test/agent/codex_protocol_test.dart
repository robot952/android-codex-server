import 'dart:async';
import 'dart:convert';

import 'package:codex_remote/src/agent/codex_protocol.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Codex JSONL encoding', () {
    test('encodes the initialize handshake and sequential numeric ids', () {
      final generation = CodexProtocolSession().beginGeneration();

      final initialize = generation.initialize(clientVersion: '1.8.0');
      final list = generation.threadList(searchTerm: '  migration  ');
      final page = generation.threadList(
        searchTerm: 'migration',
        cursor: 'next-page-token',
      );
      final initialized = generation.initialized();

      expect(initialize.id, const CodexRequestId.number(1));
      expect(list.id, const CodexRequestId.number(2));
      expect(jsonDecode(initialize.encode()), <String, Object?>{
        'method': 'initialize',
        'id': 1,
        'params': <String, Object?>{
          'clientInfo': <String, Object?>{
            'name': 'codex_remote_android',
            'title': 'Codex Remote Android',
            'version': '1.8.0',
          },
          'capabilities': <String, Object?>{
            'optOutNotificationMethods': <Object?>[],
            'experimentalApi': true,
          },
        },
      });
      expect(jsonDecode(list.encode())['params'], <String, Object?>{
        'limit': 100,
        'archived': false,
        'sortKey': 'recency_at',
        'sortDirection': 'desc',
        'searchTerm': 'migration',
      });
      expect(jsonDecode(page.encode())['params'], <String, Object?>{
        'limit': 100,
        'archived': false,
        'sortKey': 'recency_at',
        'sortDirection': 'desc',
        'searchTerm': 'migration',
        'cursor': 'next-page-token',
      });
      expect(jsonDecode(initialized.encode()), <String, Object?>{
        'method': 'initialized',
        'params': <String, Object?>{},
      });
      expect(initialized.encodeLine(), endsWith('\n'));
    });

    test('encodes a provider filter for thread listings', () {
      final generation = CodexProtocolSession().beginGeneration();
      final request = generation.threadList(modelProviders: const ['relay']);

      expect(
        jsonDecode(request.encode())['params'],
        containsPair('modelProviders', const ['relay']),
      );
    });

    test(
      'encodes thread and turn lifecycle methods like the Kotlin client',
      () {
        final generation = CodexProtocolSession().beginGeneration();

        final startThread = generation.threadStart(
          cwd: '/srv/app',
          model: 'gpt-5.2-codex',
          approvalMode: ApprovalMode.autoApprove,
        );
        final read = generation.threadRead(threadId: 'thread-1');
        final turn = generation.turnStart(
          threadId: 'thread-1',
          text: 'Fix it',
          model: 'gpt-5.2-codex',
          effort: 'high',
          approvalMode: ApprovalMode.autoApprove,
          cwd: '/srv/app',
        );
        final interrupt = generation.turnInterrupt(
          threadId: 'thread-1',
          turnId: 'turn-1',
        );
        final steer = generation.turnSteer(
          threadId: 'thread-1',
          turnId: 'turn-1',
          text: 'Also update the tests',
        );

        expect(startThread.method, 'thread/start');
        expect(startThread.params, <String, Object?>{
          'cwd': '/srv/app',
          'model': 'gpt-5.2-codex',
          'approvalPolicy': 'on-request',
          'sandbox': 'workspace-write',
          'ephemeral': false,
        });
        expect(read.params, <String, Object?>{
          'threadId': 'thread-1',
          'includeTurns': true,
        });
        expect(turn.params, <String, Object?>{
          'threadId': 'thread-1',
          'input': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'Fix it'},
          ],
          'approvalPolicy': 'on-request',
          'sandboxPolicy': <String, Object?>{'type': 'workspaceWrite'},
          'model': 'gpt-5.2-codex',
          'effort': 'high',
          'cwd': '/srv/app',
        });
        expect(interrupt.method, 'turn/interrupt');
        expect(interrupt.params, <String, Object?>{
          'threadId': 'thread-1',
          'turnId': 'turn-1',
        });
        expect(steer.method, 'turn/steer');
        expect(steer.params, <String, Object?>{
          'threadId': 'thread-1',
          'expectedTurnId': 'turn-1',
          'input': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'Also update the tests'},
          ],
        });
      },
    );

    test('encodes thread mutations, review and goal lifecycle methods', () {
      final generation = CodexProtocolSession().beginGeneration();

      final compact = generation.threadCompactStart(threadId: 'thread-1');
      final rollback = generation.threadRollback(
        threadId: 'thread-1',
        numTurns: 2,
      );
      final archive = generation.threadArchive(threadId: 'thread-1');
      final rename = generation.threadNameSet(
        threadId: 'thread-1',
        name: '迁移 Flutter 页面',
      );
      final review = generation.reviewStart(threadId: 'thread-1');
      final goalGet = generation.threadGoalGet(threadId: 'thread-1');
      final goalSet = generation.threadGoalSet(
        threadId: 'thread-1',
        objective: '完成迁移',
        status: ThreadGoalStatus.active,
        tokenBudget: 120000,
      );
      final goalClear = generation.threadGoalClear(threadId: 'thread-1');

      expect(compact.method, 'thread/compact/start');
      expect(compact.params, <String, Object?>{'threadId': 'thread-1'});
      expect(rollback.method, 'thread/rollback');
      expect(rollback.params, <String, Object?>{
        'threadId': 'thread-1',
        'numTurns': 2,
      });
      expect(archive.method, 'thread/archive');
      expect(archive.params, <String, Object?>{'threadId': 'thread-1'});
      expect(rename.method, 'thread/name/set');
      expect(rename.params, <String, Object?>{
        'threadId': 'thread-1',
        'name': '迁移 Flutter 页面',
      });
      expect(review.method, 'review/start');
      expect(review.params, <String, Object?>{
        'threadId': 'thread-1',
        'target': <String, Object?>{'type': 'uncommittedChanges'},
        'delivery': 'inline',
      });
      expect(goalGet.method, 'thread/goal/get');
      expect(goalGet.params, <String, Object?>{'threadId': 'thread-1'});
      expect(goalSet.method, 'thread/goal/set');
      expect(goalSet.params, <String, Object?>{
        'threadId': 'thread-1',
        'objective': '完成迁移',
        'status': 'active',
        'tokenBudget': 120000,
      });
      expect(goalClear.method, 'thread/goal/clear');
      expect(goalClear.params, <String, Object?>{'threadId': 'thread-1'});
    });

    test('allows explicit string ids without converting their wire type', () {
      final generation = CodexProtocolSession().beginGeneration();
      final request = generation.request(
        'test/method',
        id: const CodexRequestId.string('7'),
      );

      expect(jsonDecode(request.encode())['id'], '7');
    });
  });

  group('Codex JSONL decoding', () {
    const decoder = CodexJsonlDecoder();

    test('strictly distinguishes numeric and string response ids', () {
      final numeric =
          decoder.decodeLine('{"id":7,"result":{"ok":true}}', generation: 3)
              as CodexRpcResponse;
      final textual =
          decoder.decodeLine('{"id":"7","result":{"ok":true}}', generation: 3)
              as CodexRpcResponse;

      expect(numeric.id, const CodexRequestId.number(7));
      expect(textual.id, const CodexRequestId.string('7'));
      expect(numeric.id, isNot(textual.id));
    });

    test('keeps unknown notifications without throwing', () {
      final message = decoder.decodeLine(
        '{"method":"future/event","params":{"value":1}}',
        generation: 4,
      );

      expect(message, isA<CodexRpcNotification>());
      final notification = message as CodexRpcNotification;
      expect(notification.method, 'future/event');
      expect(notification.params, <String, Object?>{'value': 1});
      expect(notification.isKnown, isFalse);
    });

    test('decodes server requests while preserving id type', () {
      final message =
          decoder.decodeLine(
                '{"id":"approval-1","method":"item/commandExecution/requestApproval",'
                '"params":{"threadId":"thread-1"}}',
                generation: 5,
              )
              as CodexServerRequest;

      expect(message.id, const CodexRequestId.string('approval-1'));
      expect(message.method, 'item/commandExecution/requestApproval');
      expect(message.params['threadId'], 'thread-1');
    });

    test('returns parse errors for malformed and invalid JSON-RPC lines', () {
      for (final line in <String>[
        '{broken',
        '[]',
        '{}',
        '{"method":null}',
        '{"id":true,"result":{}}',
        '{"id":1,"result":{},"error":{"code":-1,"message":"bad"}}',
      ]) {
        expect(
          decoder.decodeLine(line, generation: 6),
          isA<CodexParseError>(),
          reason: line,
        );
      }
    });

    test('turns error responses into structured exceptions', () {
      final response =
          decoder.decodeLine(
                '{"id":12,"error":{"code":-32001,"message":"busy",'
                '"data":{"retryAfter":3}}}',
                generation: 7,
              )
              as CodexRpcResponse;

      expect(response.error?.code, -32001);
      expect(response.error?.data, <String, Object?>{'retryAfter': 3});
      expect(
        response.resultOrThrow,
        throwsA(
          isA<CodexRpcException>()
              .having((error) => error.code, 'code', -32001)
              .having((error) => error.message, 'message', 'busy')
              .having(
                (error) => error.id,
                'id',
                const CodexRequestId.number(12),
              ),
        ),
      );
    });
  });

  group('generation guard', () {
    test('old scopes cannot decode, commit or publish async results', () async {
      final session = CodexProtocolSession();
      final oldGeneration = session.beginGeneration();
      final pending = Completer<String>();
      final guarded = oldGeneration.guard(pending.future);

      final currentGeneration = session.beginGeneration();
      pending.complete('stale result');

      expect(oldGeneration.decodeLine('{"id":1,"result":{}}'), isNull);
      expect(oldGeneration.commit(() => 'stale update'), isNull);
      expect(await guarded, isNull);
      expect(
        currentGeneration.decodeLine('{"id":1,"result":{}}'),
        isA<CodexRpcResponse>(),
      );
      expect(
        currentGeneration.commit(() => 'current update'),
        'current update',
      );
      expect(() => oldGeneration.threadList(), throwsA(isA<StateError>()));
    });
  });

  group('inbound sequence and oversized envelope inspection', () {
    test(
      'assigns monotonically increasing sequence values within a generation',
      () {
        final session = CodexProtocolSession();
        final generation = session.beginGeneration();

        final first = generation.decodeLine(
          '{"method":"future/one","params":{}}',
        )!;
        final second = generation.decodeLine('{"id":1,"result":{"ok":true}}')!;
        final third = generation.decodeLine('{broken')!;

        expect(
          <int>[first.sequence, second.sequence, third.sequence],
          <int>[1, 2, 3],
        );
        expect(first.generation, generation.value);
        expect(second.generation, generation.value);
        expect(third.generation, generation.value);
      },
    );

    test('resets inbound sequence when a connection generation is renewed', () {
      final session = CodexProtocolSession();
      final oldGeneration = session.beginGeneration();
      expect(
        oldGeneration.decodeLine('{"method":"old","params":{}}')!.sequence,
        1,
      );

      final newGeneration = session.beginGeneration();
      expect(
        oldGeneration.decodeLine('{"method":"stale","params":{}}'),
        isNull,
      );
      final firstNewMessage = newGeneration.decodeLine(
        '{"method":"new","params":{}}',
      )!;

      expect(firstNewMessage.sequence, 1);
      expect(firstNewMessage.generation, newGeneration.value);
    });

    test(
      'preserves numeric and string response id types in an oversized prefix',
      () {
        final numeric = inspectCodexJsonRpcEnvelopePrefix(
          '{"id":42,"result":{"large":"payload',
        );
        final textual = inspectCodexJsonRpcEnvelopePrefix(
          '{"id":"9","result":{"large":"payload',
        );

        expect(numeric.id, const CodexRequestId.number(42));
        expect(textual.id, const CodexRequestId.string('9'));
        expect(numeric.hasMethod, isFalse);
        expect(textual.hasMethod, isFalse);
      },
    );

    test('recognizes only a top-level method field', () {
      final topLevel = inspectCodexJsonRpcEnvelopePrefix(
        '{"method":"item/delta","params":{"id":42,',
      );
      final nested = inspectCodexJsonRpcEnvelopePrefix(
        '{"id":42,"result":{"method":"nested","ok":true}}',
      );

      expect(topLevel.hasMethod, isTrue);
      expect(topLevel.id, isNull);
      expect(nested.hasMethod, isFalse);
      expect(nested.id, const CodexRequestId.number(42));
    });

    test('does not invent an id from a truncated string value', () {
      final completeIdWithTruncatedResult = inspectCodexJsonRpcEnvelopePrefix(
        '{"id":"request-7","result":{"large":"payload',
      );
      final truncatedId = inspectCodexJsonRpcEnvelopePrefix('{"id":"request-7');

      expect(
        completeIdWithTruncatedResult.id,
        const CodexRequestId.string('request-7'),
      );
      expect(truncatedId.id, isNull);
      expect(truncatedId.hasMethod, isFalse);
    });
  });

  group('CodexPayloadParser', () {
    test('parses standard and compatible thread-list fields', () {
      final standardPage = CodexPayloadParser.parseThreadList(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'thread-1',
            'name': 'Standard title',
            'preview': 'Preview',
            'cwd': '/srv/standard',
            'source': <String, Object?>{'custom': 'vscode'},
            'modelProvider': 'relay',
            'status': <String, Object?>{'type': 'active'},
            'createdAt': 10,
            'updatedAt': 20,
            'cliVersion': '0.146.0',
            'turns': <Object?>[
              <String, Object?>{'id': 'turn-running', 'status': 'inProgress'},
            ],
          },
        ],
        'next_cursor': 'next-page',
        'backwardsCursor': 'previous-page',
      });
      final standard = standardPage.threads;
      final compatible = CodexPayloadParser.parseThreads(<String, Object?>{
        'threads': <Object?>[
          <String, Object?>{
            'thread_id': 'thread-2',
            'title': 'Compatible title',
            'last_message': 'Older preview',
            'working_directory': '/srv/legacy',
            'thread_source': 'cli',
            'status': 'idle',
            'created_at': '30',
            'updated_at': 40,
            'cli_version': '0.145.0',
          },
        ],
      });

      expect(standard.single.title, 'Standard title');
      expect(standard.single.source, 'vscode');
      expect(standard.single.modelProvider, 'relay');
      expect(standard.single.status, 'active');
      expect(standard.single.activeTurnId, 'turn-running');
      expect(standardPage.nextCursor, 'next-page');
      expect(standardPage.backwardsCursor, 'previous-page');
      expect(standardPage.hasNextPage, isTrue);
      expect(compatible.single.id, 'thread-2');
      expect(compatible.single.title, 'Compatible title');
      expect(compatible.single.preview, 'Older preview');
      expect(compatible.single.cwd, '/srv/legacy');
      expect(compatible.single.createdAt, 30);
      expect(compatible.single.cliVersion, '0.145.0');
    });

    test('reuses AgentModel and TimelineEntry domain models', () {
      final models = CodexPayloadParser.parseModels(<String, Object?>{
        'models': <Object?>[
          <String, Object?>{
            'id': 'gpt-test',
            'display_name': 'GPT Test',
            'supported_reasoning_efforts': <Object?>[
              <String, Object?>{'effort': 'high'},
            ],
          },
        ],
      });
      final snapshot = CodexPayloadParser.parseThreadPayload(<String, Object?>{
        'thread': <String, Object?>{
          'id': 'thread-1',
          'turns': <Object?>[
            <String, Object?>{
              'id': 'turn-1',
              'items': <Object?>[
                <String, Object?>{
                  'id': 'message-1',
                  'type': 'agentMessage',
                  'text': 'done',
                },
              ],
            },
          ],
        },
      });

      expect(models.single, isA<AgentModel>());
      expect(models.single.efforts, <String>['high']);
      expect(snapshot?.thread, isA<AgentThread>());
      expect(snapshot?.timeline.single, isA<TimelineEntry>());
      expect(snapshot?.timeline.single.text, 'done');
    });

    test('parses standard and compatible thread goals with a fallback id', () {
      final standard = CodexPayloadParser.parseThreadGoal(<String, Object?>{
        'threadId': 'thread-standard',
        'objective': '完成迁移',
        'status': 'paused',
        'createdAt': 10,
        'updatedAt': '20',
        'timeUsedSeconds': 30,
        'tokensUsed': '40',
        'tokenBudget': 500,
      });
      final compatible = CodexPayloadParser.parseThreadGoal(<String, Object?>{
        'goal': '兼容目标',
        'status': 'budgetLimited',
        'created_at': '11',
        'updated_at': 21,
        'time_used_seconds': '31',
        'tokens_used': 41,
        'token_budget': '501',
      }, fallbackThreadId: 'thread-fallback');

      expect(
        standard,
        const ThreadGoal(
          threadId: 'thread-standard',
          objective: '完成迁移',
          status: ThreadGoalStatus.paused,
          createdAt: 10,
          updatedAt: 20,
          timeUsedSeconds: 30,
          tokensUsed: 40,
          tokenBudget: 500,
        ),
      );
      expect(
        compatible,
        const ThreadGoal(
          threadId: 'thread-fallback',
          objective: '兼容目标',
          status: ThreadGoalStatus.budgetLimited,
          createdAt: 11,
          updatedAt: 21,
          timeUsedSeconds: 31,
          tokensUsed: 41,
          tokenBudget: 501,
        ),
      );
      expect(CodexPayloadParser.parseThreadGoal('not-a-goal'), isNull);
    });

    test('restores image and transported file metadata from user messages', () {
      final entry = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'message-1',
        'type': 'userMessage',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '请检查这些附件'},
          <String, Object?>{'type': 'localImage', 'path': '/tmp/diagram.png'},
          <String, Object?>{
            'type': 'text',
            'text': '附件 report.pdf: /tmp/report.pdf',
          },
          <String, Object?>{
            'type': 'text',
            'text': '文本附件 notes.md:\nfirst line',
          },
        ],
      }, turnId: 'turn-1');

      expect(entry?.text, '请检查这些附件');
      expect(entry?.attachments, const <MessageAttachment>[
        MessageAttachment(
          name: 'diagram.png',
          remotePath: '/tmp/diagram.png',
          mimeType: 'image/*',
        ),
        MessageAttachment(name: 'report.pdf', remotePath: '/tmp/report.pdf'),
        MessageAttachment(name: 'notes.md', mimeType: 'text/plain'),
      ]);
    });

    test('compacts a merged inline text attachment before display', () {
      final entry = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'message-merged',
        'type': 'userMessage',
        'content': <Object?>[
          <String, Object?>{
            'type': 'text',
            'text': '请分析日志\n  文本附件 debug.txt:\nline one\nline two',
          },
        ],
      }, turnId: 'turn-merged');

      expect(entry?.text, '请分析日志');
      expect(entry?.attachments, const <MessageAttachment>[
        MessageAttachment(name: 'debug.txt', mimeType: 'text/plain'),
      ]);
    });

    test('compacts a text attachment joined directly to historical text', () {
      final entry = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'message-joined-attachment',
        'type': 'userMessage',
        'content': <Object?>[
          <String, Object?>{
            'type': 'text',
            'text':
                '为什么内容会向下滚动呢？内容从上面冒出来的文本附件 '
                'agent-diagnostic-session.log.txt:\n'
                '2026-08-11T23:56:34 INFO Agent state connected\n'
                '2026-08-11T23:56:35 WARN Heartbeat failed',
          },
        ],
      }, turnId: 'turn-joined-attachment');

      expect(entry?.text, '为什么内容会向下滚动呢？内容从上面冒出来的');
      expect(entry?.text, isNot(contains('Heartbeat failed')));
      expect(entry?.attachments, const <MessageAttachment>[
        MessageAttachment(
          name: 'agent-diagnostic-session.log.txt',
          mimeType: 'text/plain',
        ),
      ]);
    });

    test('bounds thread fields and timeline text with visible markers', () {
      final oversizedMetadata = 'm'.padRight(codexMaxThreadFieldChars + 1, 'm');
      final oversizedText = 't'.padRight(codexMaxTimelineTextChars + 1, 't');

      final thread = CodexPayloadParser.parseThread(<String, Object?>{
        'id': 'thread-1',
        'name': oversizedMetadata,
        'preview': oversizedMetadata,
        'cwd': oversizedMetadata,
        'source': <String, Object?>{'provider': oversizedMetadata},
        'modelProvider': oversizedMetadata,
        'status': oversizedMetadata,
        'cliVersion': oversizedMetadata,
      });
      final entry = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'message-1',
        'type': 'agentMessage',
        'text': oversizedText,
      }, turnId: oversizedMetadata);

      expect(thread, isNotNull);
      expect(thread!.title.length, codexMaxThreadFieldChars);
      expect(thread.preview.length, codexMaxThreadFieldChars);
      expect(thread.cwd.length, codexMaxThreadFieldChars);
      expect(thread.source.length, lessThanOrEqualTo(codexMaxThreadFieldChars));
      expect(thread.status.length, codexMaxThreadFieldChars);
      expect(thread.cliVersion.length, codexMaxThreadFieldChars);
      expect(thread.modelProvider.length, codexMaxThreadFieldChars);
      expect(thread.preview, endsWith(codexTextTruncationMarker));
      expect(entry?.text.length, codexMaxTimelineTextChars);
      expect(entry?.text, endsWith(codexTextTruncationMarker));
      expect(entry?.turnId.length, codexMaxThreadFieldChars);
    });

    test('bounds command output and aggregate file diffs', () {
      final oversizedOutput = 'o'.padRight(codexMaxCommandOutputChars + 1, 'o');
      final oversizedDiff = 'd'.padRight(codexMaxDiffChars + 1, 'd');

      final command = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'command-1',
        'type': 'commandExecution',
        'aggregatedOutput': oversizedOutput,
      }, turnId: 'turn-1');
      final fileChange = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'change-1',
        'type': 'fileChange',
        'changes': <Object?>[
          <String, Object?>{'path': 'first', 'diff': oversizedDiff},
          for (var index = 1; index < 300; index += 1)
            <String, Object?>{'path': 'file-$index', 'diff': 'extra'},
        ],
      }, turnId: 'turn-1');

      expect(command?.output.length, codexMaxCommandOutputChars);
      expect(command?.output, endsWith(codexOutputTruncationMarker));
      expect(fileChange?.changes.length, 256);
      expect(
        fileChange?.changes.fold<int>(
          0,
          (sum, change) => sum + change.diff.length,
        ),
        lessThanOrEqualTo(codexMaxDiffChars),
      );
      expect(
        fileChange?.changes.first.diff,
        endsWith(codexDiffTruncationMarker),
      );
      expect(
        fileChange?.changes.skip(1).every((change) => change.diff.isEmpty),
        isTrue,
      );
    });

    test('bounds reasoning lists, payload lists and unknown JSON previews', () {
      final reasoning = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'reasoning-1',
        'type': 'reasoning',
        'summary': <Object?>[
          for (var index = 0; index < 100; index += 1)
            'part-$index-${'r'.padRight(5000, 'r')}',
        ],
      }, turnId: 'turn-1');
      final unknown = CodexPayloadParser.parseItem(<String, Object?>{
        'id': 'unknown-1',
        'type': 'futureItem',
        'payload': <String, Object?>{
          'value': 'u'.padRight(codexMaxMetadataPreviewChars * 2, 'u'),
        },
      }, turnId: 'turn-1');
      final threads = CodexPayloadParser.parseThreads(<String, Object?>{
        'data': <Object?>[
          for (var index = 0; index < 1100; index += 1)
            <String, Object?>{'id': 'thread-$index'},
        ],
      });
      final timeline = CodexPayloadParser.parseTimeline(<String, Object?>{
        'turns': <Object?>[
          <String, Object?>{
            'id': 'turn-1',
            'items': <Object?>[
              for (var index = 0; index < 5000; index += 1)
                <String, Object?>{
                  'id': 'notice-$index',
                  'type': 'contextCompaction',
                },
            ],
          },
        ],
      });

      expect(reasoning?.reasoningSummary.length, lessThanOrEqualTo(64));
      expect(
        reasoning?.reasoningSummary.fold<int>(
          0,
          (sum, part) => sum + part.length,
        ),
        lessThanOrEqualTo(codexMaxTimelineTextChars),
      );
      expect(
        reasoning?.text.length,
        lessThanOrEqualTo(codexMaxTimelineTextChars),
      );
      expect(unknown?.text.length, codexMaxMetadataPreviewChars);
      expect(unknown?.text, endsWith(codexTextTruncationMarker));
      expect(threads.length, lessThan(1100));
      expect(timeline.length, lessThan(5000));
    });

    test('keeps inherited parent turns out of resumed sub-agent history', () {
      final snapshot = CodexPayloadParser.parseResumedThread(<String, Object?>{
        'thread': <String, Object?>{
          'id': 'child-thread',
          'source': <String, Object?>{'subAgent': <String, Object?>{}},
          'createdAt': 200,
        },
        'initialTurnsPage': <String, Object?>{
          'nextCursor': 'older-page',
          'data': <Object?>[
            <String, Object?>{
              'id': 'child-turn',
              'startedAt': 220,
              'items': <Object?>[
                <String, Object?>{
                  'id': 'child-message',
                  'type': 'agentMessage',
                  'text': 'child',
                },
              ],
            },
            <String, Object?>{
              'id': 'parent-turn',
              'startedAt': 100,
              'items': <Object?>[
                <String, Object?>{
                  'id': 'parent-message',
                  'type': 'agentMessage',
                  'text': 'parent',
                },
              ],
            },
          ],
        },
      });

      expect(snapshot?.thread.source, 'subAgent');
      expect(snapshot?.timeline.map((entry) => entry.text), ['child']);
      expect(snapshot?.nextTurnsCursor, isNull);
    });

    test('stops sub-agent paging when an older page reaches parent turns', () {
      final page = CodexPayloadParser.parseTurnsPage(<String, Object?>{
        'nextCursor': 'next-page',
        'data': <Object?>[
          <String, Object?>{
            'id': 'child-turn',
            // Missing timestamps are retained for older app-server builds.
            'items': <Object?>[
              <String, Object?>{
                'id': 'child-message',
                'type': 'agentMessage',
                'text': 'child-without-time',
              },
            ],
          },
          <String, Object?>{
            'id': 'parent-turn',
            'startedAt': 100,
            'items': <Object?>[
              <String, Object?>{
                'id': 'parent-message',
                'type': 'agentMessage',
                'text': 'parent',
              },
            ],
          },
        ],
      }, subAgentCreatedAt: 200);

      expect(page.timeline.map((entry) => entry.text), ['child-without-time']);
      expect(page.nextCursor, isNull);
    });

    test('hydrates stable sub-agent states from turn and collab payloads', () {
      final historical = CodexPayloadParser.parseTimeline(<String, Object?>{
        'turns': <Object?>[
          <String, Object?>{
            'id': 'turn-complete',
            'status': <String, Object?>{'type': 'completed'},
            'items': <Object?>[
              <String, Object?>{
                'id': 'activity-complete',
                'type': 'subAgentActivity',
                'kind': 'started',
                'agentThreadId': 'child-complete',
              },
            ],
          },
        ],
      });
      final collab = CodexPayloadParser.parseTimeline(<String, Object?>{
        'turns': <Object?>[
          <String, Object?>{
            'id': 'turn-running',
            'status': <String, Object?>{'type': 'inProgress'},
            'items': <Object?>[
              <String, Object?>{
                'id': 'activity-failed',
                'type': 'subAgentActivity',
                'kind': 'interacted',
                'agentThreadId': 'child-failed',
              },
              <String, Object?>{
                'id': 'collab-state',
                'type': 'collabAgentToolCall',
                'agentsStates': <String, Object?>{
                  'child-failed': <String, Object?>{'status': 'errored'},
                },
              },
            ],
          },
        ],
      });

      expect(
        historical
            .singleWhere((entry) => entry.kind == TimelineKind.subAgent)
            .status,
        'completed',
      );
      expect(
        collab
            .singleWhere((entry) => entry.kind == TimelineKind.subAgent)
            .status,
        'errored',
      );
    });
  });
}
