import 'package:integration_test/integration_test.dart';

import '../test/ui/provider_transport_workflow_test.dart' as workflows;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  workflows.main(device: true);
}
