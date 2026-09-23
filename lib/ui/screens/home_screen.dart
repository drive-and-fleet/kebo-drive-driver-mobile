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
  final _myWorkKey = GlobalKey<MyWorkScreenState>();
  final _searchKey = GlobalKey<SearchScreenState>();

  Future<void> _refreshCurrentTab() async {
    switch (_index) {
      case 0:
        await _myWorkKey.currentState?.refresh();
      case 1:
        await _searchKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      MyWorkScreen(key: _myWorkKey, services: widget.services),
      SearchScreen(key: _searchKey, services: widget.services, onClaimed: () => _myWorkKey.currentState?.refresh()),
      TransfersScreen(services: widget.services),
      SyncScreen(services: widget.services),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Munkáim', 'Szabad fuvarok', 'Átadások', 'Szinkron'][_index]),
        actions: [
          if (_index == 0 || _index == 1)
            IconButton(onPressed: _refreshCurrentTab, icon: const Icon(Icons.refresh), tooltip: 'Frissítés'),
          AnimatedBuilder(
            animation: widget.services.sync,
            builder: (_, __) => IconButton(
              tooltip: 'Szinkron',
              onPressed: () => setState(() => _index = 3),
              icon: widget.services.sync.pending == 0
                  ? const Icon(Icons.cloud_done_outlined)
                  : Badge(
                      label: Text('${widget.services.sync.pending}'),
                      child: const Icon(Icons.cloud_upload_outlined),
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
          NavigationDestination(icon: Icon(Icons.playlist_add_check_outlined), selectedIcon: Icon(Icons.playlist_add_check), label: 'Szabad fuvarok'),
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'Átadás'),
          NavigationDestination(icon: Icon(Icons.sync), label: 'Szinkron'),
        ],
      ),
    );
  }
}
