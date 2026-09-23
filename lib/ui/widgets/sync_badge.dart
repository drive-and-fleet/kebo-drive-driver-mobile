import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../theme.dart';

/// Megmondja a sofőrnek, mi van még csak a telefonon. `null` = nincs nyitott
/// sync művelet, minden a szerveren van.
class SyncBadge extends StatelessWidget {
  const SyncBadge(this.state, {super.key, this.detailed = false});
  final LegSyncState? state;

  /// Részletes kártya magyarázattal (fuvar adatlap), vagy tömör sor (lista).
  final bool detailed;

  static (IconData, Color, Color, String, String) describe(LegSyncState? state) => switch (state) {
        null || LegSyncState.synced => (Icons.cloud_done_outlined, AppColors.signalGreen, AppColors.tintGreen,
            'Szinkronizálva', 'Minden adat a szerveren van.'),
        LegSyncState.pending => (Icons.save_outlined, AppColors.signalAmber, AppColors.tintAmber,
            'Helyben mentve – feltöltésre vár', 'Az adatok biztonságban vannak a telefonon. Hálózat esetén automatikusan feltöltődnek.'),
        LegSyncState.running => (Icons.cloud_upload_outlined, AppColors.signalBlue, AppColors.tintBlue,
            'Feltöltés folyamatban', 'Az adatok most kerülnek fel a szerverre.'),
        LegSyncState.error => (Icons.sync_problem, AppColors.signalAmber, AppColors.tintAmber,
            'Feltöltési hiba – újrapróbálja', 'Az adatok a telefonon vannak. A feltöltés automatikusan újra elindul; a részletek a Szinkron nézetben.'),
        LegSyncState.conflict => (Icons.warning_amber, AppColors.signalRed, AppColors.tintRed,
            'Beavatkozás szükséges', 'A szerver elutasította a feltöltést. Nézd meg a Szinkron nézetben, és szólj a diszpécsernek.'),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color, tint, title, detail) = describe(state);
    if (!detailed) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(title, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600))),
      ]);
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: tint, border: Border.all(color: color)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: AppText.body)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
          ]),
        ),
      ]),
    );
  }
}
