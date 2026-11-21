import 'package:integration_test/integration_test.dart';

import '../test/ui/turn_fork_test.dart' show runTurnForkTests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTurnForkTests(onDevice: true);
}
