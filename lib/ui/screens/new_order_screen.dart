import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../logging/app_log.dart';
import '../../services/app_services.dart';
import '../theme.dart';

/// Új fuvar a sofőrtől, egyszerűsítve: egy autó, honnan → hova, egy út, rögtön a
/// sofőrre. Local-first: mentés után azonnal a Munkáim között van, a szerverre a
/// szinkron viszi. A rendszám beírásakor (hálózattal) a szolgálat gépjármű-
/// nyilvántartásából kitölti az üres mezőket.
class NewOrderScreen extends StatefulWidget {
  const NewOrderScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<NewOrderScreen> createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends State<NewOrderScreen> {
  final _form = GlobalKey<FormState>();
  final _plate = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _color = TextEditingController();
  final _userName = TextEditingController();
  final _userPhone = TextEditingController();
  final _userEmail = TextEditingController();
  final _extraEmail = TextEditingController();
  final _pickupCompany = TextEditingController();
  final _pickupAddress = TextEditingController();
  final _pickupContact = TextEditingController();
  final _pickupPhone = TextEditingController();
  final _dropoffCompany = TextEditingController();
  final _dropoffAddress = TextEditingController();
  final _dropoffContact = TextEditingController();
  final _dropoffPhone = TextEditingController();
  final _notes = TextEditingController();

  List<Map<String, String>> _services = const [];
  List<Map<String, String>> _fleets = const [];
  String? _serviceId;
  String? _fleetId;
  DateTime? _pickupAt = DateTime.now().add(const Duration(minutes: 30));
  DateTime? _dropoffAt;
  bool _loading = true;
  bool _saving = false;
  String? _message;
  String? _registryHint;
  Timer? _lookupTimer;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: új fuvar');
    _loadServices();
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    for (final c in [_plate, _make, _model, _color, _userName, _userPhone, _userEmail, _extraEmail, _pickupCompany, _pickupAddress,
      _pickupContact, _pickupPhone, _dropoffCompany, _dropoffAddress, _dropoffContact, _dropoffPhone, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadServices() async {
    final services = await widget.services.work.myServices();
    if (!mounted) return;
    setState(() {
      _services = services;
      _serviceId = services.length == 1 ? services.first['id'] : null;
      _loading = false;
      if (services.isEmpty) _message = 'Nincs sofőrszolgálat a telefonon. Kapcsolódj a hálózatra, és nyisd meg újra.';
    });
    if (_serviceId != null) await _loadFleets(_serviceId!);
  }

  Future<void> _loadFleets(String serviceId) async {
    final fleets = await widget.services.work.fleets(serviceId);
    if (!mounted) return;
    setState(() {
      _fleets = fleets;
      _fleetId = fleets.length == 1 ? fleets.first['id'] : null;
      if (fleets.isEmpty) _message = 'A szolgálatnak nincs flottakezelő partnere a telefonon (hálózattal frissül).';
    });
  }

  void _plateChanged(String value) {
    _lookupTimer?.cancel();
    final serviceId = _serviceId;
    if (serviceId == null || value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length < 4) return;
    _lookupTimer = Timer(const Duration(milliseconds: 600), () async {
      final record = await widget.services.work.lookupVehicle(serviceId, value);
      if (!mounted || record == null) return;
      var filled = 0;
      void fill(TextEditingController c, String key) {
        final stored = record[key]?.toString() ?? '';
        if (stored.isNotEmpty && c.text.trim().isEmpty) {
          c.text = stored;
          filled++;
        }
      }
      fill(_make, 'make');
      fill(_model, 'model');
      fill(_color, 'color');
      fill(_userName, 'userName');
      fill(_userPhone, 'userPhone');
      fill(_userEmail, 'userEmail');
      fill(_extraEmail, 'extraEmail');
      setState(() => _registryHint = filled > 0
          ? 'Ismert autó: $filled mezőt kitöltöttünk a nyilvántartásból. Átírhatod; a változás visszaíródik.'
          : 'Ismert autó a nyilvántartásból.');
    });
  }

  Future<DateTime?> _pickDateTime(DateTime? initial) async {
    final now = DateTime.now();
    final start = initial ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: start,
      firstDate: now.subtract(const Duration(days: 7)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return initial;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start));
    if (time == null) return initial;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _fmt(DateTime? value) {
    if (value == null) return 'nincs megadva';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}.${two(value.month)}.${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
  }

  String? _required(String? value) => value == null || value.trim().isEmpty ? 'Kötelező' : null;
  String? _email(String? value) =>
      value == null || value.trim().isEmpty || RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim()) ? null : 'Érvénytelen e-mail-cím';

  String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (_serviceId == null || _fleetId == null) {
      setState(() => _message = 'Válaszd ki a sofőrszolgálatot és a flottakezelőt.');
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _message = null; });
    final fleetName = _fleets.firstWhere((f) => f['id'] == _fleetId, orElse: () => const {'name': ''})['name'] ?? '';
    final payload = <String, dynamic>{
      'serviceOrgId': _serviceId,
      'fleetOrgId': _fleetId,
      'registrationNumber': _plate.text.trim().toUpperCase(),
      'make': _text(_make), 'model': _text(_model), 'color': _text(_color),
      'userName': _text(_userName), 'userPhone': _text(_userPhone), 'userEmail': _text(_userEmail), 'extraEmail': _text(_extraEmail),
      'notes': _text(_notes),
      'pickup': {
        'addressLine': _pickupAddress.text.trim(), 'companyName': _text(_pickupCompany),
        'contactName': _text(_pickupContact), 'contactPhone': _text(_pickupPhone),
        'plannedFrom': _pickupAt?.toUtc().toIso8601String(),
      },
      'dropoff': {
        'addressLine': _dropoffAddress.text.trim(), 'companyName': _text(_dropoffCompany),
        'contactName': _text(_dropoffContact), 'contactPhone': _text(_dropoffPhone),
        'plannedFrom': _dropoffAt?.toUtc().toIso8601String(),
      },
    }..removeWhere((key, value) => value == null);
    try {
      await widget.services.work.createOrder(payload, fleetName: fleetName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Fuvar felvéve, a Munkáim között van. A szinkron elküldi az irodának.'),
      ));
      Navigator.of(context).pop(true);
    } catch (e) {
      log.warn('work', 'Új fuvar mentése nem sikerült', e);
      if (mounted) setState(() { _saving = false; _message = 'Nem sikerült menteni: $e'; });
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _field(TextEditingController c, String label, {String? Function(String?)? validator, TextInputType? keyboard, bool upper = false, ValueChanged<String>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: c,
        decoration: InputDecoration(labelText: label),
        validator: validator,
        keyboardType: keyboard,
        textCapitalization: upper ? TextCapitalization.characters : TextCapitalization.sentences,
        inputFormatters: upper ? [_UpperCaseFormatter()] : null,
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Új fuvar')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Egy autó, egy út: honnan viszed és hova. A fuvar rögtön a tiéd, és azonnal elindítható.'),
                  if (_message != null)
                    Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!, style: const TextStyle(color: AppColors.signalRed))),
                  if (_services.length > 1) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _serviceId,
                      decoration: const InputDecoration(labelText: 'Sofőrszolgálat'),
                      items: [for (final s in _services) DropdownMenuItem(value: s['id'], child: Text(s['name'] ?? ''))],
                      onChanged: (v) {
                        setState(() { _serviceId = v; _fleetId = null; _fleets = const []; });
                        if (v != null) _loadFleets(v);
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _fleetId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Flottakezelő (megrendelő)'),
                    items: [for (final f in _fleets) DropdownMenuItem(value: f['id'], child: Text(f['name'] ?? '', overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _fleetId = v),
                    validator: (v) => v == null ? 'Kötelező' : null,
                  ),
                  _section('Autó'),
                  _field(_plate, 'Rendszám *', validator: _required, upper: true, onChanged: _plateChanged),
                  if (_registryHint != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(_registryHint!, style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
                    ),
                  _field(_make, 'Gyártó'),
                  _field(_model, 'Modell'),
                  _field(_color, 'Szín'),
                  _field(_userName, 'Használó neve'),
                  _field(_userPhone, 'Használó telefon', keyboard: TextInputType.phone),
                  _field(_userEmail, 'Használó e-mail', validator: _email, keyboard: TextInputType.emailAddress),
                  _field(_extraEmail, 'További e-mail a jegyzőkönyvekhez', validator: _email, keyboard: TextInputType.emailAddress),
                  _section('Honnan (felvétel)'),
                  _field(_pickupCompany, 'Cégnév'),
                  _field(_pickupAddress, 'Cím *', validator: _required),
                  _field(_pickupContact, 'Kapcsolattartó'),
                  _field(_pickupPhone, 'Telefon', keyboard: TextInputType.phone),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: const Text('Felvétel időpontja'),
                    subtitle: Text(_fmt(_pickupAt)),
                    onTap: () async {
                      final picked = await _pickDateTime(_pickupAt);
                      if (mounted) setState(() => _pickupAt = picked);
                    },
                  ),
                  _section('Hova (leadás)'),
                  _field(_dropoffCompany, 'Cégnév'),
                  _field(_dropoffAddress, 'Cím *', validator: _required),
                  _field(_dropoffContact, 'Kapcsolattartó'),
                  _field(_dropoffPhone, 'Telefon', keyboard: TextInputType.phone),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text('Leadás időpontja (nem kötelező)'),
                    subtitle: Text(_fmt(_dropoffAt)),
                    onTap: () async {
                      final picked = await _pickDateTime(_dropoffAt ?? _pickupAt);
                      if (mounted) setState(() => _dropoffAt = picked);
                    },
                  ),
                  _section('Megjegyzés'),
                  _field(_notes, 'Megjegyzés (pl. engedélyszám)'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.add_road),
                    label: const Text('Fuvar felvétele'),
                  ),
                  if (_saving) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
                ],
              ),
            ),
    );
  }
}

/// A rendszám mindig nagybetűs, bárhogy írják.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
