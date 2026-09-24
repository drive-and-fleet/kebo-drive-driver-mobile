import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../logging/app_log.dart';
import '../../services/app_services.dart';
import '../theme.dart';

/// Hibajelentés a szerverre, a telefon naplójával együtt. A beküldés előtt a
/// sofőr megerősíti, hogy a napló is elmegy.
class BugReportScreen extends StatefulWidget {
  const BugReportScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends State<BugReportScreen> {
  final _description = TextEditingController();
  bool _sending = false;
  String? _error;
  int? _logBytes;

  @override
  void initState() {
    super.initState();
    log.info('bug', 'Hibajelentés képernyő megnyitva');
    AppLog.instance.collect().then((text) {
      if (mounted) setState(() => _logBytes = utf8.encode(text).length);
    });
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final description = _description.text.trim();
    if (description.length < 3) {
      setState(() => _error = 'Írd le röviden, mi történt.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Biztosan beküldöd?'),
        content: const Text(
          'A hibajelentéssel együtt elküldjük az alkalmazás naplóját is: mikor mit csináltál az appban, '
          'a szinkron állapotát és a hibákat. Jelszó, fotó és aláírás nincs benne.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Beküldöm')),
        ],
      ),
    );
    if (confirmed != true) {
      log.info('bug', 'Hibajelentés beküldése megszakítva');
      return;
    }

    setState(() { _sending = true; _error = null; });
    log.info('bug', 'Hibajelentés beküldése: ${widget.services.sync.pending} függő szinkron művelet');
    try {
      String? version;
      try {
        final info = await PackageInfo.fromPlatform();
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      final text = await AppLog.instance.collect();
      final id = await widget.services.api.submitBugReport({
        'description': description,
        'logGzipBase64': base64Encode(gzip.encode(utf8.encode(text))),
        if (version != null) 'appVersion': version,
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'pendingSyncOps': widget.services.sync.pending,
        'clientTime': DateTime.now().toUtc().toIso8601String(),
      });
      log.info('bug', 'Hibajelentés beküldve: $id');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Köszönjük! A hibajelentés beküldve (#$id).')));
      Navigator.pop(context);
    } catch (e) {
      log.warn('bug', 'Hibajelentés beküldése nem sikerült', e);
      // A leírás megmarad, internet mellett újra beküldhető.
      if (mounted) setState(() { _sending = false; _error = 'Nem sikerült beküldeni: $e\nInternetkapcsolat mellett próbáld újra.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hibajelentés')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Mi történt? Írd le, mit csináltál és mit vártál volna.'),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 5,
            maxLines: 10,
            maxLength: 5000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Pl. a leadási jegyzőkönyv lezárása után nem tűnt el a feltöltésre váró jelzés.'),
          ),
          const SizedBox(height: 8),
          Text(
            _logBytes == null
                ? 'A jelentéshez csatoljuk az alkalmazás naplóját.'
                : 'A jelentéshez csatoljuk az alkalmazás naplóját (${(_logBytes! / 1024).ceil()} KB).',
            style: const TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: AppColors.signalRed)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _sending ? null : _submit,
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: const Text('Beküldés'),
          ),
        ],
      ),
    );
  }
}
