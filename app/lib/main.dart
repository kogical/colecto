import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'data/platform/background_service.dart';
import 'data/repositories/backend_config.dart';
import 'ui/features/shell/mail_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final config = resolveBackendConfig();
  final controller = MailController(
    initialKind: config.kind,
    initialDaemonUrl: config.daemonUrl,
    initialToken: config.token,
    background: createBackgroundService(),
  );
  controller.initialize();
  runApp(ColectoApp(controller: controller));
}
