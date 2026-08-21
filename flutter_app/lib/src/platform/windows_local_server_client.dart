import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../agent/codex_global_settings.dart';
import '../agent/codex_host_capabilities.dart';
import '../agent/open_code_bootstrap.dart';
import '../agent/remote_bootstrap.dart';
import '../domain/install_progress_format.dart';
import '../domain/models.dart';
import '../ssh/ssh_server_client.dart';

const localWindowsProfileId = 'agent-local-windows';
const localWindowsHost = 'local-windows';

bool isLocalWindowsProfile(ServerProfile profile) =>
    profile.id == localWindowsProfileId || profile.host == localWindowsHost;

ServerProfile localWindowsProfile({ServerProfile? existing}) {
  final home = Platform.environment['USERPROFILE']?.trim() ?? '';
  final username = Platform.environment['USERNAME']?.trim() ?? '';
  return ServerProfile(
    id: localWindowsProfileId,
    name: '本机 Windows',
    host: localWindowsHost,
    port: 1,
    username: username.isEmpty ? 'local' : username,
    hostFingerprint: localWindowsHost,
    workspace: existing?.workspace.trim().isNotEmpty == true
        ? existing!.workspace
        : home,
    proxyUrl: existing?.proxyUrl ?? '',
    approvalMode: existing?.approvalMode ?? ApprovalMode.requestApproval,
    remoteCommand: managedCodexRemoteCommand,
    workspacePromptShown: existing?.workspacePromptShown ?? true,
    activeAgent: existing?.activeAgent ?? AgentKind.codex,
    agentModelSettings:
        existing?.agentModelSettings ?? const <AgentKind, AgentModelSettings>{},
  );
}

