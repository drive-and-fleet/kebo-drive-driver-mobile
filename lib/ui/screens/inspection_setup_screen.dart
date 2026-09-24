import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import 'inspection_editor_screen.dart';
import '../../logging/app_log.dart';

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
  String? _formId;
  /// Az egyetlen másolható jegyzőkönyv (az autó közvetlenül előző jegyzőkönyve), ha van.
  CopySource? _source;
  bool _copy = false;
  bool _loading = true;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: ${widget.phase == 'PICKUP' ? 'átvételi' : 'leadási'} jegyzőkönyv indítása (${widget.leg.legKey})');
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
    final source = await widget.services.local.copySourceFor(widget.leg, widget.phase);
    if (mounted) {
      setState(() {
        _forms = forms;
        _source = source;
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
      final source = _copy ? _source : null;
      final draft = await widget.services.work.openInspection(
        leg: widget.leg,
        phase: widget.phase,
        formTypeId: form.id,
        copyFromServerId: source?.serverId,
        copyFromLocalId: source?.localId,
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
                if (_source != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _copy,
                    onChanged: (v) => setState(() => _copy = v),
                    title: const Text('Másolás az előző jegyzőkönyvből'),
                    subtitle: Text('${_source!.label}\n'
                        'Az adatok és a sérülések átkerülnek, a kézi aláírás nem. Ellenőrizd őket, és készítsd el a kért fotókat.'),
                    isThreeLine: true,
                  )
                else
                  Text(
                    'Ennél az autónál nincs előző jegyzőkönyv, ezért nincs mit másolni.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _formId == null || _opening ? null : _continue, child: const Text('Jegyzőkönyv megnyitása')),
              ],
            ),
    );
  }
}
