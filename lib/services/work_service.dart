import '../api/driver_api.dart';
import '../local/local_repository.dart';
import '../models/local_models.dart';
import '../models/models.dart';
import 'inspection_validator.dart';
import 'sync_service.dart';

class WorkService {
  WorkService(this.api, this.local, this.sync);
  final DriverApi api;
  final LocalRepository local;
  final SyncService sync;

  Future<List<DriverLeg>> myWork({bool refreshOnline = true}) async {
    if (refreshOnline) {
      try {
        final online = await api.assigned();
        await local.cacheLegs(online);
        final serviceIds = online.map((e) => e.serviceOrgId).toSet();
        for (final serviceId in serviceIds) {
          final forms = await api.forms(serviceId);
          await local.cacheForms(serviceId, forms);
        }
        for (final leg in online) {
          try {
            await local.cachePreviousInspections(leg.legKey, await api.previousInspections(leg.legKey));
          } catch (_) {}
        }
      } catch (_) {
        // Offline is a normal operating mode. Return the local work package.
      }
    }
    return local.cachedLegs();
  }

  /// `plate` nélkül a szabad fuvarok teljes böngészhető listáját adja vissza.
  Future<List<DriverLeg>> availableLegs({String? plate}) => api.availableLegs(plate: plate);

  Future<void> claimAndDownload(DriverLeg leg) async {
    // Download config and copy-source data first. A successful claim must leave the
    // device with everything needed to continue offline.
    final forms = await api.forms(leg.serviceOrgId);
    if (forms.isEmpty) throw StateError('Nincs aktív űrlap konfigurálva ehhez a sofőrszolgálathoz.');
    await local.cacheForms(leg.serviceOrgId, forms);
    final previous = await api.previousInspections(leg.legKey);
    await local.cachePreviousInspections(leg.legKey, previous);

    await api.claim(leg.legKey);
    await local.cacheLegs([leg.copyWithStatus('ASSIGNED')]);
  }

  Future<List<FormTypeConfig>> formsFor(DriverLeg leg) => local.forms(leg.serviceOrgId);

  Future<LocalInspectionDraft> openInspection({
    required DriverLeg leg,
    required String phase,
    required String formTypeId,
    String? copyFromServerId,
    String? copyFromLocalId,
  }) =>
      local.createOrResumeInspection(
        legKey: leg.legKey,
        formTypeId: formTypeId,
        phase: phase,
        copyFromServerId: copyFromServerId,
        copyFromLocalId: copyFromLocalId,
      );

  Future<void> finalizeInspection(LocalInspectionDraft draft, FormTypeConfig form) async {
    final result = await InspectionValidator(local).validate(draft, form);
    if (!result.valid) throw StateError(result.errors.join('\n'));
    await local.markInspectionLocalComplete(draft.localId);
    await sync.run();
  }

  Future<void> startLeg(DriverLeg leg) async {
    final pickup = await local.inspectionForLeg(leg.legKey, 'PICKUP');
    if (pickup == null || !['COMPLETED_LOCAL', 'SYNCED'].contains(pickup.status)) {
      throw StateError('A fuvar indításához előbb zárd le az átvételi jegyzőkönyvet.');
    }
    await local.updateLegStatus(leg.legKey, 'IN_PROGRESS');
    await local.enqueue('START_LEG', leg.legKey);
    await sync.run();
  }

  Future<void> completeLeg(DriverLeg leg) async {
    final dropoff = await local.inspectionForLeg(leg.legKey, 'DROPOFF');
    if (dropoff == null || !['COMPLETED_LOCAL', 'SYNCED'].contains(dropoff.status)) {
      throw StateError('A fuvar lezárásához előbb zárd le a leadási jegyzőkönyvet.');
    }
    await local.updateLegStatus(leg.legKey, 'COMPLETED_PENDING_SYNC');
    await local.enqueue('COMPLETE_LEG', leg.legKey);
    await sync.run();
  }
}
