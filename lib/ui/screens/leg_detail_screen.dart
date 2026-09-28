import 'package:flutter/material.dart';

import '../../local/local_repository.dart';
import '../../logging/app_log.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../leg_flow.dart';
import '../theme.dart';
import '../widgets/sync_badge.dart';
import 'transfer_create_screen.dart';

/// Egy fuvar: fent hová és kihez, alul egyetlen nagy gomb a teendővel (átvétel /
/// leadás). A ritka műveletek (autó adatai, jegyzőkönyvek, átadás, leadom) a jobb
/// felső menüben vannak.
class LegDetailScreen extends StatefulWidget {
  const LegDetailScreen({super.key, required this.services, required this.legKey});
  final AppServices services;
  final String legKey;

  @override
  State<LegDetailScreen> createState() => _LegDetailScreenState();
}

class _LegDetailScreenState extends State<LegDetailScreen> {
  DriverLeg? _leg;
  DriverLeg? _returnLeg;
  LegSyncState? _syncState;
  bool _busy = true;
  String? _error;
  bool _pickupExists = false;
  bool _dropoffExists = false;
  bool _releasable = false;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: fuvar adatlap ${widget.legKey}');
    widget.services.sync.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => _load(quiet: true);

  Future<void> _load({bool quiet = false}) async {
    // A telefonon felvett új fuvar a szinkron után a szerver azonosítóját kapja.
    final legKey = LocalRepository.currentLegKey(widget.legKey);
    final leg = await widget.services.local.cachedLeg(legKey);
    final syncState = (await widget.services.local.legSyncStates())[legKey];
    final returnLeg = leg == null ? null : await widget.services.local.returnLegFor(leg);
    final pickup = await widget.services.local.inspectionForLeg(legKey, 'PICKUP');
    final dropoff = await widget.services.local.inspectionForLeg(legKey, 'DROPOFF');
    final releasable = leg != null && await canRelease(widget.services, leg);
    if (!mounted) return;
    setState(() {
      _leg = leg;
      _returnLeg = returnLeg;
      _syncState = syncState;
      _pickupExists = pickup != null;
      _dropoffExists = dropoff != null;
      _releasable = releasable;
      if (!quiet) _busy = false;
    });
  }

