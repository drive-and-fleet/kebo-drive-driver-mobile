import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../api/driver_api.dart';
import '../api/http_api.dart';
import '../local/local_repository.dart';
import '../models/local_models.dart';

/// Exponential backoff, capped at 5 minutes, so a failing operation is not
/// retried on every connectivity blip. PENDING operations are always due.
/// Pure and top-level so it can be checked without a database or a server.
bool syncOperationDue(SyncOperation operation, DateTime now) {
  if (operation.state != 'ERROR') return true;
  final seconds = (1 << operation.attempts.clamp(0, 8)).clamp(1, 300);
  return now.difference(operation.updatedAt) >= Duration(seconds: seconds);
}

class SyncService extends ChangeNotifier {
  SyncService(this.api, this.local);
  final DriverApi api;
  final LocalRepository local;

  bool _running = false;
  bool _again = false;
  Future<void>? _inFlight;
  int _pending = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _timer;

  bool get running => _running;
  int get pending => _pending;

  Future<void> initialize() async {
    await local.resetStuckRunningOperations();
    await refreshCount();
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) unawaited(run());
    });
    // ponytail: foreground periodic retry, not a background task. A closed-app
    // sync needs WorkManager/BGTaskScheduler; add that if drivers need it.
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(run()));
  }

  Future<void> disposeService() async {
    await _connectivity?.cancel();
    _timer?.cancel();
  }

  Future<void> refreshCount() async {
    _pending = await local.pendingCount();
    notifyListeners();
  }

  /// Ha épp fut egy szinkron, a hívás nem vész el: megjelöli, hogy még egy kör
  /// kell, és a futó szinkronra várakozik. Enélkül a "Jegyzőkönyv lezárása"
  /// első megnyomása csendben nem csinált semmit, ha a percenkénti időzítő
  /// épp benne volt egy körben.
  Future<void> run() {
    if (_running) {
      _again = true;
      return _inFlight!;
    }
    return _inFlight = _drain();
  }

  Future<void> _drain() async {
    _running = true;
    notifyListeners();
    try {
      do {
        _again = false;
        await _pass();
      } while (_again);
    } finally {
      _running = false;
      await refreshCount();
    }
  }

  Future<void> _pass() async {
    for (final operation in await local.pendingOperations()) {
      // Ordered queue: stop at the first operation that is still backing off
      // rather than skipping past it. A leg must not be reported as started
      // on the server while the pickup protocol it depends on is still
      // waiting to upload.
      if (!_isDue(operation)) break;
      await local.operationRunning(operation.id);
      try {
        switch (operation.operationType) {
          case 'START_LEG':
            await _legTransition(operation.entityId, 'IN_PROGRESS', () => api.start(operation.entityId));
            break;
          case 'SYNC_INSPECTION':
            await _syncInspection(operation.entityId);
            break;
          case 'COMPLETE_LEG':
            await _legTransition(operation.entityId, 'COMPLETED', () => api.complete(operation.entityId));
            break;
          default:
            throw StateError('Ismeretlen sync művelet: ${operation.operationType}');
        }
        await local.operationDone(operation.id);
      } on ApiException catch (e) {
        await local.operationError(operation.id, e.message, conflict: e.isConflict);
        if (e.statusCode == 0) break; // no network: keep the remaining queue untouched
      } catch (e) {
        await local.operationError(operation.id, e.toString());
      }
    }
  }

  /// A szerver oldali indítás/lezárás idempotens (a már célállapotban lévő
  /// szakaszra sem dob ütközést), így itt elég a hívás után a lokális státuszt
  /// a szerveréhez igazítani.
  Future<void> _legTransition(String legKey, String target, Future<void> Function() call) async {
    await call();
    await local.updateLegStatus(legKey, target);
  }

  bool _isDue(SyncOperation operation) => syncOperationDue(operation, DateTime.now().toUtc());

  Future<void> _syncInspection(String localId) async {
    if ((await local.inspection(localId))?.status == 'SYNCED') return;
    try {
      await _uploadInspection(localId);
    } on ApiException catch (e) {
      // A szerver már lezárta ezt a jegyzőkönyvet: nincs mit újrapróbálni,
      // különben a sor a végtelenségig ismétli a "inspection closed" hibát.
      if (!e.message.contains('inspection closed')) rethrow;
    }
    await local.markInspectionSynced(localId);
  }

  Future<void> _uploadInspection(String localId) async {
    var draft = await local.inspection(localId);
    if (draft == null) throw StateError('Hiányzó lokális jegyzőkönyv: $localId');

    var serverId = draft.serverId;
    if (serverId == null) {
      serverId = await api.createInspection(
        legKey: draft.legKey,
        formTypeId: draft.formTypeId,
        inspectionType: draft.inspectionType,
        deviceOperationId: draft.localId,
        copyFromInspectionId: draft.copyFromServerId,
      );
      await local.markInspectionServerId(localId, serverId);
      draft = (await local.inspection(localId))!;
    }

    final values = await local.inspectionValues(localId);
    await api.saveValues(serverId, values.entries.map((entry) {
      final row = entry.value;
      return <String, dynamic>{
        'fieldDefinitionId': entry.key,
        if (row['value_text'] != null) 'valueText': row['value_text'],
        if (row['value_number'] != null) 'valueNumber': '${row['value_number']}',
        if (row['value_boolean'] != null) 'valueBoolean': row['value_boolean'] == 1 || row['value_boolean'] == true,
        if (row['value_date'] != null) 'valueDate': row['value_date'],
        if (row['value_datetime'] != null) 'valueDatetime': row['value_datetime'],
        if ((row['option_ids'] as List? ?? const []).isNotEmpty) 'optionIds': row['option_ids'],
      };
    }).toList());

    var damages = await local.damages(localId);
    for (final damage in damages.where((d) => !d.baseline && d.serverId == null)) {
      final id = await api.addDamage(serverId, {
        if (damage.damageType != null) 'damageType': damage.damageType,
        if (damage.location != null) 'location': damage.location,
        'description': damage.description,
        if (damage.severity != null) 'severity': damage.severity,
        if (damage.isPreexisting != null) 'isPreexisting': damage.isPreexisting,
      });
      await local.setDamageServerId(damage.localId, id);
    }
    damages = await local.damages(localId);
    final damageServerIds = {for (final d in damages) d.localId: d.serverId};

    for (final photo in (await local.photos(localId)).where((p) => !p.baseline && p.serverId == null)) {
      if (photo.localPath == null) throw StateError('Lokális fotófájl hiányzik: ${photo.localId}');
      final file = File(photo.localPath!);
      if (!await file.exists()) throw StateError('Fotófájl nem található: ${photo.localPath}');
      final contentType = p.extension(file.path).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';
      final presign = await api.presign(serverId, p.basename(file.path), contentType,
          kind: photo.damageLocalId == null ? 'PHOTO' : 'DAMAGE');
      final uploadUrl = '${presign['uploadUrl']}';
      final storageKey = '${presign['storageKey']}';
      await api.uploadToPresignedUrl(uploadUrl, file, contentType);
      final damageId = photo.damageLocalId == null ? null : damageServerIds[photo.damageLocalId];
      final photoId = await api.addPhoto(serverId, {
        if (damageId != null) 'damageId': damageId,
        'storageKey': storageKey,
        'photoType': photo.photoType,
        'capturedAt': photo.capturedAt.toUtc().toIso8601String(),
      });
      await local.updatePhotoUpload(photo.localId, serverId: photoId, storageKey: storageKey);
    }

    for (final signature in (await local.signatures(localId)).where((s) => s.serverId == null)) {
      final file = File(signature.localPath);
      if (!await file.exists()) throw StateError('Aláírásfájl nem található');
      final presign = await api.presign(serverId, p.basename(file.path), 'image/png', kind: 'SIGNATURE');
      final storageKey = '${presign['storageKey']}';
      await api.uploadToPresignedUrl('${presign['uploadUrl']}', file, 'image/png');
      final signatureId = await api.addSignature(serverId, {
        'signerName': signature.signerName,
        if (signature.signerRole != null) 'signerRole': signature.signerRole,
        'storageKey': storageKey,
        'signedAt': signature.signedAt.toUtc().toIso8601String(),
      });
      await local.updateSignatureUpload(signature.localId, serverId: signatureId, storageKey: storageKey);
    }

    await api.completeInspection(serverId);
  }

  Future<void> retry(String operationId) async {
    await local.retryOperation(operationId);
    await run();
  }
}
