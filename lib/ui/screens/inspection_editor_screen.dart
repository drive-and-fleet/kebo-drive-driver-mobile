import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../widgets/dynamic_field.dart';
import '../../logging/app_log.dart';

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

  /// Lezárt jegyzőkönyv csak megtekinthető: a tartalma már a sync sorban van,
  /// utólagos változás sosem jutna fel a szerverre.
  bool get _readOnly => _draft?.status != 'DRAFT' || _finalizing;

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
    if (mounted) setState(() {
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

  Future<void> _saveValue(FormFieldConfig field, Map<String, dynamic> value, List<String> options) {
    log.debug('insp', 'Mező mentve: ${field.fieldDefinitionId} (${widget.draftId})');
    return _guard(() => widget.services.local.saveInspectionValue(widget.draftId, field.fieldDefinitionId, value, options));
  }

  Future<void> _takeGeneralPhoto(String type) async {
    final image = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88, maxWidth: 2200);
    if (image == null) {
      log.debug('insp', 'Fotó megszakítva: $type');
      return;
    }
    final path = await widget.services.fileStore.persistImage(image.path);
    log.info('insp', 'Fotó készült: $type (${widget.draftId})');
    await _guard(() => widget.services.local.addPhoto(inspectionLocalId: widget.draftId, photoType: type, localPath: path));
  }

  Future<void> _addDamage() async {
    final description = TextEditingController();
    String? location;
    String? type;
    String? severity;
    bool preexisting = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: const Text('Sérülés rögzítése'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: description, decoration: const InputDecoration(labelText: 'Leírás *'), maxLines: 2),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: location,
            decoration: const InputDecoration(labelText: 'Helye az autón'),
            items: [for (final v in _damageLocations) DropdownMenuItem(value: v, child: Text(v))],
            onChanged: (v) => setDialogState(() => location = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: type,
            decoration: const InputDecoration(labelText: 'Sérülés típusa'),
            items: [for (final v in _damageTypes) DropdownMenuItem(value: v, child: Text(v))],
            onChanged: (v) => setDialogState(() => type = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: severity,
            decoration: const InputDecoration(labelText: 'Súlyosság'),
            items: [for (final v in _damageSeverities) DropdownMenuItem(value: v, child: Text(v))],
            onChanged: (v) => setDialogState(() => severity = v),
          ),
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Korábban is meglévő sérülés'), value: preexisting, onChanged: (v) => setDialogState(() => preexisting = v ?? false)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, description.text.trim().isNotEmpty), child: const Text('Mentés')),
        ],
      )),
    );
    if (ok == true) {
      final text = description.text.trim();
      log.info('insp', 'Sérülés rögzítve: ${location ?? '-'} / ${type ?? '-'} / ${severity ?? '-'}${preexisting ? ' (korábbi)' : ''} (${widget.draftId})');
      await _guard(() => widget.services.local.addDamage(
            inspectionLocalId: widget.draftId,
            description: text,
            location: location,
            damageType: type,
            severity: severity,
            isPreexisting: preexisting,
          ));
    }
    description.dispose();
  }

  Future<void> _takeDamagePhoto(LocalDamage damage) async {
    final image = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88, maxWidth: 2200);
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

  Future<void> _addSignature() async {
    final name = TextEditingController(text: widget.leg.vehicleUserName ?? '');
    final controller = SignatureController(penStrokeWidth: 3);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kézi szignó'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Aláíró neve')),
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

  Future<void> _finalize() async {
    final draft = _draft;
    if (draft == null) return;
    // A még időzített megjegyzés-mentés előbb lefut: a lezárt jegyzőkönyv már nem módosítható.
    if (_noteTimer?.isActive ?? false) {
      _noteTimer!.cancel();
      await _saveNote();
    }
    setState(() => _finalizing = true);
    log.info('insp', 'Lezárás kérve: ${draft.inspectionType} ${draft.localId}');
    try {
      final legStatus = await widget.services.work.finalizeInspection(draft, widget.form);
      if (!mounted) return;
      final what = switch (legStatus) {
        'IN_PROGRESS' when draft.inspectionType == 'PICKUP' => 'Jegyzőkönyv lezárva, a fuvar elindult.',
        'COMPLETED_PENDING_SYNC' => 'Jegyzőkönyv lezárva, a fuvar lezárva.',
        _ => 'Jegyzőkönyv lezárva.',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$what Helyben mentve, a feltöltés a háttérben fut.'),
      ));
      // Elindult a fuvar: ha az iroda kéri, most kérjük a helyengedélyt (előtte elmagyarázzuk).
      if (legStatus == 'IN_PROGRESS' && draft.inspectionType == 'PICKUP') {
        await widget.services.location.askIfNeeded(context, widget.leg);
        if (!mounted) return;
      }
      // Sikeres lezárás után a képernyő zárva marad, amíg el nem tűnik.
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _finalizing = false);
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
    return Scaffold(
      appBar: AppBar(title: Text(phase == 'PICKUP' ? 'Átvételi jegyzőkönyv' : 'Leadási jegyzőkönyv')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(child: ListTile(leading: const Icon(Icons.directions_car), title: Text(widget.leg.registrationNumber), subtitle: Text('${widget.leg.make ?? ''} ${widget.leg.model ?? ''}\n${widget.form.name}'))),
                if (_draft != null && _draft!.status != 'DRAFT')
                  const Card(child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Lezárt jegyzőkönyv'), subtitle: Text('Csak megtekinthető. A feltöltés állapotát a fuvar adatlapja mutatja.'))),
                if (_draft?.copyFromServerId != null || _draft?.copyFromLocalId != null)
                  const Card(child: ListTile(leading: Icon(Icons.copy_all), title: Text('Korábbi jegyzőkönyvből előtöltve'), subtitle: Text('Ellenőrizd az adatokat. Az aláírás nem lett átmásolva.'))),
                const SizedBox(height: 12),
                Text('Adatok', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                for (final field in fields)
                  DynamicField(field: field, value: _values[field.fieldDefinitionId], enabled: !_readOnly, onChanged: (value, options) => _saveValue(field, value, options)),
                const SizedBox(height: 16),
                Text('Fotók', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                for (final requirement in requirements)
                  Card(child: ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: Text('${requirement.photoType}${requirement.required ? ' *' : ''}'),
                    subtitle: Text('Minimum: ${requirement.minCount} • Rögzítve: ${_photos.where((p) => p.damageLocalId == null && p.photoType == requirement.photoType).length}'),
                    trailing: IconButton(onPressed: _readOnly ? null : () => _takeGeneralPhoto(requirement.photoType), icon: const Icon(Icons.add_a_photo)),
                  )),
                if (_photos.where((p) => p.damageLocalId == null).isNotEmpty)
                  _PhotoStrip(photos: _photos.where((p) => p.damageLocalId == null).toList()),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Sérülések', style: Theme.of(context).textTheme.titleLarge),
                  FilledButton.tonalIcon(onPressed: _readOnly ? null : _addDamage, icon: const Icon(Icons.add), label: const Text('Sérülés')),
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
                          Align(alignment: Alignment.centerRight, child: FilledButton.tonalIcon(onPressed: _readOnly ? null : () => _takeDamagePhoto(damage), icon: const Icon(Icons.add_a_photo), label: const Text('Sérülés fotó'))),
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
                  FilledButton.tonalIcon(
                    onPressed: _readOnly ? null : _addSignature,
                    icon: const Icon(Icons.draw),
                    label: Text(_signatures.isEmpty ? 'Szignó' : 'Szignó cseréje'),
                  ),
                ]),
                for (final signature in _signatures)
                  ListTile(
                    leading: const Icon(Icons.draw),
                    title: Text(signature.signerName),
                    subtitle: Text(signature.signedAt.toLocal().toString().substring(0, 16)),
                    trailing: _readOnly
                        ? null
                        : IconButton(
                            tooltip: 'Szignó törlése',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteSignature(signature),
                          ),
                  ),
                const SizedBox(height: 24),
                if (_draft?.status == 'DRAFT') ...[
                  FilledButton.icon(onPressed: _finalizing ? null : _finalize, icon: const Icon(Icons.check), label: const Text('Jegyzőkönyv lezárása')),
                  if (_finalizing) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
                ],
              ],
            ),
    );
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
