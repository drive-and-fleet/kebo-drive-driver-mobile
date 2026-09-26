import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app.dart';
import 'config/app_config.dart';
import 'logging/app_log.dart';
import 'services/app_services.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.instance.init();
    // Minden nem kezelt hiba a naplóba kerül, így egy hibajelentés megmutatja.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      log.error('flutter', details.exceptionAsString(), null, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.error('platform', 'Nem kezelt hiba', error, stack);
      return true;
    };
    try {
      final info = await PackageInfo.fromPlatform();
      log.info('app', 'Indulás: v${info.version}+${info.buildNumber}, ${Platform.operatingSystem} ${Platform.operatingSystemVersion}, API ${AppConfig.driverApiBaseUrl}');
    } catch (e) {
      log.info('app', 'Indulás: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}, API ${AppConfig.driverApiBaseUrl}');
    }
    // A social bejelentkezés és a push-értesítés alapból ki van kapcsolva;
    // enélkül az app valódi Firebase projekt nélkül is elindul.
    if (AppConfig.firebaseNeeded) {
      await Firebase.initializeApp(options: AppConfig.firebaseOptions);
    }
    final services = await AppServices.create();
    runApp(FleetDriverApp(services: services));
  }, (error, stack) => log.error('zone', 'Nem kezelt hiba', error, stack));
}
