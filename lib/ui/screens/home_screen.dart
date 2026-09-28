import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../models/trip_rules.dart';
import '../../services/app_services.dart';
import '../theme.dart';
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

  /// Egy másik képernyő kéri, hogy a kezdőképernyő ezt a fület mutassa (pl. lezárás után a Ma).
  static final ValueNotifier<int?> tabRequest = ValueNotifier<int?>(null);

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
  /// Az út, amelyikkel a sofőr éppen úton van: minden fülön egy koppintásra nyílik.
  DriverLeg? _running;

  void _onTabRequest() {
    final tab = HomeScreen.tabRequest.value;
    if (tab == null || !mounted) return;
    HomeScreen.tabRequest.value = null;
    setState(() => _index = tab);
    unawaited(_refreshCurrentTab());
    unawaited(_searchKey.currentState?.refresh());
  }

  Future<void> _loadRunning() async {
    final running = runningLeg(await widget.services.local.cachedLegs());
    if (!mounted) return;
    if (running?.legKey != _running?.legKey || running?.toPlace != _running?.toPlace) setState(() => _running = running);
  }

  void _openRunning() {
    final leg = _running;
    if (leg == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
  }

  @override
  void initState() {
    super.initState();
    widget.services.work.addListener(_loadRunning);
    widget.services.sync.addListener(_loadRunning);
    HomeScreen.tabRequest.addListener(_onTabRequest);
    _loadRunning();
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
    widget.services.work.removeListener(_loadRunning);
    widget.services.sync.removeListener(_loadRunning);
    HomeScreen.tabRequest.removeListener(_onTabRequest);
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
      body: Column(children: [
        // A „Ma” fülön a nagy kártya maga a futó út; a többi fülön ez a sáv viszi oda.
        if (_running != null && _index != 0) _RunningBar(leg: _running!, onTap: _openRunning),
        Expanded(child: IndexedStack(index: _index, children: pages)),
      ]),
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

/// „Úton vagy: ABC-123 → Cél” – koppintásra megnyílik a futó fuvar.
class _RunningBar extends StatelessWidget {
  const _RunningBar({required this.leg, required this.onTap});
  final DriverLeg leg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.signalRed,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Icon(Icons.directions_car, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Úton: ${leg.registrationNumber} → ${leg.toPlace}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              const Text('Megnyitás', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const Icon(Icons.chevron_right, color: Colors.white),
            ]),
          ),
        ),
      );
}
