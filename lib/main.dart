import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/window_setup.dart';
import 'data/business_store.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Developer/test isolation: BIZKHATA_DATA_DIR points the app at a separate
  // data folder so testing never touches a shop's real data.
  final devDir = Platform.environment['BIZKHATA_DATA_DIR'];
  if (devDir != null && devDir.isNotEmpty) {
    BusinessStore.overrideRoot = devDir;
    SharedPreferences.setPrefix('bizkhata_dev.');
  }

  await initializeDateFormatting('en');
  await initializeDateFormatting('bn');
  await loadSavedLanguage();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await setupDesktopWindow();
  }

  runApp(const ProviderScope(child: BizKhataApp()));
}
