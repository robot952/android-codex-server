import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/models.dart';

/// A completed remote turn that may be shown after the app moves to the
/// background.  This is deliberately independent from [AppUiState] so a
/// completion from an inactive server lane is not lost.
class TurnCompletion {
  const TurnCompletion({
    required this.profileId,
    required this.agent,
    required this.profileName,
    required this.threadId,
    required this.turnId,
    this.threadTitle = '',
    this.threadPreview = '',
  });

  final String profileId;
  final AgentKind agent;
  final String profileName;
  final String threadId;
  final String turnId;
  final String threadTitle;
  final String threadPreview;
}

/// The destination carried by a completion notification.
class CompletedThreadNavigation {
  const CompletedThreadNavigation({
    required this.profileId,
    required this.agent,
    required this.threadId,
  });

  final String profileId;
  final AgentKind agent;
  final String threadId;

  Map<String, Object?> toJson() => <String, Object?>{
    'profileId': profileId,
    'agent': agent.storageKeySegment,
    'threadId': threadId,
  };

  static CompletedThreadNavigation? fromJson(Object? value) {
    if (value is! Map) return null;
    String readString(String key) {
      final item = value[key];
      return item is String ? item.trim() : '';
    }

    final profileId = readString('profileId');
    final threadId = readString('threadId');
    if (profileId.isEmpty || threadId.isEmpty) return null;
    final agentValue = readString('agent').toLowerCase();
    final agent = switch (agentValue) {
      'opencode' || 'open_code' || 'open-code' => AgentKind.openCode,
      _ => AgentKind.codex,
    };
    return CompletedThreadNavigation(
      profileId: profileId,
      agent: agent,
      threadId: threadId,
    );
  }
}

/// Bounded turn-level deduplication.  Codex can echo a completion through
/// both `turn/completed` and `thread/status/changed`; retaining identities here
/// prevents duplicate notifications while keeping memory bounded.
class TurnCompletionDeduplicator {
  TurnCompletionDeduplicator({this.maxEntries = 512}) : assert(maxEntries > 0);

  final int maxEntries;
  final Set<String> _seen = <String>{};

  bool shouldPublish(TurnCompletion completion) {
    final turnId = completion.turnId.trim();
    // A missing id cannot safely be treated as a stable identity.  It is
    // intentionally allowed through each time.
    if (turnId.isEmpty) return true;
    final identity = [
      completion.profileId,
      completion.agent.storageKeySegment,
      completion.threadId,
      turnId,
    ].join('\u0000');
    if (!_seen.add(identity)) return false;
    while (_seen.length > maxEntries) {
      _seen.remove(_seen.first);
    }
    return true;
  }
}

/// Tracks thread ids learned from timeline/list payloads so child-agent
/// completions do not produce user-facing notifications.
class SubAgentThreadRegistry {
  SubAgentThreadRegistry({this.maxEntries = 1024}) : assert(maxEntries > 0);

  final int maxEntries;
  final Set<String> _knownThreads = <String>{};

  void remember(AgentConnectionKey key, String threadId) {
    final normalized = threadId.trim();
    if (normalized.isEmpty) return;
    _knownThreads.add(
      '${key.profileId}\u0000${key.agent.storageKeySegment}\u0000$normalized',
    );
    while (_knownThreads.length > maxEntries) {
      _knownThreads.remove(_knownThreads.first);
    }
  }

  bool contains(AgentConnectionKey key, String threadId) {
    final normalized = threadId.trim();
    return normalized.isNotEmpty &&
        _knownThreads.contains(
          '${key.profileId}\u0000${key.agent.storageKeySegment}\u0000$normalized',
        );
  }
}

bool isSubAgentThreadSource(String source) {
  final normalized = source
      .trim()
      .toLowerCase()
      .replaceAll('_', '')
      .replaceAll('-', '');
  return normalized == 'subagent';
}

/// Stable notification ids avoid replacing a different server's notification
/// when the process is restarted.  Dart's [Object.hash] is deliberately not
/// used because its seed is allowed to vary between VM runs.
int completionNotificationId(
  String profileId,
  AgentKind agent,
  String threadId,
) {
  final input = '$profileId\u0000${agent.storageKeySegment}\u0000$threadId';
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 10000 + (hash & 0x00ffffff);
}

/// Android local-notification adapter.  Platform failures are contained so a
/// notification permission or plugin issue cannot break the SSH conversation.
class TurnCompletionNotifier {
  TurnCompletionNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'codex_turn_completion';
  static const channelName = '会话完成提醒';
  static const channelDescription = 'Codex 会话在后台完成时发出提醒';

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<CompletedThreadNavigation> _navigationController =
      StreamController<CompletedThreadNavigation>.broadcast(sync: true);
  Future<void>? _initialization;
  bool _available = false;

  Stream<CompletedThreadNavigation> get navigationEvents =>
      _navigationController.stream;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );
      _available = initialized != false;
      if (!_available) return;

      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _emitPayload(launch?.notificationResponse?.payload);
      }
    } catch (_) {
      _available = false;
    }
  }

  Future<void> requestPermission() async {
    await initialize();
    if (!_available) return;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
    } catch (_) {
      // Permission is optional; a denied prompt must not affect connections.
    }
  }

  Future<void> show(TurnCompletion completion) async {
    await initialize();
    if (!_available || completion.profileId.trim().isEmpty) return;
    final title = completion.profileName.trim().isEmpty
        ? '会话已完成'
        : '${completion.profileName.trim()} · 会话已完成';
    final detail = completion.threadTitle.trim().isNotEmpty
        ? completion.threadTitle.trim()
        : completion.threadPreview.trim().isNotEmpty
        ? completion.threadPreview.trim()
        : '点击查看完成的会话';
    final payload = jsonEncode(
      CompletedThreadNavigation(
        profileId: completion.profileId.trim(),
        agent: completion.agent,
        threadId: completion.threadId.trim(),
      ).toJson(),
    );
    try {
      await _plugin.show(
        id: completionNotificationId(
          completion.profileId,
          completion.agent,
          completion.threadId,
        ),
        title: title,
        body: detail.length > 240 ? '${detail.substring(0, 240)}…' : detail,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            category: AndroidNotificationCategory.status,
            icon: 'ic_launcher',
            autoCancel: true,
            onlyAlertOnce: true,
            channelShowBadge: true,
          ),
        ),
        payload: payload,
      );
    } catch (_) {
      // Notifications are best effort and must never affect the SSH lane.
    }
  }

  Future<void> cancel(
    String profileId,
    AgentKind agent,
    String threadId,
  ) async {
    await initialize();
    if (!_available) return;
    try {
      await _plugin.cancel(
        id: completionNotificationId(profileId, agent, threadId),
      );
    } catch (_) {
      // Best effort; the destination can still be opened from the list.
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    _emitPayload(response.payload);
  }

  void _emitPayload(String? payload) {
    if (payload == null || payload.length > 4096) return;
    try {
      final decoded = jsonDecode(payload);
      final navigation = CompletedThreadNavigation.fromJson(decoded);
      if (navigation != null && !_navigationController.isClosed) {
        _navigationController.add(navigation);
      }
    } on FormatException {
      // Ignore malformed notification payloads.
    }
  }

  Future<void> dispose() async {
    await _navigationController.close();
  }
}

/// Required by flutter_local_notifications for background action callbacks.
/// A tap that launches the app is recovered through
/// `getNotificationAppLaunchDetails` during [TurnCompletionNotifier.initialize].
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {}

final turnCompletionNotifier = TurnCompletionNotifier();
