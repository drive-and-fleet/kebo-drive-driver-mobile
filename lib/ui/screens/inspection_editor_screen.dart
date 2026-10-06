import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

import '../../local/local_repository.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/dynamic_field.dart';
import '../../logging/app_log.dart';
import 'done_screen.dart';
import '../leg_data_edit.dart';
import '../photo_capture.dart';

// ponytail: fix lista, DB-lookup csak ha szolgálatonként eltérő értékkészlet kell.
const _damageLocations = [
  'bal oldalon elől', 'bal első ajtón', 'bal hátsó ajtón', 'bal oldalon hátul',
  'jobb oldalon elől', 'jobb első ajtón', 'jobb hátsó ajtón', 'jobb oldalon hátul',
  'hátul', 'elől', 'tetőn',
];
const _damageTypes = ['kis karcolás', 'közepes karcolás', 'nagy karcolás', 'törés', 'horpadás'];
const _damageSeverities = ['kicsi', 'közepes', 'nagy'];

class InspectionEditorScreen extends StatefulWidget {
  const InspectionEditorScreen({super.key, required this.services, required this.leg, required this.draftId, required this.form});
  final AppServices services;
  final DriverLeg leg;
  final String draftId;
  final FormTypeConfig form;

  @override
  State<InspectionEditorScreen> createState() => _InspectionEditorScreenState();
}

class _InspectionEditorScreenState extends State<InspectionEditorScreen> {
  Map<String, Map<String, dynamic>> _values = const {};
  List<LocalDamage> _damages = const [];
  List<LocalPhoto> _photos = const [];
  List<LocalSignature> _signatures = const [];
  LocalInspectionDraft? _draft;
  bool _loading = true;
  bool _finalizing = false;
  /// Hol tart a lezárás (a teljes képernyős jelzőn látszik).
  String _step = '';

  /// Lezárt jegyzőkönyv csak megtekinthető — kivéve a javítást: az utat vivő sofőr
  /// az út lezárásáig javíthatja az adatokat és a megjegyzést (előzményként megmarad).
  bool get _readOnly => (_draft?.status != 'DRAFT' && !_correcting) || _finalizing;

  /// Fotó, sérülés és szignó csak a nyitott jegyzőkönyvben változhat (javításkor nem).
  bool get _mediaLocked => _draft?.status != 'DRAFT' || _finalizing;

  /// Javítható-e most: lezárt, és az út még folyamatban van ezen a telefonon.
  bool _correctable = false;
  bool _correcting = false;
  bool _savingCorrection = false;
  int _pendingCorrections = 0;
  /// A javítás közben átírt mezők (mentésig csak itt).
  final Map<String, ({Map<String, dynamic> value, List<String> optionIds})> _edits = {};

  /// „Általános megjegyzés”: gépelés közben, fél másodperc szünet után mentődik a telefonra.
  final _note = TextEditingController();
  bool _noteLoaded = false;
  Timer? _noteTimer;

