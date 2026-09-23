import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'config/app_config.dart';
import 'services/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A social bejelentkezés (Google/Facebook/Apple) ki van kapcsolva alapból;
  // enélkül az app valódi Firebase projekt nélkül is elindul.
  if (AppConfig.socialLoginEnabled) {
    await Firebase.initializeApp(options: AppConfig.firebaseOptions);
  }
  final services = await AppServices.create();
  runApp(FleetDriverApp(services: services));
}