  /// Az egyetlen fő gomb: megnyitja a szükséges jegyzőkönyvet; az út indítását /
  /// lezárását a jegyzőkönyv lezárása végzi (egy lokális tranzakcióban).
  Future<void> _act() async {
    final leg = _leg;
    final phase = leg == null ? null : nextPhase(leg);
    if (leg == null || phase == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await runPhase(context, widget.services, leg, phase);
    } catch (e, stack) {
      log.error('work', 'Fuvar ${phase == 'PICKUP' ? 'indítása' : 'lezárása'} nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
      await _load();
    }
  }

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

  Future<void> _menu(String action) async {
    final leg = _leg;
    if (leg == null) return;
    switch (action) {
      case 'vehicle':
        await _editVehicle(leg);
      case 'time':
        await rescheduleDialog(context, widget.services, leg);
        await _load(quiet: true);
      case 'pickup':
        await _view('PICKUP');
      case 'dropoff':
        await _view('DROPOFF');
      case 'transfer':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransferCreateScreen(services: widget.services, leg: leg)));
      case 'release':
        final released = await releaseLeg(context, widget.services, leg);
        if (released && mounted) Navigator.of(context).pop();
    }
  }

  /// Az autó minden adata javítható: rendszám, típus, szín, a használó neve,
  /// telefonja, e-mail-címe, és a további cím a jegyzőkönyvekhez. A telefonon
  /// azonnal érvényes, a szinkron viszi fel; az iroda naplózva látja.
  Future<void> _editVehicle(DriverLeg leg) async {
    final fields = <String, TextEditingController>{
      'plate': TextEditingController(text: leg.registrationNumber),
      'make': TextEditingController(text: leg.make ?? ''),
      'model': TextEditingController(text: leg.model ?? ''),
      'color': TextEditingController(text: leg.color ?? ''),
      'userName': TextEditingController(text: leg.vehicleUserName ?? ''),
      'userPhone': TextEditingController(text: leg.vehicleUserPhone ?? ''),
      'userEmail': TextEditingController(text: leg.vehicleUserEmail ?? ''),
      'extraEmail': TextEditingController(text: leg.vehicleExtraEmail ?? ''),
    };
    final form = GlobalKey<FormState>();
    String? email(String? v) =>
        v == null || v.trim().isEmpty || RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim()) ? null : 'Érvénytelen e-mail-cím';
    Widget field(String key, String label, {TextInputType? keyboard, String? Function(String?)? validator, bool upper = false}) => TextFormField(
          controller: fields[key],
          decoration: InputDecoration(labelText: label),
          keyboardType: keyboard,
          textCapitalization: upper ? TextCapitalization.characters : TextCapitalization.sentences,
          validator: validator,
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Autó adatai'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              field('plate', 'Rendszám', upper: true, validator: (v) => v == null || v.trim().isEmpty ? 'Kötelező' : null),
              field('make', 'Gyártó'),
              field('model', 'Modell'),
              field('color', 'Szín'),
              field('userName', 'Használó neve'),
              field('userPhone', 'Használó telefonja', keyboard: TextInputType.phone),
              field('userEmail', 'Használó e-mail', keyboard: TextInputType.emailAddress, validator: email),
              field('extraEmail', 'További e-mail a jegyzőkönyvekhez', keyboard: TextInputType.emailAddress, validator: email),
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
      String t(String key) => fields[key]!.text.trim();
      try {
        final changed = await widget.services.work.updateLegVehicle(leg,
            registrationNumber: t('plate').toUpperCase(),
            make: t('make'), model: t('model'), color: t('color'),
            userName: t('userName'), userPhone: t('userPhone'),
            userEmail: t('userEmail'), extraEmail: t('extraEmail'));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed ? 'Mentve.' : 'Nem volt változás.')));
        }
        await _load(quiet: true);
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    }
    for (final c in fields.values) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final leg = _leg;
    final phase = leg == null ? null : nextPhase(leg);
    return Scaffold(
      appBar: AppBar(
        title: Text(leg?.registrationNumber ?? 'Fuvar'),
        actions: [
          if (leg != null)
            PopupMenuButton<String>(
              onSelected: _menu,
              itemBuilder: (_) => [
                if (const {'ASSIGNED', 'IN_PROGRESS', 'COMPLETED_PENDING_SYNC'}.contains(leg.status))
                  const PopupMenuItem(value: 'vehicle', child: ListTile(leading: Icon(Icons.edit), title: Text('Autó adatai'))),
                if (leg.status == 'ASSIGNED')
                  const PopupMenuItem(value: 'time', child: ListTile(leading: Icon(Icons.schedule), title: Text('Felvétel időpontja'))),
                if (_pickupExists) const PopupMenuItem(value: 'pickup', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Átvételi jegyzőkönyv'))),
                if (_dropoffExists) const PopupMenuItem(value: 'dropoff', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Leadási jegyzőkönyv'))),
                if (leg.status == 'ASSIGNED' && !LocalRepository.isLocalLeg(leg.legKey))
                  const PopupMenuItem(value: 'transfer', child: ListTile(leading: Icon(Icons.swap_horiz), title: Text('Átadás másik sofőrnek'))),
                if (_releasable)
                  const PopupMenuItem(value: 'release', child: ListTile(leading: Icon(Icons.logout, color: AppColors.signalRed), title: Text('Leadom ezt a fuvart'))),
              ],
            ),
        ],
      ),
      body: leg == null
          ? const Center(child: Text('A fuvar nincs ezen a telefonon.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
                if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
                if (leg.status == 'REVOKED')
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    color: AppColors.tintRed,
                    child: const Text('Ez a fuvar már nem a tiéd (lemondták vagy másnak adták). Szólj az irodának.',
                        style: TextStyle(color: AppColors.signalRed, fontWeight: FontWeight.w600)),
                  ),
                _InfoCard(leg: leg),
                if (leg.isOutbound || leg.isReturn) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    color: AppColors.tintAmber,
                    border: AppColors.signalAmber,
                    icon: Icons.sync_alt,
                    text: leg.isOutbound
                        ? 'Körfuvar: leadás után várd meg az autót${_returnLeg == null ? '' : ', és vidd vissza ide: ${_returnLeg!.toPlace}'}.'
                        : 'Körfuvar visszaút: ${leg.fromPlace} → ${leg.toPlace}.',
                  ),
                ],
                if ((leg.status == 'IN_PROGRESS' || leg.status == 'ASSIGNED') && leg.locationSharing) ...[
                  const SizedBox(height: 12),
                  AnimatedBuilder(
                    animation: widget.services.location,
                    builder: (context, _) => FutureBuilder<bool>(
                      future: widget.services.location.permitted(),
                      builder: (context, permitted) => (permitted.data ?? false)
                          ? const SizedBox.shrink()
                          : _Banner(
                              color: AppColors.tintAmber,
                              border: AppColors.signalAmber,
                              icon: Icons.location_disabled,
                              text: 'A helyzetmegosztás nincs engedélyezve.',
                              action: TextButton(
                                onPressed: () async {
                                  await widget.services.location.askIfNeeded(context, leg);
                                  if (mounted) setState(() {});
                                },
                                child: const Text('Engedélyezés'),
                              ),
                            ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SyncBadge(_syncState, detailed: true),
              ],
            ),
      bottomNavigationBar: leg == null || phase == null || leg.status == 'REVOKED'
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 60,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                    onPressed: _busy ? null : _act,
                    icon: Icon(phase == 'PICKUP' ? Icons.key : Icons.flag, size: 26),
                    label: Text(phase == 'PICKUP' ? 'Autó átvétele' : 'Autó leadása'),
                  ),
                ),
              ),
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.border, required this.icon, required this.text, this.action});
  final Color color;
  final Color border;
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, border: Border.all(color: border), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(icon, color: border),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink900))),
          if (action != null) action!,
        ]),
      );
}

