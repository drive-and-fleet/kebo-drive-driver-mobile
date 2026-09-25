import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../api/driver_api.dart';
import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../models/local_models.dart';
import '../models/models.dart';
import 'inspection_validator.dart';
import 'sync_service.dart';

/// A sofőr munkái. Local-first: a lista mindig a telefonról jön; a szerverről
/// letöltött állapot a helyi tárba kerül, és ami már nem a sofőré (lemondták,
/// visszavették, átadták), az onnan eltűnik.
///
/// Automatikus frissítés, akkumulátorkímélően: csak amíg az app előtérben van,
/// [_autoInterval]-onként, valamint amikor az app újra előtérbe kerül, és amikor
/// visszajön a hálózat — de legfeljebb [_minGap]-enként, és egyetlen kis kéréssel
/// (űrlapot és előzményt csak az újonnan kapott szakaszokhoz tölt le).
class WorkService extends ChangeNotifier {
  WorkService(this.api, this.local, this.sync);
  final DriverApi api;
  final LocalRepository local;
  final SyncService sync;

  static const _autoInterval = Duration(minutes: 5);
  static const _minGap = Duration(minutes: 1);

  bool Function() _active = () => false;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  DateTime? _lastRefresh;
  Future<void>? _inFlight;

  /// [active]: be van-e jelentkezve a sofőr (enélkül nincs mit letölteni).
  void startAutoRefresh(bool Function() active) {
    _active = active;
    _connectivity ??= Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) unawaited(_auto('hálózat visszajött'));
    });
    onForeground();
  }

  /// Előtérben: azonnal egy (korlátozott) frissítés, utána időzítve.
  void onForeground() {
    _timer?.cancel();
    _timer = Timer.periodic(_autoInterval, (_) => unawaited(_auto('időzített')));
    unawaited(_auto('előtérbe került'));
  }

  /// Háttérben nincs időzítő: nem fogyaszt akkumulátort.
  void onBackground() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> stopAutoRefresh() async {
    onBackground();
    await _connectivity?.cancel();
    _connectivity = null;
  }

  Future<void> _auto(String why) async {
    if (!_active() || _timer == null) return;
    final last = _lastRefresh;
    if (last != null && DateTime.now().difference(last) < _minGap) return;
    try {
      await _refreshFromServer(full: false, why: why);
    } catch (e) {
      log.debug('work', 'Automatikus frissítés most nem sikerült ($why): $e');
    }
  }

  /// Egyszerre csak egy letöltés fut; a második hívó megvárja az elsőt.
  Future<void> _refreshFromServer({required bool full, required String why}) {
    return _inFlight ??= _download(full: full, why: why).whenComplete(() => _inFlight = null);
  }

  Future<void> _download({required bool full, required String why}) async {
    final fetchedAt = DateTime.now();
    final known = await local.cachedLegKeys();
    final online = await api.assigned();
    _lastRefresh = DateTime.now();
    await local.cacheLegs(online);
    final result = await local.reconcileAssigned({for (final leg in online) leg.legKey}, fetchedAt);
    final fresh = online.where((leg) => !known.contains(leg.legKey)).toList();
    log.info('work', 'Munkák letöltve ($why): ${online.length} szakasz, új: ${fresh.length}, '
        'eltűnt: ${result.removed.length}${result.revoked.isEmpty ? '' : ', már nem a sofőré, de helyi munka van rajta: ${result.revoked.join(', ')}'}');
    if (result.removed.isNotEmpty) log.info('work', 'A telefonról törölve (lemondva / visszavéve / átadva): ${result.removed.join(', ')}');

    // Űrlap és másolási előzmény: kézi frissítéskor mindenhez, automatikusan
    // csak ahhoz, ami új a telefonon (vagy aminek a szolgáltatójához nincs űrlap).
    final targets = full ? online : fresh;
    for (final serviceId in targets.map((e) => e.serviceOrgId).toSet()) {
      if (!full && await local.hasForms(serviceId)) continue;
      await local.cacheForms(serviceId, await api.forms(serviceId));
    }
    for (final leg in targets) {
      try {
        await local.cachePreviousInspections(leg.legKey, await api.previousInspections(leg.legKey));
      } catch (e) {
        log.warn('work', 'Előző jegyzőkönyvek nem jöttek le: ${leg.legKey}', e);
      }
    }
    notifyListeners();
  }

  Future<List<DriverLeg>> myWork({bool refreshOnline = true}) async {
    if (refreshOnline) {
      try {
        await _refreshFromServer(full: true, why: 'kézi');
      } catch (e) {
        // Offline is a normal operating mode. Return the local work package.
        log.warn('work', 'Munkák frissítése nem sikerült, a telefonon tárolt munka látszik', e);
      }
    }
    final legs = await local.cachedLegs();
    log.debug('work', 'Munkáim: ${legs.length} szakasz a telefonon');
    return legs;
  }

  /// A sofőr teljesített fuvarai az elmúlt [days] napból, a legújabb elöl.
  /// Local-first: ami a szerverről jön, a helyi tárba kerül, így a fuvar
  /// adatlapja offline is megnyitható; hálózat nélkül a telefonon már meglévő
  /// teljesített fuvarok látszanak (`fromServer: false`).
  Future<({List<DriverLeg> legs, bool fromServer})> completedWork(int days) async {
    var fromServer = true;
    try {
      final completed = await api.completedLegs(days: days);
      await local.cacheLegs(completed);
      log.info('work', 'Teljesített fuvarok ($days nap): ${completed.length}');
    } catch (e) {
      fromServer = false;
      log.warn('work', 'Teljesített fuvarok a szerverről nem jöttek le ($days nap)', e);
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
    log.info('work', 'Fuvar felvétele: ${leg.legKey} (${leg.orderNo} #${leg.sequenceNo}, ${leg.registrationNumber})');
    // Download config and copy-source data first. A successful claim must leave the
    // device with everything needed to continue offline.
    final forms = await api.forms(leg.serviceOrgId);
    if (forms.isEmpty) throw StateError('Nincs aktív űrlap konfigurálva ehhez a sofőrszolgálathoz.');
    await local.cacheForms(leg.serviceOrgId, forms);
    final previous = await api.previousInspections(leg.legKey);
    await local.cachePreviousInspections(leg.legKey, previous);

    await api.claim(leg.legKey);
    await local.cacheLegs([leg.copyWithStatus('ASSIGNED')]);
    log.info('work', 'Fuvar felvéve és letöltve: ${leg.legKey}');
  }

  Future<List<FormTypeConfig>> formsFor(DriverLeg leg) => local.forms(leg.serviceOrgId);

  Future<LocalInspectionDraft> openInspection({
    required DriverLeg leg,
    required String phase,
    required String formTypeId,
    String? copyFromServerId,
    String? copyFromLocalId,
  }) async {
    final copy = copyFromServerId != null ? 'szerver $copyFromServerId' : copyFromLocalId != null ? 'helyi $copyFromLocalId' : 'nincs';
    final draft = await local.createOrResumeInspection(
      legKey: leg.legKey,
      formTypeId: formTypeId,
      phase: phase,
      copyFromServerId: copyFromServerId,
      copyFromLocalId: copyFromLocalId,
    );
    log.info('insp', 'Jegyzőkönyv megnyitva: $phase ${draft.localId}, szakasz ${leg.legKey}, form $formTypeId, másolás: $copy');
    return draft;
  }

  /// Local-first: a lezárás és az ebből következő fuvar-indítás/-lezárás egy
  /// lokális tranzakció, a hálózat nincs a kritikus úton. A szinkron a
  /// háttérben indul; az állapotát a SyncService jelzi a felületnek.
  /// Visszaadja a szakasz új lokális státuszát.
  Future<String?> finalizeInspection(LocalInspectionDraft draft, FormTypeConfig form) async {
    final result = await InspectionValidator(local).validate(draft, form);
    if (!result.valid) {
      log.warn('insp', 'Lezárás elutasítva: ${draft.inspectionType} ${draft.localId}', result.errors.join('; '));
      throw StateError(result.errors.join('\n'));
    }
    final status = await local.completeInspectionAndTransition(draft.localId);
    log.info('insp', 'Jegyzőkönyv lezárva a telefonon: ${draft.inspectionType} ${draft.localId}, szakasz ${draft.legKey} → $status');
    unawaited(sync.run());
    return status;
  }

  /// Csak akkor kell, ha az átvételi jegyzőkönyv már lezárt, de a fuvar még
  /// nem indult el (egy korábbi appverzió után maradt állapot).
  Future<void> startLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'PICKUP');
    log.info('work', 'Fuvar indítása (utólag): ${leg.legKey}');
    unawaited(sync.run());
  }

  Future<void> completeLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'DROPOFF');
    log.info('work', 'Fuvar lezárása (utólag): ${leg.legKey}');
    unawaited(sync.run());
  }
}
