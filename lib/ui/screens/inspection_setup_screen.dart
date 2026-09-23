import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import 'inspection_editor_screen.dart';

class InspectionSetupScreen extends StatefulWidget {
  const InspectionSetupScreen({super.key, required this.services, required this.leg, required this.phase});
  final AppServices services;
  final DriverLeg leg;
  final String phase;

  @override
  State<InspectionSetupScreen> createState() => _InspectionSetupScreenState();
}

class _InspectionSetupScreenState extends State<InspectionSetupScreen> {
  List<FormTypeConfig> _forms = const [];
  List<PreviousInspection> _previous = const [];
  List<LocalInspectionDraft> _localPrevious = const [];
  String? _formId;
  /// Szerveroldali forrás az azonosító, lokális forrás a 'local:' előtaggal.
  String? _copyId;
  bool _loading = true;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Az Editor fölé nyílik, és amikor bezárul, ez a képernyő is — így a hívó
  /// `push` future-je a teljes folyamat végén teljesül, nem az Editor
  /// megnyitásakor (a `pushReplacement` azonnal teljesítette volna).
  Future<void> _openEditor(String draftId, FormTypeConfig form) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionEditorScreen(services: widget.services, leg: widget.leg, draftId: draftId, form: form),
    ));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _load() async {
    final existing = await widget.services.local.inspectionForLeg(widget.leg.legKey, widget.phase);
    if (existing != null) {
      // Piszkozat: folytatás. Lezárt: csak megtekintés (az Editor read-only).
      final forms = await widget.services.work.formsFor(widget.leg);
      final form = forms.where((f) => f.id == existing.formTypeId).firstOrNull;
      if (!mounted) return;
      if (form == null) {
        setState(() {
          _loading = false;
          _error = 'A jegyzőkönyv űrlapja nincs a készüléken. Frissítsd a munkalistát hálózat mellett.';
        });
        return;
      }
      await _openEditor(existing.localId, form);
      return;
    }
    final forms = await widget.services.work.formsFor(widget.leg);
    final previous = await widget.services.local.previousInspections(widget.leg.legKey);
    // Offline is lehessen az átvételi jegyzőkönyvet másolni, akkor is, ha még nem szinkronizált.
    final serverIds = previous.map((p) => p.serverId).toSet();
    final localPrevious = (await widget.services.local.localInspectionsForCopy(widget.leg.legKey, 'PICKUP'))
        .where((d) => d.serverId == null || !serverIds.contains(d.serverId))
        .toList();
    if (mounted) {
      setState(() {
        _forms = forms;
        _previous = previous;
        _localPrevious = widget.phase == 'DROPOFF' ? localPrevious : const [];
        _formId = forms.length == 1 ? forms.first.id : null;
        _loading = false;
      });
    }
  }

  Future<void> _continue() async {
    final formId = _formId;
    if (formId == null || _opening) return;
    setState(() { _opening = true; _error = null; });
    try {
      final form = _forms.firstWhere((f) => f.id == formId);
      final copy = _copyId;
      final fromLocal = copy != null && copy.startsWith('local:');
      final draft = await widget.services.work.openInspection(
        leg: widget.leg,
        phase: widget.phase,
        formTypeId: form.id,
        copyFromServerId: fromLocal ? null : copy,
        copyFromLocalId: fromLocal ? copy.substring('local:'.length) : null,
      );
      if (!mounted) return;
      await _openEditor(draft.localId, form);
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _opening = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.phase == 'PICKUP' ? 'Átvételi jegyzőkönyv' : 'Leadási jegyzőkönyv')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                Text('Rendszám: ${widget.leg.registrationNumber}', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _formId,
                  decoration: const InputDecoration(labelText: 'Űrlaptípus'),
                  items: _forms.map((f) => DropdownMenuItem(value: f.id, child: Text(f.name))).toList(),
                  onChanged: (v) => setState(() => _formId = v),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _copyId ?? '',
                  decoration: const InputDecoration(labelText: 'Korábbi jegyzőkönyv másolása', helperText: 'Opcionális. A kézi aláírás nem másolódik.'),
                  items: [
                    const DropdownMenuItem<String>(value: '', child: Text('Ne másoljon')), 
                    ..._previous.map((p) => DropdownMenuItem<String>(
                      value: p.serverId,
                      child: Text('${p.completedAt?.toLocal().toString().substring(0, 16) ?? 'Korábbi'} • ${p.inspectionType}'),
                    )),
                    ..._localPrevious.map((d) => DropdownMenuItem<String>(
                      value: 'local:${d.localId}',
                      child: Text('${d.updatedAt.toLocal().toString().substring(0, 16)} • ${d.inspectionType}'
                          '${d.status == 'SYNCED' ? '' : ' (még nem szinkronizált)'}'),
                    )),
                  ],
                  onChanged: (v) => setState(() => _copyId = (v == null || v.isEmpty) ? null : v),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _formId == null || _opening ? null : _continue, child: const Text('Jegyzőkönyv megnyitása')),
              ],
            ),
    );
  }
}
