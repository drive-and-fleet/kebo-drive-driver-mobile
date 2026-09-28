import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../logging/app_log.dart';
import '../../services/app_services.dart';
import '../widgets/address_input.dart';
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
  final _pickupEmail = TextEditingController();
  final _dropoffCompany = TextEditingController();
  final _dropoffAddress = TextEditingController();
  final _dropoffContact = TextEditingController();
  final _dropoffPhone = TextEditingController();
  final _dropoffEmail = TextEditingController();
  final _notes = TextEditingController();

  List<Map<String, String>> _services = const [];
  List<Map<String, String>> _fleets = const [];
  String? _serviceId;
  String? _fleetId;
  DateTime? _pickupAt = _nextQuarter(DateTime.now().add(const Duration(minutes: 30)));
  DateTime? _dropoffAt;
  bool _loading = true;
  bool _saving = false;
  String? _message;
  String? _registryHint;
  Timer? _lookupTimer;
  /// Amit a nyilvántartás töltött ki (mező → érték): más rendszámnál ezek törlődnek.
  final Map<TextEditingController, String> _filledFromRegistry = {};

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
      _pickupContact, _pickupPhone, _pickupEmail, _dropoffCompany, _dropoffAddress, _dropoffContact, _dropoffPhone, _dropoffEmail, _notes]) {
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
    // Más rendszám: amit az előző rendszám adatai töltöttek ki (és azóta nem írtad át), törlődik.
    if (_filledFromRegistry.isNotEmpty || _registryHint != null) {
      _filledFromRegistry.forEach((c, filled) {
        if (c.text == filled) c.clear();
      });
      _filledFromRegistry.clear();
      setState(() => _registryHint = null);
    }
    final serviceId = _serviceId;
    if (serviceId == null || value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length < 4) return;
    _lookupTimer = Timer(const Duration(milliseconds: 600), () async {
      final record = await widget.services.work.lookupVehicle(serviceId, value);
      // Közben tovább gépelt: a válasz a régi rendszámé.
      if (!mounted || record == null || _plate.text != value) return;
      var filled = 0;
      void fill(TextEditingController c, String key) {
        final stored = record[key]?.toString() ?? '';
        if (stored.isNotEmpty && c.text.trim().isEmpty) {
          c.text = stored;
          _filledFromRegistry[c] = stored;
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

  /// A következő negyedóra (10:07 → 10:15).
  static DateTime _nextQuarter(DateTime t) {
    final rounded = DateTime(t.year, t.month, t.day, t.hour, (t.minute / 15).ceil() * 15);
    return rounded;
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
    final now = DateTime.now().subtract(const Duration(minutes: 1));
    if (_pickupAt != null && _pickupAt!.isBefore(now)) {
      setState(() => _message = 'A felvétel időpontja nem lehet a múltban.');
      return;
    }
    if (_dropoffAt != null && _pickupAt != null && _dropoffAt!.isBefore(_pickupAt!)) {
      setState(() => _message = 'A leadás nem lehet korábban, mint a felvétel.');
      return;
    }
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
        'contactName': _text(_pickupContact), 'contactPhone': _text(_pickupPhone), 'contactEmail': _text(_pickupEmail),
        'plannedFrom': _pickupAt?.toUtc().toIso8601String(),
      },
      'dropoff': {
        'addressLine': _dropoffAddress.text.trim(), 'companyName': _text(_dropoffCompany),
        'contactName': _text(_dropoffContact), 'contactPhone': _text(_dropoffPhone), 'contactEmail': _text(_dropoffEmail),
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
                  AddressInput(controller: _pickupAddress, label: 'Cím *', validator: _required, suggest: widget.services.api.suggestAddresses),
                  _field(_pickupContact, 'Kapcsolattartó neve'),
                  _field(_pickupPhone, 'Telefon', keyboard: TextInputType.phone),
                  _field(_pickupEmail, 'E-mail', validator: _email, keyboard: TextInputType.emailAddress),
                  WhenField(
                    label: 'Felvétel időpontja',
                    value: _pickupAt,
                    earliest: DateTime.now(),
                    onChanged: (v) => setState(() {
                      _pickupAt = v;
                      if (_dropoffAt != null && v != null && _dropoffAt!.isBefore(v)) _dropoffAt = null;
                    }),
                  ),
                  _section('Hova (leadás)'),
                  _field(_dropoffCompany, 'Cégnév'),
                  AddressInput(controller: _dropoffAddress, label: 'Cím *', validator: _required, suggest: widget.services.api.suggestAddresses),
                  _field(_dropoffContact, 'Kapcsolattartó neve'),
                  _field(_dropoffPhone, 'Telefon', keyboard: TextInputType.phone),
                  _field(_dropoffEmail, 'E-mail', validator: _email, keyboard: TextInputType.emailAddress),
                  WhenField(
                    label: 'Leadás időpontja (nem kötelező)',
                    value: _dropoffAt,
                    earliest: _pickupAt ?? DateTime.now(),
                    optional: true,
                    onChanged: (v) => setState(() => _dropoffAt = v),
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

/// Időpont két részben: a nap (naptárból, múltbeli nem választható) és az idő
/// (lenyíló negyedórás lista; a legkorábbi napon csak a még el nem múlt idők).
class WhenField extends StatelessWidget {
  const WhenField({super.key, required this.label, required this.value, required this.earliest, required this.onChanged, this.optional = false});
  final String label;
  final DateTime? value;
  /// Ennél korábbi időpont nem választható.
  final DateTime earliest;
  final ValueChanged<DateTime?> onChanged;
  final bool optional;

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// A nap negyedórái; a legkorábbi napon csak a legkorábbi időtől.
  List<String> _times(DateTime day) {
    final all = [for (var m = 0; m < 24 * 60; m += 15) '${_two(m ~/ 60)}:${_two(m % 60)}'];
    if (!_sameDay(day, earliest)) return all;
    final from = _hm(earliest);
    return all.where((t) => t.compareTo(from) >= 0).toList();
  }

  Future<void> _pickDay(BuildContext context) async {
    final first = DateTime(earliest.year, earliest.month, earliest.day);
    final current = value ?? earliest;
    final day = await showDatePicker(
      context: context,
      initialDate: current.isBefore(first) ? first : current,
      firstDate: first,
      lastDate: first.add(const Duration(days: 365)),
    );
    if (day == null) return;
    // Az idő marad; ha azon a napon már elmúlt, a legkorábbi választható idő lesz.
    final keep = value ?? DateTime(day.year, day.month, day.day, 8);
    var next = DateTime(day.year, day.month, day.day, keep.hour, keep.minute);
    final times = _times(next);
    if (!times.contains(_hm(next)) && _sameDay(next, earliest)) {
      if (times.isEmpty) return;
      final parts = times.first.split(':');
      next = DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts[1]));
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    final times = v == null ? const <String>[] : _times(v);
    final current = v == null ? null : _hm(v);
    final items = [...times, if (current != null && !times.contains(current)) current]..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today),
              label: Text(v == null ? 'Nap' : '${v.year}.${_two(v.month)}.${_two(v.day)}.'),
              onPressed: () => _pickDay(context),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            // Sima lenyíló: mindig a pillanatnyi értéket mutatja (a nap váltásakor az idő is változhat).
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Idő', isDense: true),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: current,
                  isExpanded: true,
                  isDense: true,
                  hint: const Text('óó:pp'),
                  items: [for (final t in items) DropdownMenuItem(value: t, child: Text(t))],
                  onChanged: v == null
                      ? null
                      : (t) {
                          if (t == null) return;
                          final parts = t.split(':');
                          onChanged(DateTime(v.year, v.month, v.day, int.parse(parts[0]), int.parse(parts[1])));
                        },
                ),
              ),
            ),
          ),
          if (optional && v != null) IconButton(icon: const Icon(Icons.clear), tooltip: 'Törlés', onPressed: () => onChanged(null)),
        ]),
      ]),
    );
  }
}
