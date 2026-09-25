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
  /// Körfuvar odaútjánál a visszaút, ha a telefonon van (ennél a sofőrnél).
  DriverLeg? _returnLeg;
  LegSyncState? _syncState;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: fuvar adatlap ${widget.legKey}');
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
    final returnLeg = leg == null ? null : await widget.services.local.returnLegFor(leg);
    if (!mounted) return;
    setState(() {
      _leg = leg;
      _returnLeg = returnLeg;
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
        // Körfuvar: a leadás után a sofőr nem mehet el — megvárja az autót, és visszaviszi.
        if (phase == 'DROPOFF' && leg.isOutbound) {
          final closed = await widget.services.local.inspectionForLeg(leg.legKey, 'DROPOFF');
          if (closed != null && closed.status != 'DRAFT' && mounted) await _showWaitDialog(leg);
        }
      }
    } catch (e, stack) {
      log.error('work', 'Fuvar ${phase == 'PICKUP' ? 'indítása' : 'lezárása'} nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
      await _load();
    }
  }

  static String _time(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.month)}.${two(l.day)}. ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _showWaitDialog(DriverLeg outbound) async {
    final back = await widget.services.local.returnLegFor(outbound);
    log.info('work', 'Körfuvar: várakozás a leadás után (${outbound.legKey}), visszaút: ${back?.legKey ?? 'nincs a sofőrnél'}');
    if (!mounted) return;
    final open = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.hourglass_top, color: AppColors.signalAmber, size: 36),
        title: const Text('Körfuvar – várakozás'),
        content: Text(back == null
            ? 'Ne menj el! Várd meg az autót itt: ${outbound.toAddress}.\n\nA visszaút még nincs kiosztva neked – szólj az irodának.'
            : 'Ne menj el! Várd meg, amíg az autó elkészül itt: ${outbound.toAddress}.\n\n'
                'Utána vidd vissza ide: ${back.toAddress}'
                '${back.plannedStart == null ? '' : '\nTervezett visszaindulás: ${_time(back.plannedStart)}'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Rendben')),
          if (back != null)
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Visszaút megnyitása')),
        ],
      ),
    );
    if (open == true && back != null && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LegDetailScreen(services: widget.services, legKey: back.legKey),
      ));
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
                if (leg.status == 'REVOKED') ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: AppColors.tintRed,
                    child: const Text(
                      'Ezt a fuvart közben lemondták, visszavették vagy másnak adták, ezért már nem a tiéd. '
                      'A telefonon lévő, még fel nem töltött adatai megmaradnak. Szólj az irodának.',
                      style: TextStyle(color: AppColors.signalRed, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _InfoCard(leg: leg),
                if ((leg.isOutbound || leg.isReturn) && !const {'COMPLETED', 'CANCELLED', 'REVOKED'}.contains(leg.status)) ...[
                  const SizedBox(height: 12),
                  _RoundTripNotice(leg: leg, returnLeg: _returnLeg, time: _time),
                ],
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

/// Körfuvar jelzése az adatlapon: odaútnál, hogy a leadás után meg kell várni az
/// autót és vissza kell vinni; visszaútnál, hogy honnan és hová.
class _RoundTripNotice extends StatelessWidget {
  const _RoundTripNotice({required this.leg, required this.returnLeg, required this.time});
  final DriverLeg leg;
  final DriverLeg? returnLeg;
  final String Function(DateTime?) time;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String text;
    if (leg.isOutbound) {
      title = 'Körfuvar · odaút';
      text = returnLeg == null
          ? 'A leadás után ne menj el: várd meg az autót itt: ${leg.toAddress}. '
              'A visszaút még nincs kiosztva neked – szólj az irodának.'
          : 'A leadás után ne menj el: várd meg, amíg az autó elkészül itt: ${leg.toAddress}, '
              'majd vidd vissza ide: ${returnLeg!.toAddress}'
              '${returnLeg!.plannedStart == null ? '' : ' (tervezett visszaindulás: ${time(returnLeg!.plannedStart)})'}.';
    } else {
      title = 'Körfuvar · visszaút';
      text = 'Az autót innen viszed vissza: ${leg.fromAddress} → ${leg.toAddress}.';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.tintAmber,
        border: Border.all(color: AppColors.signalAmber),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.sync_alt, color: AppColors.signalAmber),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: AppText.body, color: AppColors.ink900)),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink900)),
        ])),
      ]),
    );
  }
}