  @override
  void dispose() {
    final pending = _noteTimer?.isActive ?? false;
    _noteTimer?.cancel();
    // Ami a gépelés után még nem mentődött (azonnal kilépett), az most megy a telefonra.
    if (pending && _draft?.status == 'DRAFT') unawaited(_saveNote());
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    try {
      await widget.services.local.saveGeneralNote(widget.draftId, _note.text);
    } catch (e, stack) {
      log.error('insp', 'A megjegyzés mentése nem sikerült (${widget.draftId})', e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('A megjegyzést nem sikerült menteni: $e')));
    }
  }

  void _noteChanged(String _) {
    if (_correcting) return; // javításkor a megjegyzés a mentéssel együtt megy
    _noteTimer?.cancel();
    _noteTimer = Timer(const Duration(milliseconds: 500), _saveNote);
  }

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: jegyzőkönyv szerkesztése ${widget.draftId} (út ${widget.leg.legKey}, form ${widget.form.id})');
    _init();
  }

  /// A kapcsolók alapértéke `false`, de eddig csak akkor keletkezett soruk, ha a
  /// sofőr hozzájuk nyúlt — így a „nem" válasz nem került fel a szerverre.
  Future<void> _init() async {
    final draft = await widget.services.local.inspection(widget.draftId);
    if (draft != null && draft.status == 'DRAFT') {
      final values = await widget.services.local.inspectionValues(widget.draftId);
      for (final field in widget.form.fields.where((f) =>
          f.dataType == 'BOOLEAN' && (f.phase == 'BOTH' || f.phase == draft.inspectionType))) {
        if (values.containsKey(field.fieldDefinitionId)) continue;
        await widget.services.local
            .saveInspectionValue(widget.draftId, field.fieldDefinitionId, {'value_boolean': false}, const []);
      }
    }
    await _reload();
  }

  Future<void> _reload() async {
    final draft = await widget.services.local.inspection(widget.draftId);
    final values = await widget.services.local.inspectionValues(widget.draftId);
    final damages = await widget.services.local.damages(widget.draftId);
    final photos = await widget.services.local.photos(widget.draftId);
    final signatures = await widget.services.local.signatures(widget.draftId);
    final leg = await widget.services.local.cachedLeg(LocalRepository.currentLegKey(widget.leg.legKey));
    final pending = await widget.services.local.pendingCorrections(widget.draftId);
    if (mounted) setState(() {
      _correctable = draft != null && draft.status != 'DRAFT' && leg?.status == 'IN_PROGRESS';
      _pendingCorrections = pending;
      _draft = draft;
      _values = values;
      _damages = damages;
      _photos = photos;
      _signatures = signatures;
      _loading = false;
      // Egyszer, betöltéskor (a másolt megjegyzés is): utána a mező a forrás.
      if (!_noteLoaded && draft != null) {
        _note.text = draft.generalNote ?? '';
        _noteLoaded = true;
      }
    });
  }

  /// Minden lokális írás hibája látható — egy csendben elnyelt hiba azt
  /// hitetné el, hogy az adat el van mentve.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e, stack) {
      log.error('insp', 'Mentés a telefonra nem sikerült (${widget.draftId})', e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nem sikerült menteni: $e')));
    }
    await _reload();
  }

  Future<void> _saveValue(FormFieldConfig field, Map<String, dynamic> value, List<String> options) async {
    if (_correcting) {
      setState(() => _edits[field.fieldDefinitionId] = (value: value, optionIds: options));
      return;
    }
    log.debug('insp', 'Mező mentve: ${field.fieldDefinitionId} (${widget.draftId})');
    await _guard(() => widget.services.local.saveInspectionValue(widget.draftId, field.fieldDefinitionId, value, options));
  }

  Future<void> _takeGeneralPhoto(String type) async {
    final image = await capturePhoto(context, widget.services,
        PendingCapture(draftId: widget.draftId, legKey: widget.leg.legKey, phase: _draft?.inspectionType ?? 'PICKUP', photoType: type), title: type);
    if (image == null) {
      log.debug('insp', 'Fotó megszakítva: $type');
      return;
    }
    final path = await widget.services.fileStore.persistImage(image.path);
    log.info('insp', 'Fotó készült: $type (${widget.draftId})');
    await _guard(() => widget.services.local.addPhoto(inspectionLocalId: widget.draftId, photoType: type, localPath: path));
  }

  /// Új sérülés: teljes képernyős űrlapon (a billentyűzet nem takar el semmit). A leírás
  /// nem kötelező – üresen a helyből és a típusból áll össze –, de valamit meg kell adni;
  /// ha nincs semmi, az űrlap kiírja, és nyitva marad.
  Future<void> _addDamage() async {
    final result = await Navigator.of(context).push<_DamageInput>(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => _DamageForm(takePhoto: _photoForNewDamage, discardPhoto: widget.services.fileStore.deleteIfExists)));
    if (result == null) return;
    log.info('insp', 'Sérülés rögzítve: ${result.location ?? '-'} / ${result.type ?? '-'} / ${result.severity ?? '-'}${result.preexisting ? ' (korábbi)' : ''} (${widget.draftId})');
    await _guard(() async {
      final damage = await widget.services.local.addDamage(
        inspectionLocalId: widget.draftId,
        description: result.description,
        location: result.location,
        damageType: result.type,
        severity: result.severity,
        isPreexisting: result.preexisting,
      );
      // Az űrlapon készült fotók ehhez a sérüléshez.
      for (final path in result.photoPaths) {
        await widget.services.local.addPhoto(inspectionLocalId: widget.draftId, photoType: 'DAMAGE', localPath: path, damageLocalId: damage.localId);
      }
      if (result.photoPaths.isNotEmpty) log.info('insp', 'Sérülésfotó készült az űrlapon: ${result.photoPaths.length} db (${widget.draftId})');
    });
  }

  /// Fotó egy még nem mentett sérüléshez (a sérülés űrlapján): a telefonra mentve, az útvonala jön vissza.
  Future<String?> _photoForNewDamage() async {
    final image = await capturePhoto(context, widget.services,
        PendingCapture(draftId: widget.draftId, legKey: widget.leg.legKey, phase: _draft?.inspectionType ?? 'PICKUP', photoType: 'DAMAGE'),
        title: 'Sérülés fotója');
    if (image == null) return null;
    return widget.services.fileStore.persistImage(image.path);
  }

  Future<void> _takeDamagePhoto(LocalDamage damage) async {
    final image = await capturePhoto(context, widget.services, PendingCapture(
        draftId: widget.draftId, legKey: widget.leg.legKey, phase: _draft?.inspectionType ?? 'PICKUP', photoType: 'DAMAGE', damageLocalId: damage.localId),
        title: 'Sérülés fotója');
    if (image == null) return;
    final path = await widget.services.fileStore.persistImage(image.path);
    log.info('insp', 'Sérülésfotó készült: ${damage.localId} (${widget.draftId})');
    await _guard(() => widget.services.local.addPhoto(
          inspectionLocalId: widget.draftId,
          photoType: 'DAMAGE',
          localPath: path,
          damageLocalId: damage.localId,
        ));
  }

  /// Átvételkor az átadó, leadáskor az átvevő szignál; szerepenként egy szignó van.
  String get _signerRole => _draft?.inspectionType == 'PICKUP' ? 'HANDOVER' : 'RECEIVER';

  Future<void> _deleteSignature(LocalSignature signature) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Szignó törlése'),
        content: Text('Törlöd ${signature.signerName} szignóját? Lezárás előtt újat kell rögzíteni.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Törlés')),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      final path = await widget.services.local.deleteSignature(signature.localId);
      await widget.services.fileStore.deleteIfExists(path);
      log.info('insp', 'Aláírás törölve (${widget.draftId})');
    });
  }

  /// Az út friss adatai (az „Adatok” módosítása után), különben a megnyitáskori.
  DriverLeg? _freshLeg;
  DriverLeg get _leg => _freshLeg ?? widget.leg;

  Future<void> _editData() async {
    if (!await editLegData(context, widget.services, _leg)) return;
    final fresh = await widget.services.local.cachedLeg(LocalRepository.currentLegKey(widget.leg.legKey));
    if (mounted && fresh != null) setState(() => _freshLeg = fresh);
  }

  /// Miért nincs aláírás (a két jelölő közül legfeljebb egy); null: kell szignó.
  Future<void> _setWaiver(String? waiver) async {
    log.info('insp', 'Aláírás elmaradásának oka: ${waiver ?? '-'} (${widget.draftId})');
    await _guard(() => widget.services.local.setSignatureWaiver(widget.draftId, waiver));
  }

  Future<void> _addSignature() async {
    // Az aláíró neve alapból üres: sokszor nem a kapcsolattartó veszi át az autót (pl. a szervizben).
    // A megálló kapcsolattartója és az autó használója egy koppintással beírható.
    final name = TextEditingController();
    final pickup = _draft?.inspectionType == 'PICKUP';
    final suggestions = <String, String>{
      if ((pickup ? _leg.fromContactName : _leg.toContactName)?.trim().isNotEmpty ?? false)
        'Kapcsolattartó': (pickup ? _leg.fromContactName : _leg.toContactName)!.trim(),
      if (_leg.vehicleUserName?.trim().isNotEmpty ?? false) 'Használó': _leg.vehicleUserName!.trim(),
    };
    final controller = SignatureController(penStrokeWidth: 3);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kézi szignó'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: pickup ? 'Átadó neve' : 'Átvevő neve')),
          if (suggestions.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 8, children: [
                for (final entry in suggestions.entries)
                  ActionChip(
                    avatar: const Icon(Icons.content_copy, size: 16),
                    label: Text('${entry.key}: ${entry.value}'),
                    onPressed: () => name.text = entry.value,
                  ),
              ]),
            ),
          const SizedBox(height: 12),
          Container(height: 220, decoration: BoxDecoration(border: Border.all(color: Colors.grey)), child: Signature(controller: controller, backgroundColor: Colors.white)),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: controller.clear, child: const Text('Törlés'))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, name.text.trim().isNotEmpty && !controller.isEmpty), child: const Text('Mentés')),
        ],
      ),
    );
    if (ok == true) {
      final bytes = await controller.toPngBytes();
      if (bytes != null) {
        final path = await widget.services.fileStore.persistBytes(bytes);
        final signerName = name.text.trim();
        await _guard(() async {
          final replaced = await widget.services.local.addSignature(
            inspectionLocalId: widget.draftId,
            signerName: signerName,
            signerRole: _signerRole,
            localPath: path,
          );
          for (final old in replaced) {
            await widget.services.fileStore.deleteIfExists(old);
          }
          log.info('insp', replaced.isEmpty ? 'Aláírás rögzítve (${widget.draftId})' : 'Aláírás lecserélve (${widget.draftId})');
        });
      }
    }
    name.dispose(); controller.dispose();
  }

  /// A mező megjelenített értéke: javítás közben az átírt, egyébként a mentett.
  Map<String, dynamic>? _shown(String fieldId) {
    final edit = _edits[fieldId];
    if (edit == null) return _values[fieldId];
    return {...edit.value, 'option_ids': edit.optionIds};
  }

  void _startCorrection() {
    log.info('insp', 'Javítás indítva: ${widget.draftId}');
    setState(() { _correcting = true; _edits.clear(); });
  }

  void _cancelCorrection() {
    setState(() {
      _correcting = false;
      _edits.clear();
      _note.text = _draft?.generalNote ?? '';
    });
  }

  Future<void> _saveCorrection() async {
    final draft = _draft;
    if (draft == null) return;
    final noteChanged = (_note.text.trim()) != (draft.generalNote ?? '').trim();
    if (_edits.isEmpty && !noteChanged) {
      _cancelCorrection();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nem volt változás.')));
      return;
    }
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Javítás mentése'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('A jegyzőkönyv a javított adatokkal újra kimegy a címzetteknek, „Javítás történt a jegyzőkönyvben” jelzéssel. Az előző értékek előzményként megmaradnak.'),
          const SizedBox(height: 12),
          TextField(controller: reason, maxLines: 2, maxLength: 500, decoration: const InputDecoration(labelText: 'Mi volt a hiba? (nem kötelező)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Javítás mentése')),
        ],
      ),
    );
    final why = reason.text;
    reason.dispose();
    if (ok != true || !mounted) return;
    setState(() => _savingCorrection = true);
    try {
      await widget.services.work.correctInspection(draft, Map.of(_edits), generalNote: noteChanged ? _note.text : null, reason: why);
      if (!mounted) return;
      setState(() { _correcting = false; _edits.clear(); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Javítás mentve a telefonon; a feltöltés a háttérben fut.')));
    } catch (e, stack) {
      log.error('insp', 'A javítás mentése nem sikerült (${widget.draftId})', e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('A javítást nem sikerült menteni: $e')));
    } finally {
      if (mounted) setState(() => _savingCorrection = false);
      await _reload();
    }
  }

  /// „Üresen kezdem”: a másolt piszkozat törlődik, és egy üres jegyzőkönyv nyílik.
  Future<void> _startEmpty() async {
    final draft = _draft;
    if (draft == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Üresen kezded?'),
        content: const Text('A korábbi jegyzőkönyvből átvett adatok, sérülések és az eddig itt rögzített fotók törlődnek.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Üresen kezdem')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _noteTimer?.cancel();
    try {
      final files = await widget.services.local.discardDraft(draft.localId);
      for (final path in files) {
        try {
          await File(path).delete();
        } catch (_) {
          // A fájl már nincs meg: nincs teendő.
        }
      }
      log.info('insp', 'Másolt piszkozat eldobva, üres jegyzőkönyv: ${draft.inspectionType} ${draft.localId}');
      final fresh = await widget.services.work.openInspection(leg: widget.leg, phase: draft.inspectionType, formTypeId: widget.form.id);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => InspectionEditorScreen(services: widget.services, leg: widget.leg, draftId: fresh.localId, form: widget.form),
      ));
    } catch (e, stack) {
      log.error('insp', 'Az üres jegyzőkönyv nem nyitható: ${draft.localId}', e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nem sikerült: $e')));
    }
  }

  /// Lezárás: előbb a kötelező adatok ellenőrzése – ha valami hiányzik, azonnal
  /// kiírjuk, és nem indul el a lezárás –, csak utána a megerősítő kérdés.
  Future<void> _confirmFinalize() async {
    final draft = _draft;
    if (draft == null) return;
    final pickup = draft.inspectionType == 'PICKUP';
    // A még időzített megjegyzés-mentés előbb lefut, hogy az ellenőrzés a friss adatot lássa.
    if (_noteTimer?.isActive ?? false) {
      _noteTimer!.cancel();
      await _saveNote();
    }
    final problems = await widget.services.work.closeProblems(draft, widget.form);
    if (!mounted) return;
    if (problems.isNotEmpty) {
      log.info('insp', 'Lezárás előtti ellenőrzés: hiányzik ${problems.length} dolog (${draft.localId})');
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Még nem zárható le'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Pótold ezeket, utána zárd le újra:'),
              const SizedBox(height: 8),
              for (final problem in problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('•  ', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.signalRed)),
                    Expanded(child: Text(problem)),
                  ]),
                ),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Rendben'))],
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(pickup ? 'Átveszed az autót?' : 'Leadod az autót?'),
        content: Text(pickup
            ? 'A jegyzőkönyv lezárul, és a fuvar elindul.'
            : 'A jegyzőkönyv lezárul, és a fuvar befejeződik.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(pickup ? 'Átvettem' : 'Leadtam')),
        ],
      ),
    );
    if (ok == true) await _finalize();
  }

  Future<void> _finalize() async {
    final draft = _draft;
    if (draft == null) return;
    // A még időzített megjegyzés-mentés előbb lefut: a lezárt jegyzőkönyv már nem módosítható.
    if (_noteTimer?.isActive ?? false) {
      _noteTimer!.cancel();
      await _saveNote();
    }
    setState(() { _finalizing = true; _step = 'Lezárás…'; });
    log.info('insp', 'Lezárás kérve: ${draft.inspectionType} ${draft.localId}');
    try {
      final legStatus = await widget.services.work.finalizeInspection(draft, widget.form,
          onStep: (step) { if (mounted) setState(() => _step = step); });
      if (!mounted) return;
      // Leadás után a „Kész” képernyő: nem ugrik magától a következő fuvarra.
      if (legStatus == 'COMPLETED_PENDING_SYNC' || draft.inspectionType == 'DROPOFF') {
        final leg = await widget.services.local.cachedLeg(LocalRepository.currentLegKey(widget.leg.legKey)) ?? widget.leg;
        if (!mounted) return;
        await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DoneScreen(services: widget.services, leg: leg)));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Autó átvéve, a fuvar elindult.')));
      // Elindult a fuvar: ha az iroda kéri, most kérjük a helyengedélyt (előtte elmagyarázzuk).
      if (legStatus == 'IN_PROGRESS' && draft.inspectionType == 'PICKUP') {
        await widget.services.location.askIfNeeded(context, widget.leg);
        if (!mounted) return;
      }
      // Sikeres lezárás után a képernyő zárva marad, amíg el nem tűnik.
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() { _finalizing = false; _step = ''; });
      if (mounted) await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(title: const Text('A jegyzőkönyv még nem zárható le'), content: Text('$e'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))]),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _draft?.inspectionType ?? '';
    final fields = widget.form.fields.where((f) => f.phase == 'BOTH' || f.phase == phase).toList();
    final requirements = widget.form.photoRequirements.where((p) => p.phase == 'BOTH' || p.phase == phase).toList();
    final open = _draft?.status == 'DRAFT';
    final copied = open && (_draft?.copyFromServerId != null || _draft?.copyFromLocalId != null);
    final scaffold = Scaffold(
      appBar: AppBar(title: Text(phase == 'PICKUP' ? 'Átvételi jegyzőkönyv' : 'Leadási jegyzőkönyv'), actions: [
        // Az autó / átvevő adatainak javítása a jegyzőkönyvből is (megerősítés után).
        if (open)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.signalYellow, foregroundColor: AppColors.ink900, visualDensity: VisualDensity.compact),
              onPressed: _editData,
              icon: const Icon(Icons.edit_note),
              label: const Text('Adatok'),
            ),
          ),
      ]),
      floatingActionButton: open && !_finalizing
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.signalGreen,
              foregroundColor: Colors.white,
              onPressed: _confirmFinalize,
              icon: const Icon(Icons.check),
              label: Text(phase == 'PICKUP' ? 'Átvettem – lezárás' : 'Leadtam – lezárás'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              // Alul hely a lebegő gombnak, hogy az utolsó mezőt ne takarja.
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Card(child: ListTile(leading: const Icon(Icons.directions_car), title: Text(widget.leg.registrationNumber), subtitle: Text('${widget.leg.make ?? ''} ${widget.leg.model ?? ''}\n${widget.form.name}'))),
                if (_draft != null && _draft!.status != 'DRAFT' && !_correcting)
                  Card(child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Lezárt jegyzőkönyv'),
                    subtitle: Text([
                      _correctable ? 'Az út lezárásáig javíthatod: az adatokat és a megjegyzést.' : 'Csak megtekinthető; az út lezárása után nem javítható.',
                      if (_pendingCorrections > 0) 'Javítás feltöltésre vár ($_pendingCorrections).',
                    ].join('\n')),
                    trailing: _correctable ? OutlinedButton(onPressed: _startCorrection, child: const Text('Javítás')) : null,
                  )),
                if (_correcting)
                  const Card(
                    color: Color(0xFFF6E3C2),
                    child: ListTile(
                      leading: Icon(Icons.edit_note, color: Color(0xFF8A5300)),
                      title: Text('Javítás'),
                      subtitle: Text('Írd át a hibás adatokat, majd mentsd. Fotó, sérülés és szignó itt nem változik.'),
                    ),
                  ),
                if (copied)
                  Card(child: ListTile(
                    leading: const Icon(Icons.copy_all),
                    title: const Text('Az előző jegyzőkönyvből kitöltve'),
                    trailing: TextButton(onPressed: _finalizing ? null : _startEmpty, child: const Text('Üresen kezdem')),
                  )),
                const SizedBox(height: 12),
                Text('Adatok', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                for (final field in fields)
                  DynamicField(
                    // Új kulcs a javítás elején / végén: a mező újra az aktuális értékből épül fel.
                    key: ValueKey('${field.fieldDefinitionId}-$_correcting'),
                    field: field, value: _shown(field.fieldDefinitionId), enabled: !_readOnly, onChanged: (value, options) => _saveValue(field, value, options)),
                const SizedBox(height: 16),
                Text('Fotók', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                for (final requirement in requirements)
                  Card(child: ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: Text('${requirement.photoType}${requirement.required ? ' *' : ''}'),
                    subtitle: Text('Minimum: ${requirement.minCount} • Rögzítve: ${_photos.where((p) => p.damageLocalId == null && p.photoType == requirement.photoType).length}'),
                    trailing: IconButton(onPressed: _mediaLocked ? null : () => _takeGeneralPhoto(requirement.photoType), icon: const Icon(Icons.add_a_photo)),
                  )),
                if (_photos.where((p) => p.damageLocalId == null).isNotEmpty)
                  _PhotoStrip(photos: _photos.where((p) => p.damageLocalId == null).toList()),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Sérülések', style: Theme.of(context).textTheme.titleLarge),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.signalRed, foregroundColor: Colors.white),
                    onPressed: _mediaLocked ? null : _addDamage,
                    icon: const Icon(Icons.car_crash),
                    label: const Text('+ Sérülés'),
                  ),
                ]),
                const SizedBox(height: 6),
                if (_damages.isEmpty) const Text('Nincs rögzített sérülés.'),
                for (final damage in _damages)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [Expanded(child: Text(damage.description, style: const TextStyle(fontWeight: FontWeight.w600))), if (damage.baseline) const Chip(label: Text('Másolt'))]),
                        if (damage.location != null) Text('Hely: ${damage.location}'),
                        if (damage.damageType != null) Text('Típus: ${damage.damageType}'),
                        if (damage.severity != null) Text('Súlyosság: ${damage.severity}'),
                        const SizedBox(height: 8),
                        _PhotoStrip(photos: _photos.where((p) => p.damageLocalId == damage.localId).toList()),
                        // A másolt sérülést és fotóit a szerver másolja; a mobil nem
                        // ismeri a másolat azonosítóját, így új fotó nem köthető hozzá.
                        if (!damage.baseline)
                          Align(alignment: Alignment.centerRight, child: FilledButton.tonalIcon(onPressed: _mediaLocked ? null : () => _takeDamagePhoto(damage), icon: const Icon(Icons.add_a_photo), label: const Text('Sérülés fotó'))),
                      ]),
                    ),
                  ),
                const SizedBox(height: 16),
                Text('Általános megjegyzés', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                TextField(
                  controller: _note,
                  readOnly: _readOnly,
                  minLines: 2,
                  maxLines: 6,
                  onChanged: _noteChanged,
                  decoration: const InputDecoration(hintText: 'Bármi, ami a jegyzőkönyvhöz tartozik (a következő jegyzőkönyvbe is átmásolható)'),
                ),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Kézi szignó', style: Theme.of(context).textTheme.titleLarge),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.signalYellow, foregroundColor: AppColors.ink900),
                    onPressed: _mediaLocked ? null : _addSignature,
                    icon: const Icon(Icons.draw),
                    label: Text(_signatures.isEmpty ? 'Szignó' : 'Szignó cseréje'),
                  ),
                ]),
                // Ha nem lehet aláíratni, az ok megadásával a szignó nem kötelező; a PDF-en a szignó helyén ez áll.
                if (_signatures.isEmpty) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A használó nincs jelen'),
                    value: _draft?.signatureWaiver == 'USER_ABSENT',
                    onChanged: _mediaLocked ? null : (v) => _setWaiver(v == true ? 'USER_ABSENT' : null),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Átvételi ponton aláírás megadására nincs lehetőség'),
                    value: _draft?.signatureWaiver == 'NOT_POSSIBLE',
                    onChanged: _mediaLocked ? null : (v) => _setWaiver(v == true ? 'NOT_POSSIBLE' : null),
                  ),
                  if (_draft?.signatureWaiver != null)
                    const Text('A szignó nem kötelező: a jegyzőkönyvön (PDF) az aláírás helyén ez az ok szerepel.',
                        style: TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
                ],
                for (final signature in _signatures)
                  ListTile(
                    leading: const Icon(Icons.draw),
                    title: Text(signature.signerName),
                    subtitle: Text(signature.signedAt.toLocal().toString().substring(0, 16)),
                    trailing: _mediaLocked
                        ? null
                        : IconButton(
                            tooltip: 'Szignó törlése',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteSignature(signature),
                          ),
                  ),
                const SizedBox(height: 24),
                if (_correcting) ...[
                  Row(children: [
                    Expanded(child: OutlinedButton(onPressed: _savingCorrection ? null : _cancelCorrection, child: const Text('Mégse'))),
                    const SizedBox(width: 10),
                    Expanded(child: FilledButton.icon(
                      onPressed: _savingCorrection ? null : _saveCorrection,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(_edits.isEmpty ? 'Javítás mentése' : 'Javítás mentése (${_edits.length})'),
                    )),
                  ]),
                ],
              ],
            ),
    );
    if (!_finalizing) return scaffold;
    // Lezárás közben: teljes képernyős jelző a lépéssel, hogy látszódjon, hogy halad.
    return Stack(children: [
      scaffold,
      const ModalBarrier(dismissible: false, color: Color(0x88000000)),
      Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_step, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photos});
  final List<LocalPhoto> photos;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final photo = photos[i];
          if (photo.localPath != null && File(photo.localPath!).existsSync()) {
            return ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(photo.localPath!), width: 84, height: 84, fit: BoxFit.cover));
          }
          return Container(width: 84, height: 84, alignment: Alignment.center, decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.photo), Text(photo.baseline ? 'Másolt' : photo.photoType, textAlign: TextAlign.center)]));
        },
      ),
    );
  }
}

