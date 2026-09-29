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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(log.flush());
      widget.services.work.onBackground();
    }
    if (state == AppLifecycleState.resumed) {
      widget.services.work.onForeground();
      // Megnyitották: az értesítések és a jelvény nullázódnak; a gyűlt pontok felmennek.
      unawaited(widget.services.push.clear());
      unawaited(widget.services.location.evaluate());
      unawaited(widget.services.location.upload());
    }
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    widget.services.sync.disposeService();
    widget.services.work.stopAutoRefresh();
    super.dispose();
  }

  /// A kijelentkezés (vagy a lejárt belépés) után minden megnyitott oldal bezárul,
  /// hogy azonnal a belépési képernyő látszódjon (ne maradjon fölötte pl. a Szinkron).
  final _navigator = GlobalKey<NavigatorState>();

  void _changed() {
    if (!widget.services.auth.isSignedIn) _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Drive and Fleet Sofőr',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: widget.services.auth.isSignedIn
          ? HomeScreen(services: widget.services)
          : LoginScreen(services: widget.services),
    );
  }
}
