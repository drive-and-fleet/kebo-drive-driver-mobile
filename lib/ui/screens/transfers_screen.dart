import 'package:flutter/material.dart';

import '../../services/app_services.dart';

class TransfersScreen extends StatefulWidget {
  const TransfersScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await widget.services.api.transfers();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = 'Az átadások kezelése online funkció. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(String id, bool approve) async {
    try {
      if (approve) {
        await widget.services.api.approveTransfer(id);
      } else {
        await widget.services.api.rejectTransfer(id);
      }
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          for (final item in _items)
            Card(
              child: ListTile(
                title: Text('Átadás • ${item['status']}'),
                subtitle: Text('Szakasz: ${item['orderLegId']}\nKezdeményező: ${item['fromDriverId']} → ${item['toDriverId']}'),
                isThreeLine: true,
                trailing: item['status'] == 'PENDING'
                    ? Wrap(spacing: 4, children: [
                        IconButton(onPressed: () => _act('${item['id']}', false), icon: const Icon(Icons.close), tooltip: 'Elutasítás'),
                        IconButton(onPressed: () => _act('${item['id']}', true), icon: const Icon(Icons.check), tooltip: 'Jóváhagyás'),
                      ])
                    : null,
              ),
            ),
          if (!_loading && _items.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Nincs átadási kérés.'))),
        ],
      ),
    );
  }
}