/// Native Windows Host used by the desktop executable. Agent JSONL, reducers,
/// approvals and thread state remain in the shared Agent layer.
class WindowsLocalServerClient
    implements
        RemoteServerClient,
        LocalRemoteServerClient,
        RemoteServerCodexProcessClient,
        RemoteServerAgentProcessClient,
        RemoteServerCodexRuntimeClient,
        RemoteServerOpenCodeRuntimeClient,
        RemoteServerCodexSettingsClient,
        RemoteServerAttachmentClient,
        RemoteServerImageClient,
        RemoteServerFileClient,
        RemoteServerDirectoryClient {
  bool _connected = false;
  ServerProfile? _profile;
  Completer<void> _done = Completer<void>();
  final Set<_WindowsProcessSession> _sessions = <_WindowsProcessSession>{};

  @override
  bool get isConnected => _connected;

  @override
  Future<void> get done => _done.future;

  @override
  Future<String> probeFingerprint(ServerProfile profile) async =>
      localWindowsHost;

  @override
  Future<void> connect(ServerProfile profile) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('本机 Windows 仅可在 Windows EXE 中使用');
    }
    if (!isLocalWindowsProfile(profile)) {
      throw StateError('本机 Windows Host 收到了无效配置');
    }
    if (_done.isCompleted) _done = Completer<void>();
    _profile = profile;
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _profile = null;
    for (final session in _sessions.toList()) {
      session.terminate();
    }
    _sessions.clear();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() => unawaited(disconnect());

  @override
  SSHClient requireSshClient() => throw UnsupportedError('本机 Windows 不使用 SSH');

  @override
  Future<String> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    int maxOutputBytes = 1024 * 1024,
  }) => Future<String>.error(UnsupportedError('本机 Windows 不执行 POSIX shell 命令'));

  @override
  Future<ServerMetrics> readServerMetrics(ServerProfile profile) async =>
      ServerMetrics(
        sampledAtEpochMillis: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  Future<RemoteServerProcessSession> openCodexAppServer() async {
    final profile = _requireConnectedProfile();
    final executable = await _findCodexExecutable();
    if (executable == null) throw StateError('没有找到 Windows 原生 Codex');
    final environment = await _codexEnvironment(profile);
    final process = await Process.start(
      executable,
      const <String>['app-server', '--listen', 'stdio://'],
      workingDirectory: _workspace(profile),
      environment: environment,
      includeParentEnvironment: true,
      runInShell: executable.toLowerCase().endsWith('.cmd'),
    );
    late final _WindowsProcessSession session;
    session = _WindowsProcessSession(process, () => _sessions.remove(session));
    _sessions.add(session);
    return session;
  }

  @override
  Future<RemoteServerProcessSession> openAgentAppServer(AgentKind agent) async {
    if (agent != AgentKind.openCode) {
      return openCodexAppServer();
    }
    final executable = await _findOpenCodeExecutable();
    if (executable == null) throw StateError('没有找到 Windows 原生 OpenCode');
    final bridge = File(_openCodeBridgeFile);
    if (!await bridge.exists()) {
      throw StateError('OpenCode 桥接文件不存在，请重新安装 OpenCode');
    }
    final node = await _findManagedNodeExecutable();
    if (node == null) throw StateError('没有找到 OpenCode 所需的 Node.js 运行时');
    final profile = _requireConnectedProfile();
    final environment = await _openCodeEnvironment(profile);
    environment['OPENCODE_BIN'] = executable;
    final process = await Process.start(
      node,
      <String>[
        bridge.path,
        if (profile.workspace.trim().isNotEmpty) ...[
          '--directory',
          profile.workspace.trim(),
        ],
      ],
      workingDirectory: _workspace(profile),
      environment: environment,
      includeParentEnvironment: true,
      runInShell: false,
    );
    late final _WindowsProcessSession session;
    session = _WindowsProcessSession(process, () => _sessions.remove(session));
    _sessions.add(session);
    return session;
  }

  @override
  Future<AgentRuntimeInspection> inspectOpenCodeRuntime(
    ServerProfile profile, {
    required String bridgeSource,
  }) async {
    _requireConnectedProfile(profile);
    final executable = await _findOpenCodeExecutable();
    final node = await _findManagedNodeExecutable();
    final bridge = File(_openCodeBridgeFile);
    String? version;
    if (executable != null) {
      final result = await Process.run(executable, const <String>[
        '--version',
      ]).timeout(const Duration(seconds: 15));
      if (result.exitCode == 0) version = result.stdout.toString().trim();
    }
    final compatible =
        executable != null &&
        node != null &&
        await bridge.exists() &&
        version?.contains(pinnedOpenCodeVersion) == true &&
        await bridge.readAsString() == bridgeSource;
    return AgentRuntimeInspection(
      os: 'Windows',
      architecture: _windowsArchitecture(),
      home: _userHome,
      libc: '',
      hasShell: true,
      hasTar: true,
      hasSha256: true,
      hasFlock: true,
      hasSetsidWait: true,
      managedVersion: version,
      managedPath: executable,
      downloader: 'npm',
      fallbackCommand: compatible ? 'windows-native-opencode' : null,
    );
  }

  @override
  Future<void> installOpenCodeRuntime(
    ServerProfile profile, {
    required String bridgeSource,
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    _requireConnectedProfile(profile);
    final started = DateTime.now();
    onProgress(
      const RemoteInstallProgress(
        percent: 5,
        message: '正在检测 OpenCode 安装环境',
        detail: '检查共享 Node.js、npm 和 OpenCode 平台包',
        indeterminate: true,
      ),
    );
    final runtime = await _ensureWindowsNodeRuntime(
      profile,
      onProgress: onProgress,
    );
    await Directory(_openCodeRoot).create(recursive: true);
    final packageJson = File(path.join(_openCodeRoot, 'package.json'));
    await packageJson.writeAsString(
      '{"private":true,"dependencies":{"jsonc-parser":"3.3.1","opencode-ai":"$pinnedOpenCodeVersion","opencode-${_windowsPackageSuffix()}":"$pinnedOpenCodeVersion"}}\n',
      flush: true,
    );
    final install = await _runOpenCodeNpmInstall(
      runtime.npm,
      profile,
      registry: 'https://registry.npmmirror.com',
      minimumPercent: 25,
      onProgress: onProgress,
    );
    if (install.exitCode != 0) {
      onProgress(
        const RemoteInstallProgress(
          percent: 45,
          message: '国内镜像不可用，正在切换官方源',
          detail: '保留已显示的处理量，重新获取 OpenCode 依赖',
          indeterminate: true,
        ),
      );
      final retry = await _runOpenCodeNpmInstall(
        runtime.npm,
        profile,
        registry: 'https://registry.npmjs.org',
        minimumPercent: 45,
        onProgress: onProgress,
      );
      if (retry.exitCode != 0) {
        throw StateError('OpenCode npm 安装失败：${_short(retry.stderr)}');
      }
    }
    onProgress(
      const RemoteInstallProgress(
        percent: 85,
        message: '校验 OpenCode 运行时',
        detail: '检查平台运行文件和固定版本',
        indeterminate: true,
      ),
    );
    final executable = await _findOpenCodeExecutable();
    if (executable == null) throw StateError('OpenCode 安装完成，但没有找到可执行文件');
    final actual = await Process.run(executable, const <String>['--version']);
    if (actual.exitCode != 0 ||
        !actual.stdout.toString().contains(pinnedOpenCodeVersion)) {
      throw StateError('OpenCode 版本校验失败：${_short(actual.stdout.toString())}');
    }
    onProgress(
      const RemoteInstallProgress(
        percent: 92,
        message: '写入 OpenCode 移动端桥接',
        detail: '发布应用自带的 JSONL bridge',
        indeterminate: true,
      ),
    );
    await File(_openCodeBridgeFile).writeAsString(bridgeSource, flush: true);
    final stats = await _readInstallStats(Directory(_openCodeRoot));
    final elapsed = DateTime.now().difference(started).inSeconds;
    final rate = elapsed <= 0 ? null : stats.bytes ~/ elapsed;
    onProgress(
      RemoteInstallProgress(
        percent: 100,
        message: 'Windows 原生 OpenCode 已就绪',
        detail:
            '桥接服务、Node.js 和 OpenCode $pinnedOpenCodeVersion 已准备完成 · '
            '已处理 ${formatInstallBytes(stats.bytes)} · ${formatInstallRate(rate)} · '
            '已用时 ${elapsed}s',
        downloadedBytes: stats.bytes,
        bytesPerSecond: rate,
        elapsedSeconds: elapsed,
      ),
    );
  }

  @override
  Future<void> uninstallOpenCodeRuntime(ServerProfile profile) async {
    _requireConnectedProfile(profile);
    for (final session in _sessions.toList()) {
      session.terminate();
    }
    final root = Directory(_openCodeRoot);
    if (await root.exists()) await root.delete(recursive: true);
  }

  @override
  Future<AgentRuntimeInspection> inspectCodexRuntime(
    ServerProfile profile,
  ) async {
    _requireConnectedProfile(profile);
    final executable = await _findCodexExecutable();
    String? version;
    if (executable != null) {
      final result = await Process.run(
        executable,
        const <String>['--version'],
        runInShell: executable.toLowerCase().endsWith('.cmd'),
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode == 0) version = result.stdout.toString().trim();
    }
    final architecture = _windowsArchitecture();
    return AgentRuntimeInspection(
      os: 'Windows',
      architecture: architecture,
      home: _userHome,
      libc: '',
      hasShell: true,
      hasTar: true,
      hasSha256: true,
      hasFlock: true,
      hasSetsidWait: true,
      managedVersion: executable != null && _isManagedCodex(executable)
          ? version
          : null,
      managedPath: executable != null && _isManagedCodex(executable)
          ? executable
          : null,
      systemVersion: executable != null && !_isManagedCodex(executable)
          ? version
          : null,
      systemPath: executable != null && !_isManagedCodex(executable)
          ? executable
          : null,
      downloader: 'PowerShell',
      // Native process startup resolves the executable itself. Any installed
      // native Codex is usable even if its patch version differs from Linux.
      fallbackCommand: executable == null ? null : 'windows-native-codex',
    );
  }

  @override
  Future<void> installCodexRuntime(
    ServerProfile profile, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    _requireConnectedProfile(profile);
    onProgress(
      const RemoteInstallProgress(percent: 5, message: '正在检测 Windows 安装环境'),
    );
    final npm = await _where('npm.cmd') ?? await _where('npm');
    if (npm != null) {
      onProgress(
        const RemoteInstallProgress(
          percent: 20,
          message: '正在通过 npm 安装 Codex',
          detail: '国内镜像 · 正在获取依赖清单',
          indeterminate: true,
        ),
      );
      await Directory(_managedRoot).create(recursive: true);
      var install = await _runNpmInstall(
        npm,
        profile,
        registry: 'https://registry.npmmirror.com',
        minimumPercent: 20,
        onProgress: onProgress,
      );
      if (install.exitCode != 0) {
        onProgress(
          const RemoteInstallProgress(
            percent: 35,
            message: '国内镜像不可用，正在切换官方源',
            detail: '上一次安装输出已结束，重新获取依赖清单',
            indeterminate: true,
          ),
        );
        install = await _runNpmInstall(
          npm,
          profile,
          registry: 'https://registry.npmjs.org',
          minimumPercent: 35,
          onProgress: onProgress,
        );
      }
      if (install.exitCode != 0) {
        throw StateError('npm 安装 Codex 失败：${_short(install.stderr)}');
      }
    } else {
      onProgress(
        const RemoteInstallProgress(
          percent: 20,
          message: '正在运行 Codex 官方安装器',
          detail: 'PowerShell 安装器 · 正在下载并配置',
          indeterminate: true,
        ),
      );
      final started = DateTime.now();
      final process = await Process.start(
        'powershell.exe',
        const <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r"$env:CODEX_NON_INTERACTIVE='1'; irm https://chatgpt.com/codex/install.ps1 | iex",
        ],
        environment: <String, String>{
          if (profile.proxyUrl.trim().isNotEmpty) ...{
            'HTTP_PROXY': profile.proxyUrl.trim(),
            'HTTPS_PROXY': profile.proxyUrl.trim(),
          },
        },
        includeParentEnvironment: true,
      );
      final stdoutFuture = utf8.decoder.bind(process.stdout).forEach((chunk) {
        final text = chunk.trim();
        if (text.isEmpty) return;
        onProgress(
          RemoteInstallProgress(
            percent: 20,
            message: '正在运行 Codex 官方安装器',
            detail: 'PowerShell 安装器 · $text',
            indeterminate: true,
            elapsedSeconds: DateTime.now().difference(started).inSeconds,
          ),
        );
      });
      final stderrFuture = utf8.decoder.bind(process.stderr).join();
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        onProgress(
          RemoteInstallProgress(
            percent: 20,
            message: '正在运行 Codex 官方安装器',
            detail: 'PowerShell 安装器 · 正在下载并配置',
            indeterminate: true,
            elapsedSeconds: DateTime.now().difference(started).inSeconds,
          ),
        );
      });
      late final int exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(minutes: 15));
      } on TimeoutException {
        process.kill();
        throw StateError('Codex 官方安装器超时，请检查网络或代理后重试');
      } finally {
        timer.cancel();
      }
      await stdoutFuture;
      final stderr = await stderrFuture;
      if (exitCode != 0) {
        throw StateError('Codex 官方安装器失败：${_short(stderr)}');
      }
    }
    if (await _findCodexExecutable() == null) {
      throw StateError('Codex 安装完成，但没有找到可执行文件');
    }
    onProgress(
      const RemoteInstallProgress(
        percent: 100,
        message: 'Windows 原生 Codex 已就绪',
      ),
    );
  }

  @override
  Future<void> uninstallCodexRuntime(ServerProfile profile) async {
    _requireConnectedProfile(profile);
    for (final session in _sessions.toList()) {
      session.terminate();
    }
    final root = Directory(_managedRoot);
    if (await root.exists()) await root.delete(recursive: true);
  }

  @override
  Future<RemoteDirectoryListing> listDirectories(String? requestedPath) async {
    final profile = _requireConnectedProfile();
    final current = Directory(_resolveDirectory(requestedPath, profile));
    if (!await current.exists()) throw StateError('目录不存在：${current.path}');
    final directories = <RemoteDirectory>[];
    await for (final entity in current.list(followLinks: false)) {
      if (entity is! Directory) continue;
      directories.add(
        RemoteDirectory(name: path.basename(entity.path), path: entity.path),
      );
      if (directories.length >= maxRemoteDirectoryEntries) break;
    }
    directories.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    final parent = current.parent.path == current.path
        ? null
        : current.parent.path;
    return RemoteDirectoryListing(
      currentPath: current.path,
      parentPath: parent,
      directories: directories,
    );
  }

  @override
  Future<String> uploadAttachment(
    String name,
    Uint8List bytes, {
    int maxBytes = maxRemoteAttachmentBytes,
  }) async {
    _requireConnectedProfile();
    if (bytes.length > maxBytes) throw StateError('附件超过大小限制');
    final safeName = _safeFileName(name);
    final root = Directory(_uploadRoot);
    await root.create(recursive: true);
    final target = File(path.join(root.path, '${const Uuid().v4()}-$safeName'));
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  @override
  Future<Uint8List> readRemoteImage(
    String imagePath, {
    int maxBytes = maxRemoteImageBytes,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    _requireConnectedProfile();
    final file = File(imagePath);
    final size = await file.length();
    if (size > maxBytes) throw StateError('图片超过预览大小限制');
    onProgress?.call(0, size);
    final builder = BytesBuilder(copy: false);
    var receivedBytes = 0;
    await for (final chunk in file.openRead()) {
      builder.add(chunk);
      receivedBytes += chunk.length;
      onProgress?.call(receivedBytes, size);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != size) throw StateError('图片读取不完整');
    return bytes;
  }

  @override
  Future<int> downloadRemoteFile(
    String filePath, {
    required Future<void> Function(Uint8List chunk) writeChunk,
    int maxBytes = maxRemoteFileBytes,
  }) async {
    _requireConnectedProfile();
    final file = File(filePath);
    final size = await file.length();
    if (size > maxBytes) throw StateError('文件超过下载大小限制');
    var received = 0;
    await for (final chunk in file.openRead()) {
      received += chunk.length;
      if (received > maxBytes) throw StateError('文件超过下载大小限制');
      await writeChunk(Uint8List.fromList(chunk));
    }
    return received;
  }

  @override
  Future<AgentGlobalSettings> readCodexSettings(ServerProfile profile) async {
    _requireConnectedProfile(profile);
    final configText = await _readTextIfExists(_configFile);
    final root = _tomlRootValues(configText);
    final provider = root['model_provider']?.trim().isNotEmpty == true
        ? root['model_provider']!
        : 'openai';
    var baseUrl = root['openai_base_url'] ?? '';
    if (provider != 'openai') {
      baseUrl =
          _tomlTableValues(
            configText,
            'model_providers.$provider',
          )['base_url'] ??
          baseUrl;
    }
    final websocketPolicy = provider == 'openai'
        ? null
        : _tomlBooleanValue(
            configText,
            'model_providers.$provider',
            'supports_websockets',
          );
    final auth = await _readJsonMap(_authFile);
    final envText = await _readTextIfExists(_environmentFile);
    final proxy =
        RegExp(
          r'^# codex-remote-proxy: (.*)$',
          multiLine: true,
        ).firstMatch(envText)?.group(1)?.trim() ??
        '';
    final apiKey = auth['OPENAI_API_KEY'] is String
        ? (auth['OPENAI_API_KEY'] as String)
        : '';
    return AgentGlobalSettings(
      baseUrl: baseUrl,
      model: root['model'] ?? '',
      reasoningEffort: root['model_reasoning_effort'] ?? '',
      modelProvider: provider,
      websocketPolicy: websocketPolicy == null
          ? null
          : websocketPolicy
          ? codexWebSocketPolicyEnabled
          : codexWebSocketPolicyDisabled,
      hasStoredAuthentication:
          apiKey.isNotEmpty || await File(_authFile).exists(),
      apiKey: apiKey,
      proxyUrl: proxy,
    );
  }

  @override
  Future<void> writeCodexSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String defaultModel,
    required String defaultReasoningEffort,
    String? websocketPolicy,
    required bool preserveCurrentProvider,
  }) async {
    _requireConnectedProfile(profile);
    final normalizedBase = normalizeCodexBaseUrl(baseUrl);
    final normalizedKey = normalizeCodexApiKey(apiKey);
    final normalizedProxy = normalizeCodexProxyUrl(proxyUrl);
    final normalizedModel = normalizeCodexModel(defaultModel, '默认模型');
    final normalizedEffort = normalizeCodexReasoningEffort(
      defaultReasoningEffort,
    );
    final normalizedWebSocketPolicy = normalizeCodexWebSocketPolicy(
      websocketPolicy,
    );
    await Directory(_codexHome).create(recursive: true);
    final existing = await _readTextIfExists(_configFile);
    final providerUpdated = updateCodexProviderBaseUrl(
      existing,
      normalizedBase,
    );
    final settingsUpdated = updateCodexProviderWebSocketPolicy(
      providerUpdated,
      normalizedWebSocketPolicy,
    );
    final replacements = <String, String?>{
      'model': normalizedModel.isEmpty ? null : normalizedModel,
      'model_reasoning_effort': normalizedEffort.isEmpty
          ? null
          : normalizedEffort,
    };
    await _writeAtomicText(
      _configFile,
      _replaceTomlRoot(settingsUpdated, replacements),
    );
    if (normalizedProxy.isEmpty) {
      final envFile = File(_environmentFile);
      if (await envFile.exists()) await envFile.delete();
    } else {
      await _writeAtomicText(
        _environmentFile,
        '# Managed by Codex Remote. Loaded before native Codex starts.\n'
        '# codex-remote-proxy: $normalizedProxy\n',
      );
    }
    if (normalizedKey.isNotEmpty) {
      await _loginWithApiKey(profile, normalizedKey);
    }
  }

  @override
  Future<AgentConnectionTestResult> testCodexSettings(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
    required String testModel,
    ModelApiProtocol? apiProtocol,
  }) async {
    _requireConnectedProfile(profile);
    final key = normalizeCodexApiKey(apiKey);
    final model = normalizeCodexModel(testModel, '测试模型');
    if (key.isEmpty) {
      return const AgentConnectionTestResult(
        successful: false,
        message: '请输入 API 密钥后再测试',
      );
    }
    if (model.isEmpty) {
      return const AgentConnectionTestResult(
        successful: false,
        message: '请输入测试模型后再测试',
      );
    }
    final base = _normalizedApiBase(baseUrl);
    final proxy = normalizeCodexProxyUrl(proxyUrl);
    final protocols = apiProtocol == null
        ? const <ModelApiProtocol>[
            ModelApiProtocol.responses,
            ModelApiProtocol.chatCompletions,
          ]
        : <ModelApiProtocol>[apiProtocol];
    try {
      for (final protocol in protocols) {
        final endpoint = protocol == ModelApiProtocol.responses
            ? 'responses'
            : 'chat/completions';
        final body = protocol == ModelApiProtocol.responses
            ? <String, Object>{'model': model, 'input': 'ping'}
            : <String, Object>{
                'model': model,
                'messages': <Object>[
                  <String, Object>{'role': 'user', 'content': 'ping'},
                ],
              };
        final status = await _httpStatus(
          Uri.parse('$base/$endpoint'),
          key,
          proxy,
          body,
        );
        if (status >= 200 && status < 300) {
          final label = protocol == ModelApiProtocol.responses
              ? 'Responses'
              : 'Chat Completions';
          return AgentConnectionTestResult(
            successful: true,
            message: '模型 $model 可用（$label）（HTTP $status）',
          );
        }
        if (status == 401 || status == 403) {
          return AgentConnectionTestResult(
            successful: false,
            message: 'API 密钥无效或没有权限（HTTP $status）',
          );
        }
        if (protocol == protocols.last) {
          return AgentConnectionTestResult(
            successful: false,
            message: 'API 服务返回异常（HTTP $status）',
          );
        }
      }
    } on TimeoutException {
      return const AgentConnectionTestResult(
        successful: false,
        message: '连接 API 服务超时，请检查网络或代理',
      );
    } on SocketException {
      return const AgentConnectionTestResult(
        successful: false,
        message: '无法连接 API 服务，请检查模型 URL、代理或本机网络',
      );
    }
    return const AgentConnectionTestResult(
      successful: false,
      message: 'API 测试失败',
    );
  }

  @override
  Future<List<ApiModelOption>> fetchCodexApiModels(
    ServerProfile profile, {
    required String baseUrl,
    required String apiKey,
    required String proxyUrl,
  }) async {
    _requireConnectedProfile(profile);
    final key = normalizeCodexApiKey(apiKey);
    if (key.isEmpty) throw StateError('请先在模型配置中保存 API 密钥');
    final client = _httpClient(normalizeCodexProxyUrl(proxyUrl));
    try {
      final request = await client
          .getUrl(Uri.parse('${_normalizedApiBase(baseUrl)}/models'))
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = await _boundedResponse(response, 256 * 1024);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('API 密钥无效或没有权限（HTTP ${response.statusCode}）');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('模型 API 返回异常（HTTP ${response.statusCode}）');
      }
      return parseCodexApiModelsJson(bytes);
    } finally {
      client.close(force: true);
    }
  }

  ServerProfile _requireConnectedProfile([ServerProfile? expected]) {
    final profile = _profile;
    if (!_connected || profile == null) throw StateError('本机 Windows 尚未连接');
    if (expected != null && !profile.hasSameConnectionIdentity(expected)) {
      throw StateError('本机 Windows 配置已更新');
    }
    return profile;
  }

  String get _userHome =>
      Platform.environment['USERPROFILE']?.trim().isNotEmpty == true
      ? Platform.environment['USERPROFILE']!.trim()
      : Directory.current.path;
  String get _localAppData =>
      Platform.environment['LOCALAPPDATA']?.trim().isNotEmpty == true
      ? Platform.environment['LOCALAPPDATA']!.trim()
      : path.join(_userHome, 'AppData', 'Local');
  String get _managedRoot => path.join(_localAppData, 'CodexRemote', 'codex');
  String get _openCodeRoot =>
      path.join(_localAppData, 'CodexRemote', 'opencode');
  String get _runtimeRoot => path.join(_localAppData, 'CodexRemote', 'runtime');
  String get _openCodeBridgeFile => path.join(_openCodeRoot, 'bridge.cjs');
  String get _uploadRoot => path.join(_localAppData, 'CodexRemote', 'uploads');
  String get _codexHome => path.join(_userHome, '.codex');
  String get _configFile => path.join(_codexHome, 'config.toml');
  String get _authFile => path.join(_codexHome, 'auth.json');
  String get _environmentFile => path.join(_codexHome, 'codex-remote.env');

  String _workspace(ServerProfile profile) =>
      profile.workspace.trim().isEmpty ? _userHome : profile.workspace.trim();
  String _resolveDirectory(String? requested, ServerProfile profile) =>
      requested?.trim().isNotEmpty == true
      ? requested!.trim()
      : _workspace(profile);
  bool _isManagedCodex(String executable) {
    final root = path.normalize(_managedRoot).toLowerCase();
    final candidate = path.normalize(executable).toLowerCase();
    return candidate == root || candidate.startsWith('$root${path.separator}');
  }

  Future<String?> _findCodexExecutable() async {
    final candidates = <String>[
      path.join(_managedRoot, 'node_modules', '.bin', 'codex.cmd'),
      path.join(
        _localAppData,
        'Programs',
        'OpenAI',
        'Codex',
        'bin',
        'codex.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return await _where('codex.exe') ??
        await _where('codex.cmd') ??
        await _where('codex');
  }

  Future<String?> _findOpenCodeExecutable() async {
    final suffix = _windowsPackageSuffix();
    final candidates = <String>[
      path.join(
        _openCodeRoot,
        'node_modules',
        'opencode-$suffix',
        'bin',
        'opencode.exe',
      ),
      path.join(
        _openCodeRoot,
        'node_modules',
        'opencode-ai',
        'bin',
        'opencode.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> _findManagedNodeExecutable() async {
    final pinned = await _findPinnedNodeRuntime();
    return pinned?.node ?? await _where('node.exe') ?? await _where('node');
  }

  Future<String?> _where(String executable) async {
    try {
      final result = await Process.run('where.exe', <String>[
        executable,
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return null;
      return const LineSplitter()
          .convert(result.stdout.toString())
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '')
          .nullIfEmpty;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _codexEnvironment(ServerProfile profile) async {
    final settings = await readCodexSettings(profile);
    final proxy = settings.proxyUrl.isNotEmpty
        ? settings.proxyUrl
        : profile.proxyUrl.trim();
    return <String, String>{
      if (proxy.isNotEmpty) ...{
        'HTTP_PROXY': proxy,
        'HTTPS_PROXY': proxy,
        'ALL_PROXY': proxy,
        'http_proxy': proxy,
        'https_proxy': proxy,
        'all_proxy': proxy,
      },
    };
  }

  Future<Map<String, String>> _openCodeEnvironment(
    ServerProfile profile,
  ) async {
    final proxy = profile.proxyUrl.trim();
    return <String, String>{
      if (proxy.isNotEmpty) ...{
        'HTTP_PROXY': proxy,
        'HTTPS_PROXY': proxy,
        'ALL_PROXY': proxy,
        'http_proxy': proxy,
        'https_proxy': proxy,
        'all_proxy': proxy,
      },
    };
  }

  Future<_WindowsNodeRuntime?> _findPinnedNodeRuntime() async {
    final directory = path.join(
      _runtimeRoot,
      'node-v$pinnedNodeVersion-win-${_windowsNodeArchitecture()}',
    );
    final node = path.join(directory, 'node.exe');
    final npm = path.join(directory, 'npm.cmd');
    if (!await File(node).exists() || !await File(npm).exists()) return null;
    try {
      final result = await Process.run(node, const <String>[
        '--version',
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0 ||
          result.stdout.toString().trim() != 'v$pinnedNodeVersion') {
        return null;
      }
    } catch (_) {
      return null;
    }
    return _WindowsNodeRuntime(node: node, npm: npm);
  }

  Future<_WindowsNodeRuntime> _ensureWindowsNodeRuntime(
    ServerProfile profile, {
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final existing = await _findPinnedNodeRuntime();
    if (existing != null) {
      onProgress(
        const RemoteInstallProgress(
          percent: 22,
          message: '复用现有 Node.js 运行时',
          detail: '固定版本 Node.js 已通过校验',
        ),
      );
      return existing;
    }
    final arch = _windowsNodeArchitecture();
    final name = 'node-v$pinnedNodeVersion-win-$arch';
    final checksum = arch == 'arm64'
        ? '78355dc9ca117bb71d3f081e4b1b281855e2b134f3939bb0ca314f7567b0e621'
        : '721ab118a3aac8584348b132767eadf51379e0616f0db802cc1e66d7f0d98f85';
    final archive = File(path.join(_runtimeRoot, '$name.zip'));
    await archive.parent.create(recursive: true);
    final mirrors = <Uri>[
      Uri.parse(
        'https://npmmirror.com/mirrors/node/v$pinnedNodeVersion/$name.zip',
      ),
      Uri.parse('https://nodejs.org/dist/v$pinnedNodeVersion/$name.zip'),
    ];
    Object? lastError;
    for (var index = 0; index < mirrors.length; index++) {
      try {
        final minimumPercent = index == 0 ? 8 : 14;
        final maximumPercent = index == 0 ? 13 : 18;
        onProgress(
          RemoteInstallProgress(
            percent: minimumPercent,
            message: index == 0 ? '下载独立 Node.js 运行时' : '国内镜像不可用，正在切换官方源',
            detail: index == 0 ? 'Node.js 国内镜像' : 'Node.js 官方下载源',
            indeterminate: true,
          ),
        );
        await _downloadInstallFile(
          mirrors[index],
          archive,
          profile,
          minimumPercent: minimumPercent,
          maximumPercent: maximumPercent,
          label: '下载独立 Node.js 运行时',
          onProgress: onProgress,
        );
        lastError = null;
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw StateError('Node.js 下载失败：${_short('$lastError')}');
    }
    onProgress(
      const RemoteInstallProgress(
        percent: 19,
        message: '校验 Node.js 下载文件',
        detail: '校验 SHA-256',
      ),
    );
    final actual = (await sha256.bind(archive.openRead()).first).toString();
    if (actual != checksum) throw StateError('Node.js 下载文件校验失败');
    onProgress(
      const RemoteInstallProgress(
        percent: 20,
        message: '解压 Node.js 运行时',
        detail: '正在准备独立 Windows 运行环境',
        indeterminate: true,
      ),
    );
    final result = await Process.run('powershell.exe', <String>[
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'param($archive,$destination,$runtime); New-Item -ItemType Directory -Force -Path $destination | Out-Null; if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }; Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force',
      archive.path,
      _runtimeRoot,
      path.join(_runtimeRoot, name),
    ]).timeout(const Duration(minutes: 5));
    if (result.exitCode != 0) {
      throw StateError('Node.js 解压失败：${_short(result.stderr.toString())}');
    }
    final runtime = await _findPinnedNodeRuntime();
    if (runtime == null) throw StateError('Node.js 解压完成，但运行时校验失败');
    try {
      await archive.delete();
    } on FileSystemException {
      // The verified runtime is already committed; a stale archive is harmless.
    }
    onProgress(
      const RemoteInstallProgress(
        percent: 22,
        message: 'Node.js 运行时已就绪',
        detail: '固定版本运行环境准备完成',
      ),
    );
    return runtime;
  }

  Future<void> _downloadInstallFile(
    Uri uri,
    File target,
    ServerProfile profile, {
    required int minimumPercent,
    required int maximumPercent,
    required String label,
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final client = _httpClient(profile.proxyUrl.trim());
    final started = DateTime.now();
    var received = 0;
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      final sink = target.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          sink.add(chunk);
          received += chunk.length;
          final elapsed = DateTime.now().difference(started).inSeconds;
          final rate = elapsed <= 0 ? null : received ~/ elapsed;
          final downloadPercent = total == null
              ? null
              : (received * 100 ~/ total).clamp(0, 99);
          onProgress(
            RemoteInstallProgress(
              percent: downloadPercent == null
                  ? minimumPercent
                  : minimumPercent +
                        ((maximumPercent - minimumPercent) *
                            downloadPercent ~/
                            100),
              message: label,
              detail: total == null
                  ? '已下载 ${formatInstallBytes(received)} · ${formatInstallRate(rate)} · 已用时 ${elapsed}s'
                  : '${formatInstallBytes(received)} / ${formatInstallBytes(total)} · ${formatInstallRate(rate)} · 已用时 ${elapsed}s',
              downloadPercent: downloadPercent,
              downloadedBytes: received,
              totalBytes: total,
              bytesPerSecond: rate,
              elapsedSeconds: elapsed,
              indeterminate: total == null,
            ),
          );
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<({int exitCode, String stderr})> _runNpmInstall(
    String npm,
    ServerProfile profile, {
    required String registry,
    required int minimumPercent,
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final started = DateTime.now();
    var sampling = false;
    var finished = false;
    Future<void> publishStats({String? output}) async {
      if (sampling || finished) return;
      sampling = true;
      try {
        final stats = await _readManagedInstallStats();
        if (finished) return;
        final elapsed = DateTime.now().difference(started).inSeconds;
        final rate = elapsed <= 0 ? null : stats.bytes ~/ elapsed;
        final outputSuffix = output == null || output.isEmpty
            ? '正在解析和安装依赖'
            : output;
        onProgress(
          RemoteInstallProgress(
            // npm does not expose a reliable total download size. Let the
            // observed file count move this stage forward without crossing
            // the next explicit phase boundary.
            percent: minimumPercent + (stats.fileCount ~/ 250).clamp(0, 11),
            message: '正在通过 npm 安装 Codex',
            detail:
                '$registry · 已写入 ${stats.fileCount} 个文件 · '
                '已写入 ${formatInstallBytes(stats.bytes)} · '
                '${formatInstallRate(rate)} · $outputSuffix',
            downloadedBytes: stats.bytes,
            bytesPerSecond: rate,
            elapsedSeconds: elapsed,
            indeterminate: true,
          ),
        );
      } finally {
        sampling = false;
      }
    }

    final process = await Process.start(
      npm,
      <String>[
        'install',
        '--prefix',
        _managedRoot,
        '--no-audit',
        '--no-fund',
        '@openai/codex@$pinnedCodexVersion',
      ],
      environment: <String, String>{
        if (profile.proxyUrl.trim().isNotEmpty) ...{
          'HTTP_PROXY': profile.proxyUrl.trim(),
          'HTTPS_PROXY': profile.proxyUrl.trim(),
        },
        'npm_config_registry': registry,
      },
      includeParentEnvironment: true,
      runInShell: npm.toLowerCase().endsWith('.cmd'),
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).forEach((
      chunk,
    ) {
      final lines = chunk.split(RegExp(r'\r?\n'));
      for (final line in lines) {
        final text = line.trim();
        if (text.isNotEmpty) {
          unawaited(publishStats(output: text));
        }
      }
    });
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(publishStats());
    });
    final exitCode = await process.exitCode;
    timer.cancel();
    finished = true;
    await stdoutFuture;
    final finalStats = await _readManagedInstallStats();
    onProgress(
      RemoteInstallProgress(
        percent: minimumPercent + 12,
        message: '正在通过 npm 安装 Codex',
        detail:
            '$registry · npm 命令已完成 · 已写入 ${finalStats.fileCount} 个文件 · '
            '${formatInstallBytes(finalStats.bytes)}',
        downloadedBytes: finalStats.bytes,
        indeterminate: false,
        elapsedSeconds: DateTime.now().difference(started).inSeconds,
      ),
    );
    return (exitCode: exitCode, stderr: await stderrFuture);
  }

  Future<({int exitCode, String stderr})> _runOpenCodeNpmInstall(
    String npm,
    ServerProfile profile, {
    required String registry,
    required int minimumPercent,
    required void Function(RemoteInstallProgress progress) onProgress,
  }) async {
    final started = DateTime.now();
    var sampling = false;
    var finished = false;
    Future<void> publishStats({String? output}) async {
      if (sampling || finished) return;
      sampling = true;
      try {
        final stats = await _readInstallStats(Directory(_openCodeRoot));
        if (finished) return;
        final elapsed = DateTime.now().difference(started).inSeconds;
        final rate = elapsed <= 0 ? null : stats.bytes ~/ elapsed;
        onProgress(
          RemoteInstallProgress(
            percent: minimumPercent + (stats.fileCount ~/ 80).clamp(0, 14),
            message: '正在通过 npm 安装 OpenCode',
            detail:
                '$registry · 已处理 ${stats.fileCount} 个文件 · '
                '已写入 ${formatInstallBytes(stats.bytes)} · '
                '${formatInstallRate(rate)} · 已用时 ${elapsed}s'
                '${output == null || output.isEmpty ? '' : ' · $output'}',
            downloadedBytes: stats.bytes,
            bytesPerSecond: rate,
            elapsedSeconds: elapsed,
            indeterminate: true,
          ),
        );
      } finally {
        sampling = false;
      }
    }

    final process = await Process.start(
      npm,
      <String>[
        'install',
        '--prefix',
        _openCodeRoot,
        '--no-audit',
        '--no-fund',
        '--omit=dev',
        '--omit=optional',
        '--ignore-scripts',
        '--loglevel=error',
      ],
      environment: <String, String>{
        ...await _openCodeEnvironment(profile),
        'npm_config_registry': registry,
      },
      includeParentEnvironment: true,
      runInShell: npm.toLowerCase().endsWith('.cmd'),
    );
    final stdoutFuture = utf8.decoder.bind(process.stdout).forEach((chunk) {
      final text = chunk.trim();
      if (text.isNotEmpty) unawaited(publishStats(output: text));
    });
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(publishStats());
    });
    final exitCode = await process.exitCode;
    timer.cancel();
    finished = true;
    await stdoutFuture;
    final stats = await _readInstallStats(Directory(_openCodeRoot));
    onProgress(
      RemoteInstallProgress(
        percent: minimumPercent + 15,
        message: '正在通过 npm 安装 OpenCode',
        detail:
            '$registry · npm 命令已完成 · 已写入 ${formatInstallBytes(stats.bytes)}',
        downloadedBytes: stats.bytes,
        elapsedSeconds: DateTime.now().difference(started).inSeconds,
      ),
    );
    return (exitCode: exitCode, stderr: await stderrFuture);
  }

  Future<_WindowsInstallStats> _readManagedInstallStats() async {
    return _readInstallStats(Directory(_managedRoot));
  }

  Future<_WindowsInstallStats> _readInstallStats(Directory root) async {
    if (!await root.exists()) return const _WindowsInstallStats();
    var fileCount = 0;
    var bytes = 0;
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        fileCount++;
        try {
          final size = await entity.length();
          bytes = _saturatingAdd(bytes, size);
        } on FileSystemException {
          // npm can remove a file between list() and stat(); keep the sample.
        }
      }
    } on FileSystemException {
      // The directory can be replaced while npm is unpacking a package.
    }
    return _WindowsInstallStats(fileCount: fileCount, bytes: bytes);
  }

  Future<void> _loginWithApiKey(ServerProfile profile, String apiKey) async {
    final executable = await _findCodexExecutable();
    if (executable == null) throw StateError('没有找到 Windows 原生 Codex');
    final process = await Process.start(
      executable,
      const <String>['login', '--with-api-key'],
      environment: await _codexEnvironment(profile),
      includeParentEnvironment: true,
      runInShell: executable.toLowerCase().endsWith('.cmd'),
    );
    final stdoutFuture = process.stdout.drain<void>();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    process.stdin.write(apiKey);
    await process.stdin.close();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      process.kill();
      throw StateError('Codex API 密钥登录超时');
    }
    await stdoutFuture;
    final stderr = await stderrFuture;
    if (exitCode != 0) {
      throw StateError('Codex API 密钥登录失败：${_short(stderr)}');
    }
  }
}

class _WindowsInstallStats {
  const _WindowsInstallStats({this.fileCount = 0, this.bytes = 0});

  final int fileCount;
  final int bytes;
}

class _WindowsNodeRuntime {
  const _WindowsNodeRuntime({required this.node, required this.npm});

  final String node;
  final String npm;
}

int _saturatingAdd(int current, int value) {
  final next = current + value;
  return next < current ? 0x7fffffffffffffff : next;
}

class _WindowsProcessSession implements RemoteServerProcessSession {
  _WindowsProcessSession(this._process, this._onDone) {
    _done = _process.exitCode.then<void>((_) => _onDone());
  }
  final Process _process;
  final void Function() _onDone;
  late final Future<void> _done;
  bool _terminated = false;

  @override
  Stream<Uint8List> get stdout => _process.stdout.map(Uint8List.fromList);
  @override
  Stream<Uint8List> get stderr => _process.stderr.map(Uint8List.fromList);
  @override
  Future<void> get done => _done;
  @override
  void write(Uint8List data) => _process.stdin.add(data);
  @override
  void terminate() {
    if (_terminated) return;
    _terminated = true;
    unawaited(_process.stdin.close());
    _process.kill();
    if (Platform.isWindows) {
      unawaited(
        Process.run('taskkill.exe', <String>[
          '/PID',
          '${_process.pid}',
          '/T',
          '/F',
        ]).then<void>((_) {}, onError: (_) {}),
      );
    }
  }
}

String _windowsArchitecture() {
  final value =
      (Platform.environment['PROCESSOR_ARCHITEW6432'] ??
              Platform.environment['PROCESSOR_ARCHITECTURE'] ??
              '')
          .toLowerCase();
  if (value.contains('arm64')) return 'arm64';
  if (value.contains('amd64') || value.contains('x86_64')) return 'amd64';
  return value;
}

String _windowsNodeArchitecture() =>
    _windowsArchitecture() == 'arm64' ? 'arm64' : 'x64';

String _windowsPackageSuffix() {
  final value =
      (Platform.environment['PROCESSOR_ARCHITEW6432'] ??
              Platform.environment['PROCESSOR_ARCHITECTURE'] ??
              '')
          .toLowerCase();
  return value.contains('arm64') ? 'windows-arm64' : 'windows-x64-baseline';
}

String _safeFileName(String value) {
  final base = path
      .basename(value)
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
  if (base.isEmpty || base == '.' || base == '..') return 'attachment';
  return base.length <= 120 ? base : base.substring(base.length - 120);
}

String _short(String value) {
  final text = value.trim();
  return text.length <= 500 ? text : '${text.substring(0, 500)}...';
}

Future<String> _readTextIfExists(String filePath) async {
  final file = File(filePath);
  return await file.exists() ? file.readAsString() : '';
}

Future<Map<String, Object?>> _readJsonMap(String filePath) async {
  try {
    final decoded = jsonDecode(await _readTextIfExists(filePath));
    return decoded is Map
        ? decoded.cast<String, Object?>()
        : <String, Object?>{};
  } catch (_) {
    return <String, Object?>{};
  }
}

Future<void> _writeAtomicText(String filePath, String contents) async {
  final target = File(filePath);
  await target.parent.create(recursive: true);
  final temporary = File('$filePath.codex-remote.tmp');
  await temporary.writeAsString(contents, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(filePath);
}

Map<String, String> _tomlRootValues(String text) => _tomlValues(text, null);
Map<String, String> _tomlTableValues(String text, String table) =>
    _tomlValues(text, table);

bool? _tomlBooleanValue(String text, String table, String key) {
  String? currentTable;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    final header = RegExp(r'^\[([^\]]+)\]').firstMatch(line);
    if (header != null) {
      currentTable = header.group(1)!.trim();
      continue;
    }
    if (currentTable != table) continue;
    final match = RegExp(
      '^${RegExp.escape(key)}\\s*=\\s*(true|false)(?:\\s*#.*)?\\u0024',
    ).firstMatch(line);
    if (match != null) return match.group(1) == 'true';
  }
  return null;
}

Map<String, String> _tomlValues(String text, String? table) {
  final values = <String, String>{};
  String? currentTable;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    final header = RegExp(r'^\[([^]]+)\]').firstMatch(line);
    if (header != null) {
      currentTable = header.group(1)!.trim();
      continue;
    }
    if (currentTable != table) continue;
    final match = RegExp(
      r'^([A-Za-z0-9_]+)\s*=\s*"((?:\\.|[^"])*)"',
    ).firstMatch(line);
    if (match == null) continue;
    values[match.group(1)!] = _unescapeToml(match.group(2)!);
  }
  return values;
}

String _replaceTomlRoot(String text, Map<String, String?> replacements) {
  final output = <String>[];
  var inRoot = true;
  var inserted = false;
  void insert() {
    if (inserted) return;
    for (final entry in replacements.entries) {
      if (entry.value != null) {
        output.add('${entry.key} = "${_escapeToml(entry.value!)}"');
      }
    }
    if (output.isNotEmpty && output.last.isNotEmpty) output.add('');
    inserted = true;
  }

  for (final raw in const LineSplitter().convert(text)) {
    if (raw.trimLeft().startsWith('[')) {
      insert();
      inRoot = false;
    }
    final key = inRoot
        ? RegExp(r'^\s*([A-Za-z0-9_]+)\s*=').firstMatch(raw)?.group(1)
        : null;
    if (key != null && replacements.containsKey(key)) continue;
    output.add(raw);
  }
  insert();
  return '${output.join('\n').replaceFirst(RegExp(r'\n+$'), '')}\n';
}

String _escapeToml(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
String _unescapeToml(String value) =>
    value.replaceAll('\\"', '"').replaceAll('\\\\', '\\');

String _normalizedApiBase(String value) {
  final normalized = normalizeCodexBaseUrl(value);
  return normalized.isEmpty ? 'https://api.openai.com/v1' : normalized;
}

HttpClient _httpClient(String proxy) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  if (proxy.isNotEmpty) {
    client.findProxy = (_) => 'PROXY ${Uri.parse(proxy).authority}';
  }
  return client;
}

Future<int> _httpStatus(
  Uri uri,
  String apiKey,
  String proxy,
  Object body,
) async {
  final client = _httpClient(proxy);
  try {
    final request = await client
        .postUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 25));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _boundedResponse(
  HttpClientResponse response,
  int maximum,
) async {
  final builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response) {
    length += chunk.length;
    if (length > maximum) throw StateError('模型列表响应过大，无法安全加载');
    builder.add(chunk);
  }
  return builder.takeBytes();
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