/// Hová és kihez: a két cím a kapcsolattartóval, az autó és a használója.
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.leg});
  final DriverLeg leg;

  @override
  Widget build(BuildContext context) {
    final car = [leg.make, leg.model, leg.color].whereType<String>().where((v) => v.trim().isNotEmpty).join(' · ');
    final user = [leg.vehicleUserName, leg.vehicleUserPhone].whereType<String>().where((v) => v.trim().isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(leg.plannedStart == null ? 'Időpont nélkül' : shortTime(leg.plannedStart), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            StatusPlate(leg.status, labelOverride: _status(leg.status)),
          ]),
          if (car.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(car, style: const TextStyle(color: AppColors.ink600))),
          const Divider(height: 24),
          _Stop(label: 'Honnan', place: leg.fromPlace, contact: [leg.fromContactName, leg.fromContactPhone].whereType<String>().join(' · '), note: leg.fromStopNotes),
          const SizedBox(height: 12),
          _Stop(label: 'Hova', place: leg.toPlace, contact: [leg.toContactName, leg.toContactPhone].whereType<String>().join(' · '), note: leg.toStopNotes),
          if (user.isNotEmpty || leg.vehicleNotes != null) const Divider(height: 24),
          if (user.isNotEmpty) Text('Használó: $user'),
          if (leg.vehicleNotes != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(leg.vehicleNotes!, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }

  static String _status(String value) => switch (value) {
        'ASSIGNED' => 'Tiéd',
        'IN_PROGRESS' => 'Úton',
        'COMPLETED_PENDING_SYNC' => 'Kész, feltöltésre vár',
        'COMPLETED' => 'Kész',
        'CANCELLED' => 'Lemondva',
        'REVOKED' => 'Már nem a tiéd',
        _ => value,
      };
}

class _Stop extends StatelessWidget {
  const _Stop({required this.label, required this.place, required this.contact, this.note});
  final String label;
  final String place;
  final String contact;
  final String? note;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(), style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink600)),
        Text(place, style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600)),
        if (contact.isNotEmpty) Text(contact),
        if (note != null && note!.trim().isNotEmpty) Text(note!, style: const TextStyle(color: AppColors.ink600)),
      ]);
}
