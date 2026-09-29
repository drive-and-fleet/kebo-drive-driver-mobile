import 'package:flutter/material.dart';

import '../../logging/app_log.dart';

import '../../local/local_repository.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../leg_flow.dart';
import '../theme.dart';
import '../widgets/sync_badge.dart';
import 'home_screen.dart';
import 'leg_detail_screen.dart';

/// A leadás után: a fuvar kész. Megmutatja, mi zárult le és hogy a feltöltés hol
/// tart; körfuvarnál kimondja, hogy a sofőr várja meg az autót. Nem ugrik magától
/// a következő fuvarra – a sofőr dönt, hová megy tovább.
class DoneScreen extends StatefulWidget {
  const DoneScreen({super.key, required this.services, required this.leg});
  final AppServices services;
  final DriverLeg leg;

  @override
  State<DoneScreen> createState() => _DoneScreenState();
}

class _DoneScreenState extends State<DoneScreen> {
  LegSyncState? _sync;
  DriverLeg? _returnLeg;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Fuvar lezárva – ${widget.leg.registrationNumber}');
    widget.services.sync.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final key = LocalRepository.currentLegKey(widget.leg.legKey);
    final state = (await widget.services.local.legSyncStates())[key];
    final back = widget.leg.isOutbound ? await widget.services.local.returnLegFor(widget.leg) : null;
    if (mounted) setState(() { _sync = state; _returnLeg = back; });
  }

  /// Vissza a Ma fülre (akárhonnan nyitotta a fuvart), friss listákkal.
  void _home() {
    HomeScreen.tabRequest.value = 0;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final leg = widget.leg;
    final back = _returnLeg;
    // A telefon vissza gombja is a Ma fülre visz (nem a lezárt fuvar képernyőire).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _home();
      },
      child: Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('Fuvar lezárva')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.check_circle, color: AppColors.signalGreen, size: 72),
          const SizedBox(height: 12),
          Text(leg.registrationNumber, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: 34, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${leg.fromPlace}\n→ ${leg.toPlace}', textAlign: TextAlign.center, style: const TextStyle(fontSize: AppText.body)),
          const SizedBox(height: 16),
          Center(child: SyncBadge(_sync, detailed: true)),
          if (back != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.tintAmber, border: Border.all(color: AppColors.signalAmber), borderRadius: BorderRadius.circular(8)),
              child: Text(
                'Körfuvar: ne menj el! Várd meg az autót, és vidd vissza ide: ${back.toPlace}'
                '${back.plannedStart == null ? '' : '\nTervezett indulás: ${shortTime(back.plannedStart)}'}',
                style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: back.legKey))),
                icon: const Icon(Icons.u_turn_left),
                label: const Text('Visszaút megnyitása'),
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            child: back == null
                ? FilledButton.icon(onPressed: _home, icon: const Icon(Icons.home), label: const Text('Vissza a Fuvarjaimhoz'))
                : OutlinedButton.icon(onPressed: _home, icon: const Icon(Icons.home), label: const Text('Vissza a Fuvarjaimhoz')),
          ),
        ],
      ),
    ),
    );
  }
}
