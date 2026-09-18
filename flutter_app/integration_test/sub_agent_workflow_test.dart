import 'package:integration_test/integration_test.dart';

import '../test/ui/sub_agent_workflow_test.dart' as workflows;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  workflows.main(device: true);
}