class _DamageInput {
  const _DamageInput({required this.description, this.location, this.type, this.severity, this.preexisting = false, this.photoPaths = const []});
  final List<String> photoPaths;
  final String description;
  final String? location;
  final String? type;
  final String? severity;
  final bool preexisting;
}

/// Egy sérülés adatai, saját képernyőn.
class _DamageForm extends StatefulWidget {
  const _DamageForm({required this.takePhoto, required this.discardPhoto});
  /// Fotó a sérülésről (az app kamerája); a telefonra mentett kép útvonala, vagy null.
  final Future<String?> Function() takePhoto;
  final Future<void> Function(String path) discardPhoto;
  @override
  State<_DamageForm> createState() => _DamageFormState();
}

class _DamageFormState extends State<_DamageForm> {
  final _description = TextEditingController();
  String? _location;
  String? _type;
  String? _severity;
  bool _preexisting = false;
  String? _error;
  final List<String> _photos = [];
  bool _saved = false;

  @override
  void dispose() {
    _description.dispose();
    // Kilépett mentés nélkül: az itt készült fotók nem maradnak a telefonon.
    if (!_saved) {
      for (final path in _photos) {
        widget.discardPhoto(path);
      }
    }
    super.dispose();
  }

  Future<void> _addPhoto() async {
    final path = await widget.takePhoto();
    if (path != null && mounted) setState(() { _photos.add(path); _error = null; });
  }

