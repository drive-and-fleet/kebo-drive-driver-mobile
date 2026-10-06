import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../services/app_services.dart';
import 'leg_flow.dart';
import 'permissions.dart';
import 'screens/camera_screen.dart';

/// Melyik fotóhelyre készül a kép: egy jegyzőkönyv általános fotója vagy egy sérülésé.
class PendingCapture {
  const PendingCapture({required this.draftId, required this.legKey, required this.phase, required this.photoType, this.damageLocalId});
  final String draftId;
  final String legKey;
  final String phase;
  final String photoType;
  final String? damageLocalId;

  Map<String, dynamic> toJson() => {'draftId': draftId, 'legKey': legKey, 'phase': phase, 'photoType': photoType, 'damageLocalId': damageLocalId};
  static PendingCapture? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return PendingCapture(draftId: '${m['draftId']}', legKey: '${m['legKey']}', phase: '${m['phase']}', photoType: '${m['photoType']}',
          damageLocalId: m['damageLocalId']?.toString());
    } catch (_) {
      return null;
    }
  }
}

const _pendingKey = 'pending_capture';

/// Fotó. Elsőként az app saját kamerája ([CameraScreen]): az appon belül marad, így az Android
/// nem állítja le közben. Ha az nem indul (engedély, nincs kamera), a telefon kamera-alkalmazása
/// jön – az alatt az Android leállíthatja az appot, ezért előtte feljegyezzük, hova kerül a kép;
/// újraindulás után [recoverPendingCapture] átveszi a megőrzött fotót, és visszanyitja a jegyzőkönyvet.
Future<XFile?> capturePhoto(BuildContext context, AppServices services, PendingCapture target, {String title = 'Fotó'}) async {
  // Engedély nélkül újra kérjük (ha végleg tiltva, a beállításokhoz visz).
  if (!await ensureCameraPermission(context) || !context.mounted) return null;
  final result = await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => CameraScreen(title: title)));
  if (result is XFile) return result;
  if (result is! CameraUnavailable) return null;
  log.info('insp', 'Az app kamerája nem érhető el (${result.reason}): a telefon kamera-alkalmazása nyílik');
  await services.local.setAppState(_pendingKey, jsonEncode(target.toJson()));
  try {
    return await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2000);
  } finally {
    await services.local.setAppState(_pendingKey, null);
  }
}

/// Indításkor: ha egy fotózás közben állt le az app, a kép a helyére kerül (ha az Android
/// megőrizte), és újra megnyílik az a jegyzőkönyv, amelyikben a sofőr dolgozott.
Future<void> recoverPendingCapture(BuildContext context, AppServices services) async {
  final pending = PendingCapture.fromJson(await services.local.appState(_pendingKey));
  if (pending == null) return;
  await services.local.setAppState(_pendingKey, null);
  log.info('insp', 'Fotózás közben leállt az app: visszatérés a jegyzőkönyvhöz (${pending.draftId})');
  var saved = false;
  if (Platform.isAndroid) {
    try {
      final lost = await ImagePicker().retrieveLostData();
      final file = lost.file ?? (lost.files?.isNotEmpty == true ? lost.files!.first : null);
      if (file != null) {
        final path = await services.fileStore.persistImage(file.path);
        await services.local.addPhoto(
            inspectionLocalId: pending.draftId, photoType: pending.photoType, localPath: path, damageLocalId: pending.damageLocalId);
        saved = true;
        log.info('insp', 'Fotó megmentve újraindulás után: ${pending.photoType} (${pending.draftId})');
      }
    } catch (e) {
      log.warn('insp', 'A leállás előtti fotó nem állítható vissza', e);
    }
  }
  final leg = await services.local.cachedLeg(LocalRepository.currentLegKey(pending.legKey));
  if (leg == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(saved
        ? 'A telefon a kamera idejére leállította az appot – a fotó megmaradt, folytathatod a jegyzőkönyvet.'
        : 'A telefon a kamera idejére leállította az appot – a jegyzőkönyv megmaradt, a fotót készítsd el újra.'),
    duration: const Duration(seconds: 6),
  ));
  try {
    await openInspection(context, services, leg, pending.phase);
  } catch (e) {
    log.warn('insp', 'A jegyzőkönyv nem nyitható vissza', e);
  }
}
