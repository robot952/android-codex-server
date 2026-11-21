import 'package:codex_remote/src/app/fork_thread_title.dart';
import 'package:codex_remote/src/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ForkThreadTitle from(String title, {String preview = ''}) =>
      ForkThreadTitle.fromThread(
        AgentThread(id: 'a', title: title, preview: preview),
      );

  test('unnamed fork families use preview then a stable empty fallback', () {
    expect(from('', preview: '  原问题\n第二行').next, '原问题 (1)');
    expect(from(' ', preview: ' ').next, '未命名任务 (1)');
  });

  test(
    'only the final numeric suffix is interpreted and only exact names collide',
    () {
      final family = from('  比价 (2026) 项目🧪 (4) ');
      family.observe('比价 (2026) 项目🧪 (5) 延长');
      family.observe('比价 (2026) 项目🧪 (05)');
      family.observe('比价 (2026) 项目🧪 (6)');
      expect(family.next, '比价 (2026) 项目🧪 (5)');
      family.observe(family.next);
      expect(family.next, '比价 (2026) 项目🧪 (7)');
      expect(from('项目 (2026 归档)').next, '项目 (2026 归档) (1)');
      expect(
        from('项目 (99999999999999999999)').next,
        '项目 (100000000000000000000)',
      );
    },
  );
}
