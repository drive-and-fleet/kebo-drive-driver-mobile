import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../../logging/app_log.dart';

class TransferCreateScreen extends StatefulWidget {
  const TransferCreateScreen({super.key, required this.services, required this.leg});
  final AppServices services;
  final DriverLeg leg;

  @override
  State<TransferCreateScreen> createState() => _TransferCreateScreenState();
}

class _TransferCreateScreenState extends State<TransferCreateScreen> {
  List<Map<String, dynamic>> _drivers = const [];
  bool _busy = true;
  String? _selected;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Átadás másik sofőrnek (${widget.leg.legKey})');
    _load();
  }

  Future<void> _load() async {
    try {
      final drivers = await widget.services.api.serviceDrivers(widget.leg.serviceOrgId);
      if (mounted) setState(() => _drivers = drivers);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Az átadás internetkapcsolatot igényel: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_selected == null) return;
    setState(() => _busy = true);
    try {
      log.info('transfer', 'Átadási kérés: ${widget.leg.legKey} → sofőr $_selected');
      await widget.services.api.requestTransfer(widget.leg.legKey, _selected!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Átadási kérés elküldve. A másik sofőr jóváhagyása szükséges.')));
      Navigator.pop(context);
    } catch (e) {
      log.warn('transfer', 'Átadási kérés nem sikerült: ${widget.leg.legKey}', e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fuvar átadása')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${widget.leg.registrationNumber} • ${widget.leg.fromAddress} → ${widget.leg.toAddress}'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selected,
            decoration: const InputDecoration(labelText: 'Átvevő sofőr'),
            items: _drivers.map((d) => DropdownMenuItem(
              value: '${d['driverId']}',
              child: Text('${d['lastName']} ${d['firstName']} • ${d['email']}'),
            )).toList(),
            onChanged: _busy ? null : (value) => setState(() => _selected = value),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy || _selected == null ? null : _submit, child: const Text('Átadási kérés elküldése')),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        ]),
      ),
    );
  }
}
