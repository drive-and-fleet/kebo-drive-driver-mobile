import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import '../../logging/app_log.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.services, this.onClaimed});
  final AppServices services;
  final VoidCallback? onClaimed;

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> {
  /// A home_screen AppBar explicit frissítés gombja hívja.
  Future<void> refresh() => _load();
  final _plate = TextEditingController();
  List<DriverLeg> _results = const [];
  bool _loading = true;
  bool _busy = false;
  String? _message;

  /// A most felvett utak: a kártyán „Felvetted” jelzés, nem nyílik meg az adatlap.
  final Set<String> _claimed = {};

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Szabad fuvarok');
    _load();
  }

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    log.info('work', 'Szabad fuvarok lekérése${_plate.text.trim().isEmpty ? '' : ' (rendszám: ${_plate.text.trim()})'}');
    setState(() { _loading = true; _message = null; });
    try {
      final results = await widget.services.work.availableLegs(plate: _plate.text.trim());
      log.info('work', 'Szabad fuvarok: ${results.length}');
      // Egy autó útjai egymás után (körfuvarnál az odaút elöl), az autók indulás szerint.
      final grouped = groupByVehicle(results, (a, b) {
        final x = a.plannedStart, y = b.plannedStart;
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return x.compareTo(y);
      });
      if (mounted) setState(() => _results = grouped);
    } catch (e) {
      log.warn('work', 'Szabad fuvarok nem töltődtek be', e);
      if (mounted) setState(() => _message = 'A szabad fuvarok listája internetkapcsolatot igényel. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _claim(DriverLeg leg) async {
    setState(() { _busy = true; _message = 'Offline munkacsomag letöltése…'; });
    try {
      await widget.services.work.claimAndDownload(leg);
      widget.onClaimed?.call();
      if (!mounted) return;
      setState(() { _message = null; _claimed.add(leg.legKey); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Felvetted: a fuvar a Munkáid között van, offline is elérhető.')));
    } catch (e) {
      log.warn('work', 'Fuvar felvétele nem sikerült: ${leg.legKey}', e);
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        // Rövid listánál is le lehessen húzni a frissítéshez.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Szűrés rendszámra', hintText: 'ABC-123'),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: _busy ? null : _load, child: const Text('Szűrés')),
            const SizedBox(width: 6),
            IconButton.outlined(
              onPressed: _loading || _busy ? null : _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Frissítés',
            ),
          ]),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!, style: const TextStyle(color: AppColors.signalRed)),
            ),
          if (!_loading && _message == null && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text(
                'Nincs jelenleg felvehető szabad fuvar. Ez azt is jelentheti, hogy a sofőrszolgálatod még nem engedélyezte a sofőr önkiosztást — kérdezd meg az ügyintézőt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
              ),
            ),
          const SizedBox(height: 12),
          for (final leg in _results)
            LegCard(
              leg: leg,
              onTap: () {},
              showStatus: false,
              // Az utak sorban mennek: az előző út teljesülése előtt ez nem vehető fel.
              trailing: _claimed.contains(leg.legKey)
                  ? const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check_circle, color: AppColors.signalGreen),
                      SizedBox(width: 6),
                      Text('Felvetted', style: TextStyle(color: AppColors.signalGreen, fontWeight: FontWeight.w700)),
                    ])
                  : leg.waitsForPreviousLeg
                  ? const Flexible(
                      child: Text('Előbb az előző útnak kell teljesülnie',
                          textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: AppColors.ink600)),
                    )
                  : FilledButton(onPressed: _busy ? null : () => _claim(leg), child: const Text('Felveszem')),
            ),
        ],
      ),
    );
  }
}
