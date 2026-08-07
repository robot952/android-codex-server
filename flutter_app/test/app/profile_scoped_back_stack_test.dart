import 'package:codex_remote/src/app/profile_scoped_back_stack.dart';
import 'package:flutter_test/flutter_test.dart';

class _Frame {
  const _Frame(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is _Frame && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

void main() {
  group('ProfileScopedBackStack', () {
    test('keeps nested navigation independent for each scope', () {
      final stack = ProfileScopedBackStack<_Frame>();
      const firstParent = _Frame('first-parent');
      const firstChild = _Frame('first-child');
      const secondParent = _Frame('second-parent');

      stack.push('server-a', firstParent);
      stack.push('server-a', firstChild);
      stack.push('server-b', secondParent);

      expect(stack.peek('server-a'), same(firstChild));
      expect(stack.peek('server-b'), same(secondParent));
      expect(stack.pop('server-a'), same(firstChild));
      expect(stack.pop('server-a'), same(firstParent));
      expect(stack.pop('server-a'), isNull);
      expect(stack.pop('server-b'), same(secondParent));
    });

    test('ignores blank scope ids', () {
      final stack = ProfileScopedBackStack<_Frame>();
      const frame = _Frame('frame');

      stack.push('', frame);
      stack.push('   ', frame);

      expect(stack.size(''), 0);
      expect(stack.size('   '), 0);
      expect(stack.beginPendingPop('   '), isNull);
    });

    test('reports size and clears only the requested scope', () {
      final stack = ProfileScopedBackStack<_Frame>();
      const first = _Frame('first');
      const second = _Frame('second');
      const other = _Frame('other');
      stack
        ..push('server-a', first)
        ..push('server-a', second)
        ..push('server-b', other);
      expect(stack.beginPendingPop('server-a'), same(second));

      expect(stack.size('server-a'), 2);
      expect(stack.size('server-b'), 1);

      stack.clear('server-a');

      expect(stack.size('server-a'), 0);
      expect(stack.peek('server-a'), isNull);
      expect(stack.isPopPending('server-a'), isFalse);
      expect(stack.size('server-b'), 1);
      expect(stack.peek('server-b'), same(other));
    });

    test('top checks and conditional pops use identity', () {
      final stack = ProfileScopedBackStack<_Frame>();
      final parent = _Frame('parent');
      final child = _Frame('same');
      final equalButDistinctChild = _Frame('same');
      stack
        ..push('server', parent)
        ..push('server', child);

      expect(child, equalButDistinctChild);
      expect(identical(child, equalButDistinctChild), isFalse);
      expect(stack.isTop('server', equalButDistinctChild), isFalse);
      expect(stack.popIfTop('server', equalButDistinctChild), isNull);
      expect(stack.peek('server'), same(child));
      expect(stack.popIfTop('server', child), same(child));
      expect(stack.popIfTop('server', parent), same(parent));
    });

    test('pending pop makes repeated requests idempotent', () {
      final stack = ProfileScopedBackStack<_Frame>();
      final parent = _Frame('parent');
      final child = _Frame('child');
      stack
        ..push('server', parent)
        ..push('server', child);

      expect(stack.beginPendingPop('server'), same(child));
      expect(stack.isPopPending('server'), isTrue);
      expect(stack.beginPendingPop('server'), isNull);
      expect(stack.completePendingPop('server', child), same(child));
      expect(stack.isPopPending('server'), isFalse);
      expect(stack.peek('server'), same(parent));
    });

    test('cancel retains the frame and permits retry', () {
      final stack = ProfileScopedBackStack<_Frame>();
      final root = _Frame('root');
      final child = _Frame('child');
      stack
        ..push('server', root)
        ..push('server', child);

      expect(stack.beginPendingPop('server'), same(child));
      expect(stack.cancelPendingPop('server', _Frame('child')), isFalse);
      expect(stack.isPopPending('server'), isTrue);
      expect(stack.cancelPendingPop('server', child), isTrue);
      expect(stack.isPopPending('server'), isFalse);
      expect(stack.peek('server'), same(child));

      expect(stack.beginPendingPop('server'), same(child));
      expect(stack.completePendingPop('server', child), same(child));
      expect(stack.peek('server'), same(root));
    });

    test('direct pop clears a pending marker for the same frame', () {
      final stack = ProfileScopedBackStack<_Frame>();
      final frame = _Frame('frame');
      stack.push('server', frame);
      expect(stack.beginPendingPop('server'), same(frame));

      expect(stack.pop('server'), same(frame));

      expect(stack.isPopPending('server'), isFalse);
      expect(stack.size('server'), 0);
    });

    test('late completion cannot pop a newer equal-valued frame', () {
      final stack = ProfileScopedBackStack<_Frame>();
      final parent = _Frame('parent');
      final child = _Frame('same');
      final newer = _Frame('same');
      stack
        ..push('server', parent)
        ..push('server', child);
      expect(stack.beginPendingPop('server'), same(child));
      stack.push('server', newer);

      expect(stack.completePendingPop('server', child), isNull);
      expect(stack.peek('server'), same(newer));
      expect(stack.size('server'), 3);
      expect(stack.isPopPending('server'), isFalse);
    });
  });
}
