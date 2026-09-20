import 'package:flutter/material.dart';

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
  String? _formId;
  String? _copyId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final existing = await widget.services.local.inspectionForLeg(widget.leg.legKey, widget.phase);
    if (existing != null) {
      final forms = await widget.services.work.formsFor(widget.leg);
      final form = forms.firstWhere((f) => f.id == existing.formTypeId);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => InspectionEditorScreen(services: widget.services, leg: widget.leg, draftId: existing.localId, form: form),
      ));
      return;
    }
    final forms = await widget.services.work.formsFor(widget.leg);
    final previous = await widget.services.local.previousInspections(widget.leg.legKey, widget.phase);
    if (mounted) {
      setState(() {
        _forms = forms;
        _previous = previous;
        _formId = forms.length == 1 ? forms.first.id : null;
        _loading = false;
      });
    }
  }

  Future<void> _continue() async {
    final formId = _formId;
    if (formId == null) return;
    final form = _forms.firstWhere((f) => f.id == formId);
    final draft = await widget.services.work.openInspection(
      leg: widget.leg,
      phase: widget.phase,
      formTypeId: form.id,
      copyFromServerId: _copyId,
    );
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => InspectionEditorScreen(services: widget.services, leg: widget.leg, draftId: draft.localId, form: form),
    ));
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
                  ],
                  onChanged: (v) => setState(() => _copyId = (v == null || v.isEmpty) ? null : v),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _formId == null ? null : _continue, child: const Text('Jegyzőkönyv megnyitása')),
              ],
            ),
    );
  }
}
