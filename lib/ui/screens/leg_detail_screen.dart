import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
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

  /// Egyetlen gomb minden állapothoz: megnyitja a szükséges jegyzőkönyvet, és
  /// annak lezárása után automatikusan elindítja/lezárja a fuvart — a sofőrnek
  /// nem kell tudnia, hogy ez a rendszerben két külön lépés.
  Future<void> _startTrip() async {
    final leg = _leg!;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionSetupScreen(services: widget.services, leg: leg, phase: 'PICKUP'),
    ));
    final pickup = await widget.services.local.inspectionForLeg(leg.legKey, 'PICKUP');
    if (pickup != null && ['COMPLETED_LOCAL', 'SYNCED'].contains(pickup.status)) {
      await _action(() => widget.services.work.startLeg(leg));
    } else {
      await _load();
    }
  }

  Future<void> _finishTrip() async {
    final leg = _leg!;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionSetupScreen(services: widget.services, leg: leg, phase: 'DROPOFF'),
    ));
    final dropoff = await widget.services.local.inspectionForLeg(leg.legKey, 'DROPOFF');
    if (dropoff != null && ['COMPLETED_LOCAL', 'SYNCED'].contains(dropoff.status)) {
      await _action(() => widget.services.work.completeLeg(leg));
    } else {
      await _load();
    }
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
                if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
                _InfoCard(leg: leg),
                const SizedBox(height: 16),
                if (leg.status == 'ASSIGNED')
                  FilledButton.icon(
                    onPressed: _busy ? null : _startTrip,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Fuvar indítása'),
                  ),
                if (leg.status == 'IN_PROGRESS')
                  FilledButton.icon(
                    onPressed: _busy ? null : _finishTrip,
                    icon: const Icon(Icons.done_all),
                    label: const Text('Fuvar lezárása'),
                  ),
                if (leg.status == 'ASSIGNED') ...[
                  const SizedBox(height: 10),
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
                const SizedBox(height: 16),
                const Text(
                  'Az offline rögzített adatok azonnal mentésre kerülnek a telefonon. Internetkapcsolat esetén a Szinkron nézetből vagy automatikusan feltöltődnek a szerverre.',
                  style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
                ),
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
          Row(children: [
            Expanded(
              child: Text(
                '${leg.registrationNumber} ${[leg.make, leg.model].whereType<String>().join(' ')}',
                style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: AppText.plate, fontWeight: FontWeight.w700),
              ),
            ),
            StatusPlate(leg.status),
          ]),
          const SizedBox(height: 6),
          Text('Fuvar: ${leg.orderNo} • Szakasz #${leg.sequenceNo}', style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
          const Divider(height: 24),
          Text('Felvétel: ${leg.fromAddress}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.body)),
          if (leg.fromContactName != null) Text('Kapcsolat: ${leg.fromContactName} ${leg.fromContactPhone ?? ''}'),
          const SizedBox(height: 10),
          Text('Leadás: ${leg.toAddress}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.body)),
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
