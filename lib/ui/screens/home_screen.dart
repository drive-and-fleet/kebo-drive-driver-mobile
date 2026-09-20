import 'package:flutter/material.dart';

import '../../services/app_services.dart';
import 'my_work_screen.dart';
import 'search_screen.dart';
import 'sync_screen.dart';
import 'transfers_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      MyWorkScreen(services: widget.services),
      SearchScreen(services: widget.services),
      TransfersScreen(services: widget.services),
      SyncScreen(services: widget.services),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Munkáim', 'Fuvar keresése', 'Átadások', 'Szinkron'][_index]),
        actions: [
          AnimatedBuilder(
            animation: widget.services.sync,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: widget.services.sync.pending == 0
                    ? const Icon(Icons.cloud_done_outlined)
                    : Badge(
                        label: Text('${widget.services.sync.pending}'),
                        child: const Icon(Icons.cloud_upload_outlined),
                      ),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'Munkáim'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Keresés'),
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'Átadás'),
          NavigationDestination(icon: Icon(Icons.sync), label: 'Szinkron'),
        ],
      ),
    );
  }
}