  void _save() {
    final text = _description.text.trim();
    if (text.isEmpty && _location == null && _type == null) {
      setState(() => _error = 'Add meg a sérülés helyét, típusát vagy leírását.');
      return;
    }
    final description = text.isNotEmpty ? text : [_type, _location].whereType<String>().join(', ');
    _saved = true;
    Navigator.of(context).pop(_DamageInput(
        description: description, location: _location, type: _type, severity: _severity, preexisting: _preexisting, photoPaths: List.of(_photos)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sérülés rögzítése'), actions: [TextButton(onPressed: _save, child: const Text('Mentés'))]),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            value: _location,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Helye az autón'),
            items: [for (final v in _damageLocations) DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() { _location = v; _error = null; }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _type,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sérülés típusa'),
            items: [for (final v in _damageTypes) DropdownMenuItem(value: v, child: Text(v))],
            onChanged: (v) => setState(() { _type = v; _error = null; }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _severity,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Súlyosság'),
            items: [for (final v in _damageSeverities) DropdownMenuItem(value: v, child: Text(v))],
            onChanged: (v) => setState(() => _severity = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) { if (_error != null) setState(() => _error = null); },
            decoration: const InputDecoration(labelText: 'Leírás', hintText: 'nem kötelező – üresen a helyből és a típusból áll össze'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Korábban is meglévő sérülés'),
            value: _preexisting,
            onChanged: (v) => setState(() => _preexisting = v ?? false),
          ),
          const SizedBox(height: 8),
          // Fotó rögtön itt, a sérülés felvételekor.
          OutlinedButton.icon(
            onPressed: _addPhoto,
            icon: const Icon(Icons.add_a_photo),
            label: Text(_photos.isEmpty ? 'Fotó a sérülésről' : 'Még egy fotó (${_photos.length} kész)'),
          ),
          if (_photos.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final path in _photos)
                Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File(path), width: 96, height: 96, fit: BoxFit.cover)),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton.filledTonal(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Fotó törlése',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () { setState(() => _photos.remove(path)); widget.discardPhoto(path); },
                    ),
                  ),
                ]),
            ]),
          ),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: AppColors.signalRed, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Sérülés mentése')),
          const SizedBox(height: 8),
          const Text('Fotó később is adható a sérülés kártyáján.', style: TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
        ]),
      ),
    );
  }
}
