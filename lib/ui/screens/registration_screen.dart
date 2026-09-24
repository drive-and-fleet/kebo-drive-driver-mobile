import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../../logging/app_log.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _form = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  final _phone = TextEditingController();
  final _license = TextEditingController();
  bool _busy = false;
  String? _loadError;
  String? _serviceOrgId;
  List<ServiceOrgOption> _services = const [];

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Regisztráció');
    _loadServices();
  }

  Future<void> _loadServices() async {
    setState(() { _busy = true; _loadError = null; });
    try {
      final services = await widget.services.auth.serviceOrganizations();
      if (!mounted) return;
      setState(() => _services = services);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'A sofőrszolgálatok betöltéséhez internetkapcsolat kell. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _password.dispose();
    _passwordConfirm.dispose();
    _phone.dispose();
    _license.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_serviceOrgId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Válassz sofőrszolgálatot')));
      return;
    }
    setState(() => _busy = true);
    try {
      final serviceName = await widget.services.auth.registerWithPassword(
        email: _email.text,
        password: _password.text,
        firstName: _firstName.text,
        lastName: _lastName.text,
        serviceOrgId: _serviceOrgId!,
        phone: _phone.text,
        licenseNumber: _license.text,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Regisztráció elküldve'),
          content: Text('A regisztrációt elküldtük a(z) $serviceName részére. Amint jóváhagyják, be tudsz lépni ugyanezzel az e-maillel és jelszóval.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sofőr regisztráció')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('A regisztráció után a kiválasztott sofőrszolgálat ügyintézőjének jóváhagyása szükséges.'),
            const SizedBox(height: 20),
            TextFormField(controller: _lastName, decoration: const InputDecoration(labelText: 'Vezetéknév'), validator: _required),
            const SizedBox(height: 12),
            TextFormField(controller: _firstName, decoration: const InputDecoration(labelText: 'Keresztnév'), validator: _required),
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail cím'),
              validator: (v) => (v == null || !v.contains('@')) ? 'Érvényes e-mail cím szükséges' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Jelszó'),
              validator: (v) => (v == null || v.length < 8) ? 'Legalább 8 karakter' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordConfirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Jelszó megerősítése'),
              validator: (v) => v != _password.text ? 'A két jelszó nem egyezik' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Telefonszám')),
            const SizedBox(height: 12),
            TextFormField(controller: _license, decoration: const InputDecoration(labelText: 'Jogosítvány száma')),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: ValueKey(_services.length),
              value: _serviceOrgId,
              decoration: const InputDecoration(labelText: 'Sofőrszolgálat'),
              items: _services.map((s) => DropdownMenuItem(value: s.id, child: Text(s.name))).toList(),
              onChanged: (value) => setState(() => _serviceOrgId = value),
              validator: (v) => v == null ? 'Válassz sofőrszolgálatot' : null,
            ),
            if (_loadError != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text(_loadError!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error))),
                TextButton(onPressed: _loadServices, child: const Text('Újra')),
              ]),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _submit, child: const Text('Regisztráció elküldése')),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) => value == null || value.trim().isEmpty ? 'Kötelező mező' : null;
}
