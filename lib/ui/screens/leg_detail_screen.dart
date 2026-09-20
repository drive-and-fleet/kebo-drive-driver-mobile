import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import 'inspection_setup_screen.dart';
import 'transfer_create_screen.dart';

class LegDetailScreen extends StatefulWidget {
  const LegDetailScreen({super.key, required this.services, required this.legKey});
  final AppServices services;
  final String legKey;

  @override
  State<LegDetailScreen> createState() => _LegDetailScreenState();
}

class _LegDetailScreenState extends State<LegDetailScreen> {
  DriverLeg? _leg;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final leg = await widget.services.local.cachedLeg(widget.legKey);
    if (mounted) setState(() { _leg = leg; _busy = false; });
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() { _busy = true; _error = null; });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspection(String phase) async {
    final leg = _leg!;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionSetupScreen(services: widget.services, leg: leg, phase: phase),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final leg = _leg;
    return Scaffold(
      appBar: AppBar(title: Text(leg?.registrationNumber ?? 'Fuvar')),
      body: leg == null
          ? const Center(child: Text('A fuvar nincs letöltve erre a készülékre.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                _InfoCard(leg: leg),
                const SizedBox(height: 12),
                Text('Műveletek', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _inspection('PICKUP'),
                  icon: const Icon(Icons.assignment_outlined),
                  label: const Text('Átvételi jegyzőkönyv'),
                ),
                const SizedBox(height: 8),
                if (leg.status == 'ASSIGNED')
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _action(() => widget.services.work.startLeg(leg)),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('LEG indítása'),
                  ),
                if (leg.status == 'IN_PROGRESS') ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _inspection('DROPOFF'),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Leadási jegyzőkönyv'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _action(() => widget.services.work.completeLeg(leg)),
                    icon: const Icon(Icons.done_all),
                    label: const Text('LEG lezárása'),
                  ),
                ],
                if (leg.status == 'ASSIGNED') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => TransferCreateScreen(services: widget.services, leg: leg),
                            )),
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Átadás másik sofőrnek'),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Az offline műveletek a telefonon azonnal mentésre kerülnek. Internetkapcsolat esetén a Szinkron nézetből vagy automatikusan kerülnek a szerverre.'),
              ],
            ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.leg});
  final DriverLeg leg;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${leg.registrationNumber} ${[leg.make, leg.model].whereType<String>().join(' ')}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('Megrendelés: ${leg.orderNo} • LEG ${leg.sequenceNo}'),
          Text('Státusz: ${leg.status}'),
          const Divider(height: 24),
          Text('Felvétel: ${leg.fromAddress}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (leg.fromContactName != null) Text('Kapcsolat: ${leg.fromContactName} ${leg.fromContactPhone ?? ''}'),
          const SizedBox(height: 10),
          Text('Leadás: ${leg.toAddress}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (leg.toContactName != null) Text('Kapcsolat: ${leg.toContactName} ${leg.toContactPhone ?? ''}'),
          if (leg.vehicleUserName != null) ...[
            const Divider(height: 24),
            Text('Autó használója: ${leg.vehicleUserName}'),
            if (leg.vehicleUserPhone != null) Text(leg.vehicleUserPhone!),
            if (leg.vehicleUserEmail != null) Text(leg.vehicleUserEmail!),
          ],
        ]),
      ),
    );
  }
}
