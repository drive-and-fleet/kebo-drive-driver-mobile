import 'dart:io';

import 'package:flutter/material.dart';

import '../../auth/auth_service.dart';
import '../../services/app_services.dart';
import 'registration_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } on DriverNotRegisteredException {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RegistrationScreen(services: widget.services),
      ));
    } on DriverPendingException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.services.auth.busy;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.directions_car_filled, size: 72),
                  const SizedBox(height: 16),
                  Text('Fleet Driver', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  const Text('Sofőr alkalmazás', textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: busy ? null : () => _login(widget.services.auth.signInGoogle),
                    icon: const Icon(Icons.g_mobiledata),
                    label: const Text('Belépés Google-fiókkal'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : () => _login(widget.services.auth.signInFacebook),
                    icon: const Icon(Icons.facebook),
                    label: const Text('Belépés Facebookkal'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _login(widget.services.auth.signInApple),
                    icon: Icon(Platform.isIOS ? Icons.apple : Icons.login),
                    label: const Text('Belépés Apple ID-val'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('vagy')), Expanded(child: Divider())]),
                  ),
                  TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'E-mail')),
                  const SizedBox(height: 12),
                  TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Jelszó')),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => _login(() => widget.services.auth.signInEmail(_email.text, _password.text)),
                    child: const Text('Belépés e-maillel'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  if (busy) const Padding(padding: EdgeInsets.only(top: 18), child: LinearProgressIndicator()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
