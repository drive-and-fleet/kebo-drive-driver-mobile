import 'package:flutter/material.dart';

import '../../auth/auth_service.dart';
import '../../services/app_services.dart';

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
  final _phone = TextEditingController();
  final _license = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _phone.dispose();
    _license.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await widget.services.auth.registerCurrentFirebaseUser(
        firstName: _firstName.text,
        lastName: _lastName.text,
        phone: _phone.text,
        licenseNumber: _license.text,
      );
    } on DriverPendingException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Regisztráció rögzítve'),
          content: Text(e.message),
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
            const Text('A regisztráció után a system admin jóváhagyása szükséges.'),
            const SizedBox(height: 20),
            TextFormField(controller: _firstName, decoration: const InputDecoration(labelText: 'Keresztnév'), validator: _required),
            const SizedBox(height: 12),
            TextFormField(controller: _lastName, decoration: const InputDecoration(labelText: 'Vezetéknév'), validator: _required),
            const SizedBox(height: 12),
            TextFormField(controller: _phone, decoration: const InputDecoration(labelText: 'Telefonszám')),
            const SizedBox(height: 12),
            TextFormField(controller: _license, decoration: const InputDecoration(labelText: 'Jogosítvány száma')),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _submit, child: const Text('Regisztráció elküldése')),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) => value == null || value.trim().isEmpty ? 'Kötelező mező' : null;
}
