import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';

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
  bool _loading = true;
  bool _hideCompleted = true;
  String? _message;

  List<DriverLeg> get _visibleLegs =>
      _hideCompleted ? _legs.where((l) => l.status != 'COMPLETED').toList() : _legs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = true}) async {
    setState(() => _loading = true);
    try {
      final legs = await widget.services.work.myWork(refreshOnline: refresh);
      if (mounted) setState(() { _legs = legs; _message = null; });
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_message != null) Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
          SwitchListTile(
            title: const Text('Csak folyamatban lévők'),
            value: _hideCompleted,
            onChanged: (v) => setState(() => _hideCompleted = v),
          ),
          if (!_loading && _visibleLegs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 72, horizontal: 20),
              child: Column(children: [Icon(Icons.route_outlined, size: 64), SizedBox(height: 12), Text('Nincs letöltött vagy kiosztott fuvar.')]),
            ),
          for (final leg in _visibleLegs)
            LegCard(
              leg: leg,
              onTap: () async {
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
