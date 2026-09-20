import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _plate = TextEditingController();
  List<DriverLeg> _results = const [];
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final plate = _plate.text.trim();
    if (plate.isEmpty) return;
    setState(() { _busy = true; _message = null; });
    try {
      final results = await widget.services.work.searchByPlate(plate);
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _message = 'A keresés internetkapcsolatot igényel. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim(DriverLeg leg) async {
    setState(() { _busy = true; _message = 'Offline munkacsomag letöltése…'; });
    try {
      await widget.services.work.claimAndDownload(leg);
      if (!mounted) return;
      setState(() => _message = null);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fuvar felvéve és offline használatra letöltve.')));
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey),
      ));
      await _search();
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Rendszám alapján az adott sofőrszolgálatnál elérhető, szabad LEG-ek kereshetők.'),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _plate, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Rendszám', hintText: 'ABC-123'), onSubmitted: (_) => _search())),
          const SizedBox(width: 10),
          FilledButton(onPressed: _busy ? null : _search, child: const Text('Keresés')),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        const SizedBox(height: 12),
        for (final leg in _results)
          LegCard(
            leg: leg,
            onTap: () {},
            trailing: FilledButton(onPressed: _busy ? null : () => _claim(leg), child: const Text('Felveszem')),
          ),
      ],
    );
  }
}
