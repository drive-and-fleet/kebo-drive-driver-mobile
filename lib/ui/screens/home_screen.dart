import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app_services.dart';
import 'calendar_screen.dart';
import 'leg_detail_screen.dart';
import 'new_order_screen.dart';
import 'search_screen.dart';
import 'sync_screen.dart';
import 'today_screen.dart';
import 'transfers_screen.dart';
import '../../logging/app_log.dart';
import 'bug_report_screen.dart';

const _tabs = ['Ma', 'Előjegyzés', 'Szabad fuvarok'];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 0 Ma · 1 Előjegyzés · 2 Szabad fuvarok. A „Ma” a mai munka: a soron
  /// következő fuvar egy nagy gombbal, alatta a nap többi fuvarja.
  int _index = 0;
  final _todayKey = GlobalKey<TodayScreenState>();
  final _calendarKey = GlobalKey<CalendarScreenState>();
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

  /// Értesítésre koppintott: a mai munka frissül, és megnyílik az út (ha a telefonon van).
  Future<void> _openFromPush() async {
    final legKey = widget.services.push.openLeg.value;
    if (legKey == null || !mounted) return;
    widget.services.push.openLeg.value = null;
    setState(() => _index = 0);
    await _todayKey.currentState?.refresh();
    final known = (await widget.services.local.cachedLegs()).any((l) => l.legKey == legKey);
    if (!known || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: legKey)));
  }

  void _showForeground() {
    final text = widget.services.push.foregroundMessage.value;
    if (text == null || !mounted) return;
    widget.services.push.foregroundMessage.value = null;
    unawaited(_todayKey.currentState?.refresh());
    unawaited(_calendarKey.currentState?.refresh());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _refreshCurrentTab() async {
    switch (_index) {
      case 0:
        await _todayKey.currentState?.refresh();
      case 1:
        await _calendarKey.currentState?.refresh();
      case 2:
        await _searchKey.currentState?.refresh();
    }
  }

  Future<void> _newOrder() async {
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NewOrderScreen(services: widget.services)));
    if (created == true) {
      await _todayKey.currentState?.refresh();
      await _calendarKey.currentState?.refresh();
    }
  }

  void _menu(String action) {
    final page = switch (action) {
      'transfers' => TransfersScreen(services: widget.services),
      'sync' => Scaffold(appBar: AppBar(title: const Text('Szinkron')), body: SyncScreen(services: widget.services)),
      _ => BugReportScreen(services: widget.services),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => action == 'transfers' ? Scaffold(appBar: AppBar(title: const Text('Átadások')), body: page) : page));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      TodayScreen(key: _todayKey, services: widget.services, onBrowseFree: () => setState(() => _index = 2)),
      CalendarScreen(key: _calendarKey, services: widget.services),
      SearchScreen(key: _searchKey, services: widget.services, onClaimed: () {
        _todayKey.currentState?.refresh();
        _calendarKey.currentState?.refresh();
      }),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_tabs[_index]),
        actions: [
          if (_index == 0) IconButton(onPressed: _newOrder, icon: const Icon(Icons.add), tooltip: 'Új fuvar felvétele'),
          IconButton(onPressed: _refreshCurrentTab, icon: const Icon(Icons.refresh), tooltip: 'Frissítés'),
          AnimatedBuilder(
            animation: widget.services.sync,
            builder: (_, __) => widget.services.sync.pending == 0
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Feltöltésre vár',
                    onPressed: () => _menu('sync'),
                    icon: Badge(label: Text('${widget.services.sync.pending}'), child: const Icon(Icons.cloud_upload_outlined)),
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
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'transfers', child: ListTile(leading: Icon(Icons.swap_horiz), title: Text('Átadások'))),
              PopupMenuItem(value: 'sync', child: ListTile(leading: Icon(Icons.cloud_outlined), title: Text('Szinkron'))),
              PopupMenuItem(value: 'bug', child: ListTile(leading: Icon(Icons.bug_report_outlined), title: Text('Hibajelentés'))),
            ],
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          log.debug('ui', 'Fül: ${_tabs[value]}');
          setState(() => _index = value);
          // Visszatérve a friss állapot látszik (pl. a Szabad fuvarokból felvett út a Ma alatt).
          unawaited(_refreshCurrentTab());
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Ma'),
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'Előjegyzés'),
          NavigationDestination(icon: Icon(Icons.playlist_add_check_outlined), selectedIcon: Icon(Icons.playlist_add_check), label: 'Szabad fuvarok'),
        ],
      ),
    );
  }
}
