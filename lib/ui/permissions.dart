import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logging/app_log.dart';
import '../local/local_repository.dart';

// iOS-en a permission_handler a Podfile post_install makróival kapcsolható be
// (PERMISSION_CAMERA=1, PERMISSION_LOCATION=1, PERMISSION_NOTIFICATIONS=1) – a Podfile a Macen készül.

const _askedKey = 'permissions_asked_v1';

/// Induláskor egyszer elmagyarázza, mire kell a kamera és a helyzet, majd kéri őket (az
/// értesítést a push maga kéri). Ha már megvannak, nem kérdez.
Future<void> requestStartupPermissions(BuildContext context, LocalRepository local) async {
  try {
    final camera = await Permission.camera.status;
    final location = await Permission.locationWhenInUse.status;
    if (camera.isGranted && location.isGranted) return;
    if (await local.appState(_askedKey) == null && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Engedélyek'),
          content: const Text('A jegyzőkönyvekhez az appnak a kamerára van szüksége (fotók az autóról és a sérülésekről), '
              'a helyzetre pedig a lezárás helyének rögzítéséhez és – ha az iroda kéri – a fuvar követéséhez.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Rendben'))],
        ),
      );
      await local.setAppState(_askedKey, DateTime.now().toUtc().toIso8601String());
    }
    final result = await [Permission.camera, Permission.locationWhenInUse].request();
    log.info('perm', 'Engedélyek induláskor: ${result.entries.map((e) => '${e.key}: ${e.value.name}').join(', ')}');
  } catch (e) {
    log.warn('perm', 'Az engedélyek kérése nem sikerült', e);
  }
}

/// Fotó előtt: ha nincs kamera-engedély, újra kéri; ha végleg tiltva van, a telefon
/// beállításaihoz visz. Igaz, ha lehet fotózni.
Future<bool> ensureCameraPermission(BuildContext context) async {
  try {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;
    status = await Permission.camera.request();
    if (status.isGranted) return true;
    log.info('perm', 'Kamera-engedély: ${status.name}');
    if (!context.mounted) return false;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kamera-engedély kell'),
        content: Text(status.isPermanentlyDenied || status.isRestricted
            ? 'A fotóhoz engedélyezd a kamerát az app beállításaiban (Engedélyek → Kamera → Engedélyezés).'
            : 'A fotóhoz engedélyezni kell a kamerát. Próbáld újra, és a felugró kérdésnél válaszd az engedélyezést.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          if (status.isPermanentlyDenied || status.isRestricted)
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Beállítások megnyitása')),
        ],
      ),
    );
    if (open == true) await openAppSettings();
    return false;
  } catch (e) {
    log.warn('perm', 'A kamera-engedély nem ellenőrizhető', e);
    return true; // a kamera maga jelez, ha mégsem megy
  }
}
