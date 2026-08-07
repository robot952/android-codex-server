import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'theme.dart';

class WorkspacePickerDialog extends StatelessWidget {
  const WorkspacePickerDialog({
    required this.state,
    required this.onBrowse,
    required this.onConfirm,
    required this.onDismiss,
    super.key,
  });

  final AppUiState state;
  final ValueChanged<String?> onBrowse;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final currentPath = state.workspaceCurrentPath.trim();
    final error = state.workspaceError?.trim();
    final canConfirm = !state.workspaceLoading;

    return Positioned.fill(
      key: const ValueKey('workspace-picker-overlay'),
      child: Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: '选择工作目录',
        child: Stack(
          children: [
            ModalBarrier(
              dismissible: true,
              onDismiss: onDismiss,
              color: Colors.black.withValues(alpha: 0.58),
            ),
            Center(
              child: SafeArea(
                minimum: const EdgeInsets.all(16),
                child: Dialog(
                  insetPadding: EdgeInsets.zero,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _DialogHeading(),
                          const SizedBox(height: 14),
                          _CurrentPath(path: currentPath),
                          if (error?.isNotEmpty ?? false) ...[
                            const SizedBox(height: 10),
                            _ErrorMessage(message: error!),
                          ],
                          const SizedBox(height: 10),
                          Flexible(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: 144,
                                maxHeight: 340,
                              ),
                              child: _DirectoryList(
                                parentPath: state.workspaceParentPath,
                                directories: state.workspaceDirectories,
                                loading: state.workspaceLoading,
                                onBrowse: onBrowse,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              TextButton(
                                key: const ValueKey('workspace-picker-dismiss'),
                                onPressed: onDismiss,
                                child: const Text('稍后'),
                              ),
                              FilledButton(
                                key: const ValueKey('workspace-picker-confirm'),
                                onPressed: canConfirm && currentPath.isNotEmpty
                                    ? onConfirm
                                    : null,
                                child: const Text('使用此目录'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeading extends StatelessWidget {
  const _DialogHeading();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.folder_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('选择工作目录', style: Theme.of(context).textTheme.titleLarge),
        ),
      ],
    );
  }
}

class _CurrentPath extends StatelessWidget {
  const _CurrentPath({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('workspace-current-path'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: codexSurface,
        border: Border.all(color: codexBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          path.isEmpty ? '/' : path,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.error_outline,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            message,
            key: const ValueKey('workspace-picker-error'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }
}

class _DirectoryList extends StatelessWidget {
  const _DirectoryList({
    required this.parentPath,
    required this.directories,
    required this.loading,
    required this.onBrowse,
  });

  final String? parentPath;
  final List<RemoteDirectory> directories;
  final bool loading;
  final ValueChanged<String?> onBrowse;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: codexBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          children: [
            Positioned.fill(
              child: ListView.separated(
                key: const ValueKey('workspace-directory-list'),
                padding: EdgeInsets.zero,
                itemCount: _itemCount,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (parentPath != null && index == 0) {
                    return _DirectoryRow(
                      key: const ValueKey('workspace-parent-directory'),
                      name: '上一级',
                      icon: Icons.keyboard_arrow_up,
                      onTap: () => onBrowse(parentPath),
                    );
                  }
                  final directoryIndex = index - (parentPath == null ? 0 : 1);
                  if (directoryIndex < directories.length) {
                    final directory = directories[directoryIndex];
                    return _DirectoryRow(
                      key: ValueKey('workspace-directory-${directory.path}'),
                      name: directory.name,
                      icon: Icons.folder_outlined,
                      onTap: () => onBrowse(directory.path),
                    );
                  }
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        '当前目录没有子目录',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  );
                },
              ),
            ),
            if (loading)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Semantics(
                      label: '正在加载目录',
                      child: const SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  int get _itemCount {
    final count = directories.length + (parentPath == null ? 0 : 1);
    return count == 0 ? 1 : count;
  }
}

class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    required this.name,
    required this.icon,
    required this.onTap,
    super.key,
  });

  final String name;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Icon(
                icon,
                size: 21,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Icon(Icons.chevron_right, size: 18, color: codexMuted),
            ],
          ),
        ),
      ),
    );
  }
}
