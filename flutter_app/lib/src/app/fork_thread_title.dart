import '../domain/models.dart';

/// A numbered family of titles. An explicit existing "(n)" suffix advances the
/// starting number, but numbers belonging to another base must not affect it.
class ForkThreadTitle {
  ForkThreadTitle._(this.base, this.start);

  factory ForkThreadTitle.fromThread(AgentThread thread) {
    final title = thread.title.trim();
    final fallback = thread.preview.trim().split('\n').first.trim();
    final source = title.isNotEmpty
        ? title
        : fallback.isNotEmpty
        ? fallback
        : '未命名任务';
    final match = _suffix.firstMatch(source);
    if (match != null) {
      final base = source.substring(0, match.start).trimRight();
      if (base.isNotEmpty) {
        return ForkThreadTitle._(base, BigInt.parse(match[1]!) + BigInt.one);
      }
    }
    return ForkThreadTitle._(source, BigInt.one);
  }

  static final _suffix = RegExp(r'\(([0-9]+)\)$');
  static final _canonicalNumber = RegExp(r'^[1-9][0-9]*$');
  final String base;
  final BigInt start;
  final _occupied = <BigInt>{};
  String get searchTerm => '$base (';

  void observe(String title) {
    final name = title.trim();
    if (!name.startsWith(searchTerm) || !name.endsWith(')')) return;
    final suffix = name.substring(searchTerm.length, name.length - 1);
    if (!_canonicalNumber.hasMatch(suffix)) return;
    _occupied.add(BigInt.parse(suffix));
  }

  String get next {
    var index = start;
    while (_occupied.contains(index)) {
      index += BigInt.one;
    }
    return '$base ($index)';
  }
}
