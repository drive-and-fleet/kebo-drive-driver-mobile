import 'dart:async';

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

  /// A sofőr teljesített fuvarai az elmúlt [days] napból, a legújabb elöl.
  /// Local-first: ami a szerverről jön, a helyi tárba kerül, így a fuvar
  /// adatlapja offline is megnyitható; hálózat nélkül a telefonon már meglévő
  /// teljesített fuvarok látszanak (`fromServer: false`).
  Future<({List<DriverLeg> legs, bool fromServer})> completedWork(int days) async {
    var fromServer = true;
    try {
      await local.cacheLegs(await api.completedLegs(days: days));
    } catch (_) {
      fromServer = false;
    }
    final since = DateTime.now().subtract(Duration(days: days));
    final legs = (await local.cachedLegs())
        .where((leg) => leg.status == 'COMPLETED' || leg.status == 'COMPLETED_PENDING_SYNC')
        .where((leg) => leg.plannedStart == null || leg.plannedStart!.isAfter(since))
        .toList()
      ..sort((a, b) => (b.plannedStart ?? DateTime(0)).compareTo(a.plannedStart ?? DateTime(0)));
    return (legs: legs, fromServer: fromServer);
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

  /// Local-first: a lezárás és az ebből következő fuvar-indítás/-lezárás egy
  /// lokális tranzakció, a hálózat nincs a kritikus úton. A szinkron a
  /// háttérben indul; az állapotát a SyncService jelzi a felületnek.
  /// Visszaadja a szakasz új lokális státuszát.
  Future<String?> finalizeInspection(LocalInspectionDraft draft, FormTypeConfig form) async {
    final result = await InspectionValidator(local).validate(draft, form);
    if (!result.valid) throw StateError(result.errors.join('\n'));
    final status = await local.completeInspectionAndTransition(draft.localId);
    unawaited(sync.run());
    return status;
  }

  /// Csak akkor kell, ha az átvételi jegyzőkönyv már lezárt, de a fuvar még
  /// nem indult el (egy korábbi appverzió után maradt állapot).
  Future<void> startLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'PICKUP');
    unawaited(sync.run());
  }

  Future<void> completeLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'DROPOFF');
    unawaited(sync.run());
  }
}
