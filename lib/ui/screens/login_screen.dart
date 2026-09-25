import 'dart:io';

import 'package:flutter/material.dart';

import '../../auth/auth_service.dart';
import '../../config/app_config.dart';
import '../../services/app_services.dart';
import '../theme.dart';
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

  /// E-mail-cím bekérése, majd a webes új-jelszó oldal linkjének kérése.
  Future<void> _forgotPassword() async {
    final controller = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Elfelejtett jelszó'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Add meg a fiókod e-mail-címét: küldünk egy linket, amellyel új jelszót állíthatsz be.'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'E-mail'),
            autofocus: true,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Link küldése')),
        ],
      ),
    );
    controller.dispose();
    if (email == null || !mounted) return;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = 'Adj meg egy érvényes e-mail-címet.');
      return;
    }
    try {
      await widget.services.auth.requestPasswordReset(email);
      if (!mounted) return;
      setState(() => _error = null);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nézd meg az e-mailjeidet'),
          content: Text('Ha van fiók ezzel a címmel ($email), pár percen belül érkezik egy levél. '
              'A benne lévő gombbal új jelszót adhatsz meg (a link 60 percig érvényes), utána azzal lépj be itt. '
              'Ha nem találod, nézd meg a levélszemét mappát is.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'A kérést most nem sikerült elküldeni. Van internet? ($e)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.services.auth.busy;
    return Scaffold(
      backgroundColor: AppColors.panel900,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.local_shipping_outlined, size: 72, color: AppColors.panelInk),
                  const SizedBox(height: 16),
                  const Text(
                    'Drive and Fleet',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: AppText.screenTitle, fontWeight: FontWeight.w700, color: AppColors.panelInk),
                  ),
                  const SizedBox(height: 8),
                  const Text('Sofőr alkalmazás', textAlign: TextAlign.center, style: TextStyle(color: AppColors.panelDim, fontSize: AppText.secondary)),
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: AppColors.sheet000, border: Border.all(color: AppColors.rule)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(fontSize: AppText.body),
                          decoration: const InputDecoration(labelText: 'E-mail cím'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          style: const TextStyle(fontSize: AppText.body),
                          decoration: const InputDecoration(labelText: 'Jelszó'),
                          onSubmitted: (_) => _login(() => widget.services.auth.signInPassword(_email.text, _password.text)),
                        ),
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => _login(() => widget.services.auth.signInPassword(_email.text, _password.text)),
                          child: const Text('Belépés'),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: busy ? null : _forgotPassword,
                            child: const Text('Elfelejtett jelszó?'),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => RegistrationScreen(services: widget.services),
                                  )),
                          child: const Text('Új sofőr vagyok, regisztrálok'),
                        ),
                      ],
                    ),
                  ),
                  if (AppConfig.socialLoginEnabled) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: Row(children: [
                        Expanded(child: Divider(color: AppColors.panel700)),
                        Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('vagy', style: TextStyle(color: AppColors.panelDim))),
                        Expanded(child: Divider(color: AppColors.panel700)),
                      ]),
                    ),
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
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.signalRed)),
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
