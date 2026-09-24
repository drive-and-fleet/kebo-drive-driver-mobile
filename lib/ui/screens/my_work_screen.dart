import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';
import '../../logging/app_log.dart';

class MyWorkScreen extends StatefulWidget {
  const MyWorkScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<MyWorkScreen> createState() => MyWorkScreenState();
}

class MyWorkScreenState extends State<MyWorkScreen> {
  /// A home_screen AppBar explicit frissítés gombja hívja — nem csak a
  /// pull-to-refresh legyen az egyetlen (nem mindig nyilvánvaló) módja annak,
  /// hogy a sofőr lekérdezze, jött-e új kiosztás.
  Future<void> refresh() => _load(refresh: true);
  List<DriverLeg> _legs = const [];
  List<DriverLeg> _completed = const [];
  Map<String, LegSyncState> _syncStates = const {};
  bool _loading = true;
  String? _message;

  /// Aktív munkák, vagy a sofőr teljesített fuvarai az elmúlt [_days] napból.
  _WorkView _view = _WorkView.active;
  int _days = 30;
  bool _completedFromServer = true;

  /// Nézetenként külön rendezés: aktívnál a legközelebbi felvétel elöl, a
  /// teljesítetteknél a legutóbbi.
  final Map<_WorkView, _SortOrder> _sort = {_WorkView.active: _SortOrder.pickupAsc, _WorkView.completed: _SortOrder.pickupDesc};

  List<DriverLeg> get _visibleLegs {
    final legs = _view == _WorkView.active ? _legs.where((l) => l.status != 'COMPLETED').toList() : [..._completed];
    int byPickup(DriverLeg a, DriverLeg b) {
      final x = a.plannedStart, y = b.plannedStart;
      if (x == null && y == null) return 0;
      if (x == null) return 1; // időpont nélküliek a végére
      if (y == null) return -1;
      return x.compareTo(y);
    }
    switch (_sort[_view]!) {
      case _SortOrder.pickupAsc:
        legs.sort(byPickup);
      case _SortOrder.pickupDesc:
        legs.sort((a, b) => a.plannedStart == null || b.plannedStart == null ? byPickup(a, b) : byPickup(b, a));
      case _SortOrder.plate:
        legs.sort((a, b) {
          final c = a.registrationNumber.toUpperCase().compareTo(b.registrationNumber.toUpperCase());
          return c != 0 ? c : byPickup(a, b);
        });
    }
    return legs;
  }

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Munkáim');
    widget.services.sync.addListener(_refreshLocal);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_refreshLocal);
    super.dispose();
  }

  /// A háttérszinkron változásai (státusz, feltöltési jelzés) hálózat nélkül,
  /// a lokális adatbázisból.
  Future<void> _refreshLocal() async {
    final legs = await widget.services.local.cachedLegs();
    final states = await widget.services.local.legSyncStates();
    if (mounted) setState(() { _legs = legs; _syncStates = states; });
  }

  Future<void> _load({bool refresh = true}) async {
    setState(() => _loading = true);
    try {
      if (_view == _WorkView.active) {
        if (refresh) log.info('ui', 'Munkáim frissítése');
        final legs = await widget.services.work.myWork(refreshOnline: refresh);
        if (mounted) setState(() => _legs = legs);
      } else {
        final result = await widget.services.work.completedWork(_days);
        if (mounted) setState(() { _completed = result.legs; _completedFromServer = result.fromServer; });
      }
      final states = await widget.services.local.legSyncStates();
      if (mounted) setState(() { _syncStates = states; _message = null; });
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _switchView(_WorkView view) {
    if (view == _view) return;
    log.info('ui', 'Munkáim nézet: ${view == _WorkView.active ? 'aktív' : 'teljesített'}');
    setState(() => _view = view);
    _load();
  }

  void _switchDays(int days) {
    if (days == _days) return;
    log.info('ui', 'Teljesített időszak: $days nap');
    setState(() => _days = days);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final completed = _view == _WorkView.completed;
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_message != null) Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SegmentedButton<_WorkView>(
              segments: const [
                ButtonSegment(value: _WorkView.active, icon: Icon(Icons.route_outlined), label: Text('Aktív munkák')),
                ButtonSegment(value: _WorkView.completed, icon: Icon(Icons.task_alt), label: Text('Teljesített')),
              ],
              selected: {_view},
              onSelectionChanged: (selection) => _switchView(selection.first),
            ),
          ),
          Row(children: [
            const Text('Rendezés:'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<_SortOrder>(
                isExpanded: true,
                value: _sort[_view],
                items: const [
                  DropdownMenuItem(value: _SortOrder.pickupAsc, child: Text('Felvétel ideje – legkorábbi elöl')),
                  DropdownMenuItem(value: _SortOrder.pickupDesc, child: Text('Felvétel ideje – legutóbbi elöl')),
                  DropdownMenuItem(value: _SortOrder.plate, child: Text('Rendszám (A–Z)')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  log.info('ui', 'Rendezés: ${v.name}');
                  setState(() => _sort[_view] = v);
                },
              ),
            ),
          ]),
          if (completed) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final days in const [30, 90, 365])
                  ChoiceChip(
                    label: Text(days == 365 ? 'Elmúlt 1 év' : 'Elmúlt $days nap'),
                    selected: _days == days,
                    onSelected: (_) => _switchDays(days),
                  ),
              ],
            ),
            if (!_loading && !_completedFromServer)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Nincs kapcsolat a szerverrel: csak a telefonon tárolt teljesített fuvarok látszanak.'),
              ),
            const SizedBox(height: 8),
          ],
          if (!_loading && _visibleLegs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 20),
              child: Column(children: [
                Icon(completed ? Icons.task_alt : Icons.route_outlined, size: 64),
                const SizedBox(height: 12),
                Text(completed ? 'Ebben az időszakban nincs teljesített fuvarod.' : 'Nincs letöltött vagy kiosztott fuvar.', textAlign: TextAlign.center),
              ]),
            ),
          for (final leg in _visibleLegs)
            LegCard(
              leg: leg,
              syncState: _syncStates[leg.legKey],
              onTap: () async {
                log.info('ui', 'Fuvar megnyitva: ${leg.legKey} (${leg.orderNo} #${leg.sequenceNo}, ${leg.status})');
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey),
                ));
                await _load(refresh: false);
              },
            ),
        ],
      ),
    );
  }
}

enum _WorkView { active, completed }

enum _SortOrder { pickupAsc, pickupDesc, plate }
