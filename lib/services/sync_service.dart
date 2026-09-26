import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../api/driver_api.dart';
import '../api/http_api.dart';
import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../models/local_models.dart';

/// Exponential backoff, capped at 5 minutes, so a failing operation is not
/// retried on every connectivity blip. PENDING operations are always due.
/// Pure and top-level so it can be checked without a database or a server.
bool syncOperationDue(SyncOperation operation, DateTime now) {
  if (operation.state != 'ERROR') return true;
  final seconds = (1 << operation.attempts.clamp(0, 8)).clamp(1, 300);
  return now.difference(operation.updatedAt) >= Duration(seconds: seconds);
}

/// A szerver stabil hibakóddal jelzi a lezárt jegyzőkönyvet; a régi szerver
/// csak az üzenetet küldte.
bool isInspectionClosed(ApiException e) {
  if (e.statusCode != 409) return false;
  final body = e.body;
  if (body is Map && body['code'] == 'INSPECTION_CLOSED') return true;
  return e.message.contains('inspection closed');
}

/// A saveValues payload: csak a jegyzőkönyv fázisába tartozó mezők (ha a form
/// ismert), és üres értéket nem küld — mindkettőt véglegesen elutasítaná a
/// szerver, és a teljes feltöltés elakadna.
List<Map<String, dynamic>> inspectionValuesPayload(Map<String, Map<String, dynamic>> values, Set<String> phaseFieldIds) {
  final result = <Map<String, dynamic>>[];
  for (final entry in values.entries) {
    if (phaseFieldIds.isNotEmpty && !phaseFieldIds.contains(entry.key)) continue;
    final row = entry.value;
    final optionIds = (row['option_ids'] as List? ?? const []).map((id) => '$id').toList();
    final number = LocalRepository.normalizeNumber(row['value_number']);
    final text = row['value_text'];
    final item = <String, dynamic>{
      'fieldDefinitionId': entry.key,
      if (text != null && '$text'.isNotEmpty) 'valueText': text,
      if (number != null) 'valueNumber': number,
      if (row['value_boolean'] != null) 'valueBoolean': row['value_boolean'] == 1 || row['value_boolean'] == true,
      if (row['value_date'] != null && '${row['value_date']}'.isNotEmpty) 'valueDate': row['value_date'],
      if (row['value_datetime'] != null && '${row['value_datetime']}'.isNotEmpty) 'valueDatetime': row['value_datetime'],
      if (optionIds.isNotEmpty) 'optionIds': optionIds,
    };
    if (item.length == 1) continue;
    result.add(item);
  }
  return result;
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
    log.info('sync', 'Indulás: $_pending függő művelet');
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      log.info('net', 'Hálózat: ${results.map((r) => r.name).join(', ')}');
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
    // A sorrend utanként kötelező (jegyzőkönyv → indítás → jegyzőkönyv →
    // lezárás): egy út első el nem végzett művelete (ütközés, hiba vagy
    // még le nem telt backoff) az út összes későbbi műveletét visszatartja.
    // Más utak műveleteit viszont nem — azok függetlenek.
    final blocked = <String>{};
    final operations = await local.pendingOperations();
    if (operations.isNotEmpty) log.info('sync', 'Szinkron kör: ${operations.length} függő művelet');
    for (final operation in operations) {
      final leg = operation.legKey ?? operation.entityId;
      final what = '${operation.operationType} ${operation.entityId} (út $leg, ${operation.attempts}. próba)';
      if (blocked.contains(leg)) continue;
      if (operation.state == 'CONFLICT' || !_isDue(operation)) {
        if (operation.state == 'CONFLICT') log.warn('sync', 'Ütközés miatt vár: $what', operation.lastError);
        blocked.add(leg);
        continue;
      }
      log.info('sync', 'Indul: $what');
      await local.operationRunning(operation.id);
      await refreshCount();
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
          case 'UPDATE_VEHICLE':
            final changes = Map<String, dynamic>.from(jsonDecode(operation.payload ?? '{}') as Map);
            await api.updateLegVehicle(operation.entityId, {for (final e in changes.entries) e.key: e.value?.toString()});
            break;
          case 'CREATE_ORDER':
            final created = await api.createOrder(Map<String, dynamic>.from(jsonDecode(operation.payload ?? '{}') as Map));
            final realKey = '${created['legKey']}';
            await local.remapLegKey(operation.entityId, realKey, orderNo: '${created['orderNo']}');
            log.info('sync', 'Új fuvar létrehozva a szerveren: ${created['orderNo']} (út $realKey)');
            // Az út többi művelete még a régi azonosítót ismeri ebben a körben:
            // a következő kör már a szerverével viszi tovább.
            blocked.add(leg);
            _again = true;
            break;
          default:
            throw StateError('Ismeretlen sync művelet: ${operation.operationType}');
        }
        await local.operationDone(operation.id);
        log.info('sync', 'Kész: $what');
      } on ApiException catch (e) {
        blocked.add(leg);
        log.warn('sync', '${e.isConflict ? 'Ütközés' : 'Hiba'}: $what — HTTP ${e.statusCode}', e.message);
        await local.operationError(operation.id, e.message, conflict: e.isConflict);
        if (e.statusCode == 0) break; // no network: keep the remaining queue untouched
      } catch (e, stack) {
        blocked.add(leg);
        log.error('sync', 'Hiba: $what', e, stack);
        await local.operationError(operation.id, e.toString());
      } finally {
        await refreshCount();
      }
    }
  }

  /// A szerver oldali indítás/lezárás idempotens (a már célállapotban lévő
  /// útra sem dob ütközést), így itt elég a hívás után a lokális státuszt
  /// a szerveréhez igazítani.
  Future<void> _legTransition(String legKey, String target, Future<void> Function() call) async {
    await call();
    await local.updateLegStatus(legKey, target);
  }

  bool _isDue(SyncOperation operation) => syncOperationDue(operation, DateTime.now().toUtc());

  Future<void> _syncInspection(String localId) async {
    final draft = await local.inspection(localId);
    if (draft == null) throw StateError('Hiányzó lokális jegyzőkönyv: $localId');
    if (draft.status == 'SYNCED') return;
    try {
      await _uploadInspection(localId);
    } on ApiException catch (e) {
      if (!isInspectionClosed(e)) rethrow;
      // A szerveren már lezárt (pl. a lezárás válasza elveszett). Ez csak akkor
      // jelenti, hogy minden fent van, ha a telefonon nem maradt feltöltetlen
      // elem — különben ütközés, amit a sofőrnek látnia kell.
      final left = await local.unsyncedItemCount(localId);
      if (left > 0) {
        throw ApiException(409, 'A jegyzőkönyv a szerveren már lezárt, de $left elem nem került fel.', body: e.body);
      }
    }
    await local.markInspectionSynced(localId);
  }

  /// Lokális forrásból másolt jegyzőkönyv: a szerver a forrás szerveroldali
  /// példányából másol. A forrás az autó közvetlenül előző jegyzőkönyve; ha az
  /// egy másik úté és még nincs fent, ez a művelet hibával visszalép, és a
  /// következő körben (a forrás feltöltése után) megy tovább.
  Future<String?> _copySource(LocalInspectionDraft draft) async {
    if (draft.copyFromServerId != null) return draft.copyFromServerId;
    final sourceId = draft.copyFromLocalId;
    if (sourceId == null) return null;
    final source = await local.inspection(sourceId);
    if (source == null) throw StateError('A másolás forrása nem található a készüléken.');
    if (source.status != 'SYNCED' || source.serverId == null) {
      throw StateError('A másolás forrása még nincs feltöltve a szerverre.');
    }
    return source.serverId;
  }

  Future<void> _uploadInspection(String localId) async {
    var draft = await local.inspection(localId);
    if (draft == null) throw StateError('Hiányzó lokális jegyzőkönyv: $localId');

    var serverId = draft.serverId;
    log.info('sync', 'Jegyzőkönyv feltöltése: ${draft.inspectionType} $localId, út ${draft.legKey}${serverId == null ? '' : ', szerver $serverId'}');
    if (serverId == null) {
      serverId = await api.createInspection(
        legKey: draft.legKey,
        formTypeId: draft.formTypeId,
        inspectionType: draft.inspectionType,
        deviceOperationId: draft.localId,
        copyFromInspectionId: await _copySource(draft),
      );
      await local.markInspectionServerId(localId, serverId);
      log.info('sync', 'Jegyzőkönyv létrehozva a szerveren: $serverId');
      draft = (await local.inspection(localId))!;
    }

    await api.saveValues(serverId, inspectionValuesPayload(
      await local.inspectionValues(localId),
      await local.phaseFieldIds(draft.formTypeId, draft.inspectionType),
    ), generalNote: draft.generalNote);

    var damages = await local.damages(localId);
    for (final damage in damages.where((d) => !d.baseline && d.serverId == null)) {
      final id = await api.addDamage(serverId, {
        if (damage.damageType != null) 'damageType': damage.damageType,
        if (damage.location != null) 'location': damage.location,
        'description': damage.description,
        if (damage.severity != null) 'severity': damage.severity,
        if (damage.isPreexisting != null) 'isPreexisting': damage.isPreexisting,
        'deviceOperationId': damage.localId,
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
      var storageKey = photo.storageKey;
      final presign = await api.presign(serverId, p.basename(file.path), contentType,
          kind: photo.damageLocalId == null ? 'PHOTO' : 'DAMAGE', storageKey: storageKey);
      if (storageKey == null) {
        storageKey = '${presign['storageKey']}';
        await local.reservePhotoKey(photo.localId, storageKey);
      }
      await api.uploadToPresignedUrl('${presign['uploadUrl']}', file, contentType);
      final damageId = photo.damageLocalId == null ? null : damageServerIds[photo.damageLocalId];
      final photoId = await api.addPhoto(serverId, {
        if (damageId != null) 'damageId': damageId,
        'storageKey': storageKey,
        'photoType': photo.photoType,
        'capturedAt': photo.capturedAt.toUtc().toIso8601String(),
      });
      await local.updatePhotoUpload(photo.localId, serverId: photoId, storageKey: storageKey);
      log.info('sync', 'Fotó feltöltve: ${photo.photoType}${photo.damageLocalId == null ? '' : ' (sérülés)'} → $photoId');
    }

    for (final signature in (await local.signatures(localId)).where((s) => s.serverId == null)) {
      final file = File(signature.localPath);
      if (!await file.exists()) throw StateError('Aláírásfájl nem található');
      var storageKey = signature.storageKey;
      final presign = await api.presign(serverId, p.basename(file.path), 'image/png', kind: 'SIGNATURE', storageKey: storageKey);
      if (storageKey == null) {
        storageKey = '${presign['storageKey']}';
        await local.reserveSignatureKey(signature.localId, storageKey);
      }
      await api.uploadToPresignedUrl('${presign['uploadUrl']}', file, 'image/png');
      final signatureId = await api.addSignature(serverId, {
        'signerName': signature.signerName,
        if (signature.signerRole != null) 'signerRole': signature.signerRole,
        'storageKey': storageKey,
        'signedAt': signature.signedAt.toUtc().toIso8601String(),
      });
      await local.updateSignatureUpload(signature.localId, serverId: signatureId, storageKey: storageKey);
      log.info('sync', 'Aláírás feltöltve → $signatureId');
    }

    // Hol volt a telefon a lezáráskor: a pont nélküli megálló innen kap térképi pontot.
    await api.completeInspection(serverId, position: await local.inspectionCompletionPosition(localId));
    log.info('sync', 'Jegyzőkönyv lezárva a szerveren: $serverId');
  }

  Future<void> retry(String operationId) async {
    log.info('sync', 'Kézi újrapróbálás: $operationId');
    await local.retryOperation(operationId);
    await run();
  }
}
