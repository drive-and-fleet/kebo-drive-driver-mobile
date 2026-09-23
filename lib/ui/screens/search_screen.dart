import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _message = null; });
    try {
      final results = await widget.services.work.availableLegs(plate: _plate.text.trim());
      if (mounted) setState(() => _results = results);
    } catch (e) {
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
      setState(() => _message = null);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fuvar felvéve és offline használatra letöltve.')));
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey),
      ));
      await _load();
    } catch (e) {
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
              trailing: FilledButton(onPressed: _busy ? null : () => _claim(leg), child: const Text('Felveszem')),
            ),
        ],
      ),
    );
  }
}
