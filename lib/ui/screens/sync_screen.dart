import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../services/app_services.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.services.sync,
      builder: (_, __) => FutureBuilder(
        future: widget.services.local.allOpenOperations(),
        builder: (context, snapshot) {
          final operations = snapshot.data ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StreamBuilder<List<ConnectivityResult>>(
                stream: Connectivity().onConnectivityChanged,
                initialData: const [],
                builder: (_, snap) {
                  final offline = snap.data?.contains(ConnectivityResult.none) == true;
                  return Card(
                    child: ListTile(
                      leading: Icon(offline ? Icons.cloud_off : Icons.cloud_done),
                      title: Text(offline ? 'Offline mód' : 'Hálózat elérhető'),
                      subtitle: const Text('A helyszíni munka offline is menthető. A hálózat jelzése nem garantál szerverelérést.'),
                    ),
                  );
                },
              ),
              Card(
                child: ListTile(
                  leading: widget.services.sync.running ? const CircularProgressIndicator() : const Icon(Icons.sync),
                  title: Text('${widget.services.sync.pending} függő művelet'),
                  trailing: FilledButton(onPressed: widget.services.sync.running ? null : widget.services.sync.run, child: const Text('Szinkron')),
                ),
              ),
              for (final op in operations)
                Card(
                  child: ListTile(
                    leading: Icon(op.state == 'CONFLICT' ? Icons.warning_amber : Icons.schedule),
                    title: Text('${_operationLabel(op.operationType)} • ${_stateLabel(op.state)}'),
                    subtitle: Text('${op.lastError ?? 'Szinkronra vár'}\nPróbálkozás: ${op.attempts}'),
                    isThreeLine: true,
                    trailing: op.state == 'ERROR' || op.state == 'CONFLICT'
                        ? IconButton(onPressed: () => widget.services.sync.retry(op.id), icon: const Icon(Icons.refresh))
                        : null,
                  ),
                ),
              const Divider(height: 32),
              Text('Bejelentkezve: ${widget.services.auth.session?.displayName ?? '-'}'),
              Text(widget.services.auth.session?.email ?? ''),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final pending = await widget.services.local.pendingCount();
                  if (!context.mounted) return;
                  if (pending > 0) {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Előbb szinkronizálni kell'),
                        content: Text('$pending művelet még csak ezen a készüléken van. Adatvédelmi okból addig nem lehet kijelentkezni, amíg ezek nincsenek biztonságosan a szerveren.'),
                        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                      ),
                    );
                    return;
                  }
                  await widget.services.local.clearDriverData();
                  await widget.services.auth.signOut();
                },
                icon: const Icon(Icons.logout),
                label: const Text('Kijelentkezés'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _operationLabel(String value) => switch (value) {
        'SYNC_INSPECTION' => 'Jegyzőkönyv feltöltése',
        'START_LEG' => 'Fuvar indítása',
        'COMPLETE_LEG' => 'Fuvar lezárása',
        _ => value,
      };

  String _stateLabel(String value) => switch (value) {
        'PENDING' => 'Szinkronra vár',
        'RUNNING' => 'Folyamatban',
        'ERROR' => 'Hiba, újra próbálja',
        'CONFLICT' => 'Ütközés — kézi ellenőrzés kell',
        'DONE' => 'Szinkronizálva',
        _ => value,
      };
}
