import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app_services.dart';
import 'active_trip_screen.dart';
import 'leg_detail_screen.dart';
import 'my_work_screen.dart';
import 'new_order_screen.dart';
import 'search_screen.dart';
import 'sync_screen.dart';
import 'transfers_screen.dart';
import '../../logging/app_log.dart';
import 'bug_report_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 0 Most · 1 Munkáim · 2 Szabad fuvarok · 3 Átadás. A „Most” van középen:
  /// a sofőr mindig látja, melyik fuvarban van éppen.
  int _index = 0;
  final _activeKey = GlobalKey<ActiveTripScreenState>();
  final _myWorkKey = GlobalKey<MyWorkScreenState>();
  final _searchKey = GlobalKey<SearchScreenState>();

  @override
  void initState() {
    super.initState();
    final push = widget.services.push;
    push.openLeg.addListener(_openFromPush);
    push.foregroundMessage.addListener(_showForeground);
    // Bejelentkezés után: értesítési engedély és a telefon regisztrálása (ha a push be van állítva).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await push.start(context);
      await widget.services.location.evaluate();
    });
  }

  @override
  void dispose() {
    widget.services.push.openLeg.removeListener(_openFromPush);
    widget.services.push.foregroundMessage.removeListener(_showForeground);
    super.dispose();
  }

  /// Értesítésre koppintott: a Munkáim frissül, és megnyílik az út (ha a telefonon van).
  Future<void> _openFromPush() async {
    final legKey = widget.services.push.openLeg.value;
    if (legKey == null || !mounted) return;
    widget.services.push.openLeg.value = null;
    setState(() => _index = 0);
    await _activeKey.currentState?.refresh();
    final known = (await widget.services.local.cachedLegs()).any((l) => l.legKey == legKey);
    if (!known || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: legKey)));
  }

  void _showForeground() {
    final text = widget.services.push.foregroundMessage.value;
    if (text == null || !mounted) return;
    widget.services.push.foregroundMessage.value = null;
    unawaited(_activeKey.currentState?.refresh());
    unawaited(_myWorkKey.currentState?.refresh());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _refreshCurrentTab() async {
    switch (_index) {
      case 0:
        await _activeKey.currentState?.refresh();
      case 1:
        await _myWorkKey.currentState?.refresh();
      case 2:
        await _searchKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ActiveTripScreen(key: _activeKey, services: widget.services, onBrowseFree: () => setState(() => _index = 2)),
      MyWorkScreen(key: _myWorkKey, services: widget.services),
      SearchScreen(key: _searchKey, services: widget.services, onClaimed: () {
        _myWorkKey.currentState?.refresh();
        _activeKey.currentState?.refresh();
      }),
      TransfersScreen(services: widget.services),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Most', 'Munkáim', 'Szabad fuvarok', 'Átadások'][_index]),
        actions: [
          if (_index <= 2)
            IconButton(onPressed: _refreshCurrentTab, icon: const Icon(Icons.refresh), tooltip: 'Frissítés'),
          AnimatedBuilder(
            animation: widget.services.sync,
            builder: (_, __) => IconButton(
              tooltip: 'Szinkron',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(appBar: AppBar(title: const Text('Szinkron')), body: SyncScreen(services: widget.services)),
              )),
              icon: widget.services.sync.pending == 0
                  ? const Icon(Icons.cloud_done_outlined)
                  : Badge(
                      label: Text('${widget.services.sync.pending}'),
                      child: const Icon(Icons.cloud_upload_outlined),
                    ),
            ),
          ),
          AnimatedBuilder(
            animation: widget.services.location,
            builder: (_, __) => widget.services.location.sharingLegKey == null
                ? const SizedBox.shrink()
                : const Tooltip(
                    message: 'Helyzet megosztva (fuvar közben)',
                    child: Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.my_location)),
                  ),
          ),
          IconButton(
            tooltip: 'Hibajelentés',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => BugReportScreen(services: widget.services),
            )),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: _index == 1
          ? FloatingActionButton.extended(
              onPressed: () async {
                final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => NewOrderScreen(services: widget.services),
                ));
                if (created == true) {
                  await _myWorkKey.currentState?.refresh();
                  await _activeKey.currentState?.refresh();
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Új fuvar'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          log.debug('ui', 'Fül: ${['Most', 'Munkáim', 'Szabad fuvarok', 'Átadás'][value]}');
          setState(() => _index = value);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.directions_car_outlined), selectedIcon: Icon(Icons.directions_car), label: 'Most'),
          NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'Munkáim'),
          NavigationDestination(icon: Icon(Icons.playlist_add_check_outlined), selectedIcon: Icon(Icons.playlist_add_check), label: 'Szabad fuvarok'),
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'Átadás'),
        ],
      ),
    );
  }
}
