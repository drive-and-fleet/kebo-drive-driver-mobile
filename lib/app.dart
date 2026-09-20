import 'package:flutter/material.dart';

import 'services/app_services.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/login_screen.dart';

class FleetDriverApp extends StatefulWidget {
  const FleetDriverApp({super.key, required this.services});
  final AppServices services;

  @override
  State<FleetDriverApp> createState() => _FleetDriverAppState();
}

class _FleetDriverAppState extends State<FleetDriverApp> {
  @override
  void initState() {
    super.initState();
    widget.services.auth.addListener(_changed);
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_changed);
    widget.services.sync.disposeService();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fleet Driver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1565c0)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: widget.services.auth.isSignedIn
          ? HomeScreen(services: widget.services)
          : LoginScreen(services: widget.services),
    );
  }
}
