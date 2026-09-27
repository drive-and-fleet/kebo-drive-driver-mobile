import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../local/local_repository.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/sync_badge.dart';
import '../leg_flow.dart';
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

  /// A következő jegyzőkönyv az előzőből induljon (alapból igen; kikapcsolható).
  bool _copy = true;
  bool _copyAvailable = false;
  bool _pickupExists = false;
  bool _dropoffExists = false;
  bool _releasable = false;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: fuvar adatlap ${widget.legKey}');
    // A háttérszinkron az út státuszát és a sync jelzést is változtatja.
    widget.services.sync.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_refresh);
    super.dispose();
  }

  /// A sofőr javítja a rendszámot, a használó e-mail-címét, vagy megad egy további
  /// címet, amelyre a jegyzőkönyvek is kimennek. A telefonon azonnal érvényes, a
  /// szinkron viszi fel; a szerver naplózza, és az iroda is látja.
  Future<void> _editVehicle(DriverLeg leg) async {
    final plate = TextEditingController(text: leg.registrationNumber);
    final userEmail = TextEditingController(text: leg.vehicleUserEmail ?? '');
    final extraEmail = TextEditingController(text: leg.vehicleExtraEmail ?? '');
    final form = GlobalKey<FormState>();
    String? email(String? v) =>
        v == null || v.trim().isEmpty || RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim()) ? null : 'Érvénytelen e-mail-cím';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Autó adatai'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: plate,
                decoration: const InputDecoration(labelText: 'Rendszám'),
                textCapitalization: TextCapitalization.characters,
                validator: (v) => v == null || v.trim().isEmpty ? 'Kötelező' : null,
              ),
              TextFormField(controller: userEmail, decoration: const InputDecoration(labelText: 'Használó e-mail'), keyboardType: TextInputType.emailAddress, validator: email),
              TextFormField(controller: extraEmail, decoration: const InputDecoration(labelText: 'További e-mail a jegyzőkönyvekhez'), keyboardType: TextInputType.emailAddress, validator: email),
              const SizedBox(height: 8),
              const Text('A változást az iroda is látja (naplózva). A jegyzőkönyvek a megadott címekre mennek.', style: TextStyle(fontSize: 13)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() ?? false) Navigator.pop(dialogContext, true);
            },
            child: const Text('Mentés'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        final changed = await widget.services.work.updateLegVehicle(leg,
            registrationNumber: plate.text.trim().toUpperCase(), userEmail: userEmail.text.trim(), extraEmail: extraEmail.text.trim());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(changed ? 'Mentve a telefonon; a szinkron felviszi.' : 'Nem volt változás.'),
          ));
        }
        await _load(quiet: true);
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    }
    plate.dispose();
    userEmail.dispose();
    extraEmail.dispose();
  }

  /// Háttérfrissítés: nem nyúl a folyamatban lévő művelet busy jelzéséhez.
  void _refresh() => _load(quiet: true);

  Future<void> _load({bool quiet = false}) async {
    // A telefonon felvett új fuvar a szinkron után a szerver azonosítóját kapja.
    final legKey = LocalRepository.currentLegKey(widget.legKey);
    final leg = await widget.services.local.cachedLeg(legKey);
    final syncState = (await widget.services.local.legSyncStates())[legKey];
    final returnLeg = leg == null ? null : await widget.services.local.returnLegFor(leg);
    final phase = leg == null ? null : nextPhase(leg);
    final copyAvailable = leg != null && phase != null && await canCopyInto(widget.services, leg, phase);
    final pickup = await widget.services.local.inspectionForLeg(legKey, 'PICKUP');
    final dropoff = await widget.services.local.inspectionForLeg(legKey, 'DROPOFF');
    final releasable = leg != null && await canRelease(widget.services, leg);
    if (!mounted) return;
    setState(() {
      _leg = leg;
      _returnLeg = returnLeg;
      _syncState = syncState;
      _copyAvailable = copyAvailable;
      _pickupExists = pickup != null;
      _dropoffExists = dropoff != null;
      _releasable = releasable;
      if (!quiet) _busy = false;
    });
  }

  /// Egyetlen gomb minden állapothoz: megnyitja a szükséges jegyzőkönyvet. A
  /// fuvar indítását/lezárását maga a jegyzőkönyv lezárása végzi, egy lokális
  /// tranzakcióban — itt a visszatérés után csak újraolvassuk az állapotot.
  Future<void> _runPhase(String phase) async {
    final leg = _leg;
    if (leg == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await runPhase(context, widget.services, leg, phase, copy: _copy);
    } catch (e, stack) {
      log.error('work', 'Fuvar ${phase == 'PICKUP' ? 'indítása' : 'lezárása'} nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
      await _load();
    }
  }

  /// A lezárt (vagy megkezdett) jegyzőkönyv bármikor megnézhető.
  Future<void> _view(String phase) async {
    final leg = _leg;
    if (leg == null) return;
    try {
      await openInspection(context, widget.services, leg, phase);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      await _load(quiet: true);
    }
  }

  Future<void> _release() async {
    final leg = _leg;
    if (leg == null || _busy) return;
    final released = await releaseLeg(context, widget.services, leg);
    if (released && mounted) Navigator.of(context).pop();
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
                if ((leg.status == 'IN_PROGRESS' || leg.status == 'ASSIGNED') && leg.locationSharing) ...[
                  const SizedBox(height: 12),
                  AnimatedBuilder(
                    animation: widget.services.location,
                    builder: (context, _) => FutureBuilder<bool>(
                      future: widget.services.location.permitted(),
                      builder: (context, permitted) => _SharingNotice(
                        started: leg.status == 'IN_PROGRESS',
                        permitted: permitted.data ?? false,
                        sharing: widget.services.location.sharingLegKey == leg.legKey,
                        live: widget.services.location.isLive,
                        onEnable: () async {
                          await widget.services.location.askIfNeeded(context, leg);
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                  ),
                ],
                // A „várd meg az autót” jelzés csak annak szól, akinél a visszaút is van.
                if ((leg.isReturn || (leg.isOutbound && _returnLeg != null)) && !const {'COMPLETED', 'CANCELLED', 'REVOKED'}.contains(leg.status)) ...[
                  const SizedBox(height: 12),
                  _RoundTripNotice(leg: leg, returnLeg: _returnLeg, time: shortTime),
                ],
                const SizedBox(height: 12),
                SyncBadge(_syncState, detailed: true),
                const SizedBox(height: 16),
                if (_copyAvailable)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _copy,
                    onChanged: _busy ? null : (v) => setState(() => _copy = v),
                    title: const Text('Másolás az előző jegyzőkönyvből'),
                    subtitle: const Text('Az adatok és a sérülések átkerülnek, a kézi aláírás nem. Kikapcsolva üres jegyzőkönyv indul.'),
                  ),
                if (leg.status == 'ASSIGNED')
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _runPhase('PICKUP'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Fuvar indítása (átvételi jegyzőkönyv)'),
                  ),
                if (leg.status == 'IN_PROGRESS')
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _runPhase('DROPOFF'),
                    icon: const Icon(Icons.done_all),
                    label: const Text('Fuvar lezárása (leadási jegyzőkönyv)'),
                  ),
                if (_pickupExists || _dropoffExists) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (_pickupExists)
                      OutlinedButton.icon(
                        onPressed: () => _view('PICKUP'),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Átvételi jegyzőkönyv'),
                      ),
                    if (_dropoffExists)
                      OutlinedButton.icon(
                        onPressed: () => _view('DROPOFF'),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Leadási jegyzőkönyv'),
                      ),
                  ]),
                ],
                // A még fel nem küldött új fuvar a szerveren még nem létezik: nem adható át.
                if (leg.status == 'ASSIGNED' && !LocalRepository.isLocalLeg(leg.legKey)) ...[
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
                if (_releasable) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.signalRed),
                    onPressed: _busy ? null : _release,
                    icon: const Icon(Icons.logout),
                    label: const Text('Leadom ezt a fuvart'),
                  ),
                ],
                if (const {'ASSIGNED', 'IN_PROGRESS', 'COMPLETED_PENDING_SYNC'}.contains(leg.status)) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _editVehicle(leg),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Autó adatai (rendszám, e-mail)'),
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
          Text('Fuvar: ${leg.orderNo} • Út #${leg.sequenceNo}', style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
          const Divider(height: 24),
          Text('Felvétel: ${leg.fromPlace}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.body)),
          if (leg.fromContactName != null) Text('Kapcsolat: ${leg.fromContactName} ${leg.fromContactPhone ?? ''}'),
          if (leg.fromStopNotes != null) Text('Megjegyzés: ${leg.fromStopNotes}', style: const TextStyle(color: AppColors.ink600)),
          const SizedBox(height: 10),
          Text('Leadás: ${leg.toPlace}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.body)),
          if (leg.toContactName != null) Text('Kapcsolat: ${leg.toContactName} ${leg.toContactPhone ?? ''}'),
          if (leg.toStopNotes != null) Text('Megjegyzés: ${leg.toStopNotes}', style: const TextStyle(color: AppColors.ink600)),
          const Divider(height: 24),
          Text('Autó használója: ${leg.vehicleUserName ?? '—'}'),
          if (leg.vehicleUserPhone != null) Text(leg.vehicleUserPhone!),
          Text('E-mail: ${leg.vehicleUserEmail ?? '—'}'),
          Text('További e-mail a jegyzőkönyvekhez: ${leg.vehicleExtraEmail ?? '—'}'),
          if (leg.vehicleNotes != null) ...[
            const SizedBox(height: 8),
            Text('Megjegyzés: ${leg.vehicleNotes}', style: const TextStyle(fontWeight: FontWeight.w600)),
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
          ? 'A leadás után várd meg az autót itt: ${leg.toAddress}, ha a visszautat is te viszed. '
              'A visszaút nincs nálad: az odaút teljesítése után a Szabad fuvarok között felveheted, '
              'ha addig senki más nem kapja meg – kérdezd az irodát.'
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

/// Helyzetmegosztás (az iroda kérte): fuvar közben megy-e, indulás előtt pedig
/// előre engedélyezhető, hogy az átvételkor már magától induljon.
class _SharingNotice extends StatelessWidget {
  const _SharingNotice({required this.started, required this.permitted, required this.sharing, required this.live, required this.onEnable});
  final bool started;
  final bool permitted;
  final bool sharing;
  final bool live;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    if (sharing || (!started && permitted)) {
      return Container(
        padding: const EdgeInsets.all(12),
        color: AppColors.tintGreen,
        child: Row(children: [
          const Icon(Icons.my_location, color: AppColors.signalGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              !started
                  ? 'Helyzetmegosztás engedélyezve: az átvételkor magától elindul, leadáskor leáll.'
                  : live
                      ? 'Helyzet megosztva – most élőben követik az utadat.'
                      : 'Helyzet megosztva az irodával és a címzettel, akkukímélő módban. Leadáskor leáll.',
              style: const TextStyle(color: AppColors.signalGreen, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      color: AppColors.tintAmber,
      child: Row(children: [
        const Icon(Icons.location_disabled, color: AppColors.signalAmber),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
              started
                  ? 'Az iroda kéri a helyzeted megosztását erre az útra, de a telefonon nincs engedélyezve.'
                  : 'Az iroda kéri a helyzeted megosztását az út alatt. Engedélyezd már most, hogy induláskor ne kelljen vele foglalkoznod.',
              style: const TextStyle(color: AppColors.ink900, fontWeight: FontWeight.w600)),
        ),
        TextButton(onPressed: onEnable, child: const Text('Engedélyezés')),
      ]),
    );
  }
}
