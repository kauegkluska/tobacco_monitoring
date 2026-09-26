import 'package:flutter/material.dart';

import 'app.dart';
import 'core/background.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundMonitor.init();
  runApp(const TobaccoMonitorApp());
}
