import 'dart:async';

import 'package:flutter/material.dart';

import 'logging/app_log.dart';
import 'services/app_services.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/login_screen.dart';
import 'ui/theme.dart';

class FleetDriverApp extends StatefulWidget {
  const FleetDriverApp({super.key, required this.services});
  final AppServices services;

  @override
  State<FleetDriverApp> createState() => _FleetDriverAppState();
}

class _FleetDriverAppState extends State<FleetDriverApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    widget.services.auth.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Előtér/háttér váltás: sok mobilos hiba ekörül történik (félbehagyott szinkron).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log.info('app', 'Életciklus: ${state.name}');
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) unawaited(log.flush());
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    widget.services.sync.disposeService();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fleet Driver',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: widget.services.auth.isSignedIn
          ? HomeScreen(services: widget.services)
          : LoginScreen(services: widget.services),
    );
  }
}
