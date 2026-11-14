import 'package:integration_test/integration_test.dart';

import '../test/ui/markdown_code_selection_test.dart'
    show runMarkdownCodeSelectionTests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runMarkdownCodeSelectionTests(onDevice: true);
}
