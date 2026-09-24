import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/sync_badge.dart';
import 'inspection_setup_screen.dart';
import 'transfer_create_screen.dart';
import '../../logging/app_log.dart';

class LegDetailScreen extends StatefulWidget {
  const LegDetailScreen({super.key, required this.services, required this.legKey});
  final AppServices services;
  final String legKey;

  @override
  State<LegDetailScreen> createState() => _LegDetailScreenState();
}

class _LegDetailScreenState extends State<LegDetailScreen> {
  DriverLeg? _leg;
  LegSyncState? _syncState;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A háttérszinkron a szakasz státuszát és a sync jelzést is változtatja.
    widget.services.sync.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_refresh);
    super.dispose();
  }

  /// Háttérfrissítés: nem nyúl a folyamatban lévő művelet busy jelzéséhez.
  void _refresh() => _load(quiet: true);

  Future<void> _load({bool quiet = false}) async {
    final leg = await widget.services.local.cachedLeg(widget.legKey);
    final syncState = (await widget.services.local.legSyncStates())[widget.legKey];
    if (!mounted) return;
    setState(() {
      _leg = leg;
      _syncState = syncState;
      if (!quiet) _busy = false;
    });
  }

  /// Egyetlen gomb minden állapothoz: megnyitja a szükséges jegyzőkönyvet. A
  /// fuvar indítását/lezárását maga a jegyzőkönyv lezárása végzi, egy lokális
  /// tranzakcióban — itt a visszatérés után csak újraolvassuk az állapotot, az
  /// üzleti lépés nem függ attól, hogyan zárult be a képernyő.
  Future<void> _startTrip() => _openPhase('PICKUP', (leg) => widget.services.work.startLeg(leg));

  Future<void> _finishTrip() => _openPhase('DROPOFF', (leg) => widget.services.work.completeLeg(leg));

  Future<void> _openPhase(String phase, Future<void> Function(DriverLeg leg) transitionOnly) async {
    final leg = _leg;
    if (leg == null || _busy) return;
    log.info('work', '${phase == 'PICKUP' ? 'Fuvar indítása' : 'Fuvar lezárása'} gomb: ${leg.legKey} (${leg.status})');
    setState(() { _busy = true; _error = null; });
    try {
      final existing = await widget.services.local.inspectionForLeg(leg.legKey, phase);
      if (existing != null && existing.status != 'DRAFT') {
        // A jegyzőkönyv már lezárt, csak az állapotváltás maradt el (korábbi
        // appverzió): nem nyitjuk újra, csak a hiányzó lépést végezzük el.
        await transitionOnly(leg);
      } else if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => InspectionSetupScreen(services: widget.services, leg: leg, phase: phase),
        ));
      }
    } catch (e, stack) {
      log.error('work', 'Fuvar ${phase == 'PICKUP' ? 'indítása' : 'lezárása'} nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
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
                const SizedBox(height: 12),
                SyncBadge(_syncState, detailed: true),
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
