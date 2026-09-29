import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../api/driver_api.dart';
import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../models/local_models.dart';
import '../models/models.dart';
import '../models/trip_rules.dart';
import 'inspection_validator.dart';
import 'sync_service.dart';

/// A sofőr munkái. Local-first: a lista mindig a telefonról jön; a szerverről
/// letöltött állapot a helyi tárba kerül, és ami már nem a sofőré (lemondták,
/// visszavették, átadták), az onnan eltűnik.
///
/// Automatikus frissítés, akkumulátorkímélően: csak amíg az app előtérben van,
/// [_autoInterval]-onként, valamint amikor az app újra előtérbe kerül, és amikor
/// visszajön a hálózat — de legfeljebb [_minGap]-enként, és egyetlen kis kéréssel
/// (űrlapot és előzményt csak az újonnan kapott utakhoz tölt le).
class WorkService extends ChangeNotifier {
  WorkService(this.api, this.local, this.sync);
  final DriverApi api;
  final LocalRepository local;
  final SyncService sync;

  /// A helyzetmegosztás adja: hol van most a telefon (a jegyzőkönyv lezárásakor mentjük).
  Future<({double latitude, double longitude, double? accuracy})?> Function()? positionProvider;

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
    log.info('work', 'Munkák letöltve ($why): ${online.length} út, új: ${fresh.length}, '
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
    log.debug('work', 'Munkáim: ${legs.length} út a telefonon');
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

  /// A sofőr javítja az út autójának adatait (rendszám, használó e-mail, további cím).
  /// Azonnal a telefonon, a szerverre a szinkron viszi (csak a módosított mezőket).
  Future<bool> updateLegVehicle(DriverLeg leg,
      {String? registrationNumber, String? userEmail, String? extraEmail, String? make, String? model, String? color, String? userName, String? userPhone}) async {
    final changed = await local.updateLegVehicle(leg.legKey,
        registrationNumber: registrationNumber, userEmail: userEmail, extraEmail: extraEmail,
        make: make, model: model, color: color, userName: userName, userPhone: userPhone);
    if (changed) {
      log.info('work', 'Autó adatai módosítva a telefonon: ${leg.legKey} (szinkronra vár)');
      notifyListeners();
      unawaited(sync.run());
    }
    return changed;
  }

  /// Új fuvar a telefonon: azonnal a Munkáim között, a szinkron hozza létre a szerveren.
  Future<String> createOrder(Map<String, dynamic> payload, {required String fleetName}) async {
    final legKey = await local.createLocalOrder(payload, fleetName: fleetName);
    log.info('work', 'Új fuvar a telefonon: $legKey (${payload['registrationNumber']}, $fleetName) — szinkronra vár');
    notifyListeners();
    unawaited(sync.run());
    // A jegyzőkönyvhöz kell a szolgálat űrlapja: ha még nincs a telefonon, most letöltjük (hálózattal).
    final serviceId = '${payload['serviceOrgId']}';
    unawaited(() async {
      try {
        if (!await local.hasForms(serviceId)) await local.cacheForms(serviceId, await api.forms(serviceId));
      } catch (e) {
        log.warn('work', 'Az űrlap letöltése most nem sikerült ($serviceId)', e);
      }
    }());
    return legKey;
  }

  /// A sofőr szolgálatai: hálózattal frissen, offline a legutóbb letöltött lista.
  Future<List<Map<String, String>>> myServices() async {
    try {
      await local.cacheServices(await api.myServices());
    } catch (e) {
      log.warn('work', 'A szolgálatok listája nem frissült, a telefonon tárolt látszik', e);
    }
    return local.services();
  }

  /// A szolgálat flottakezelő partnerei: hálózattal frissen, offline a tárolt lista.
  Future<List<Map<String, String>>> fleets(String serviceOrgId) async {
    try {
      await local.cacheFleets(serviceOrgId, await api.fleets(serviceOrgId));
    } catch (e) {
      log.warn('work', 'A partnerek listája nem frissült, a telefonon tárolt látszik', e);
    }
    return local.fleets(serviceOrgId);
  }

  /// Amit a szolgálat gépjármű-nyilvántartása tud a rendszámról (csak hálózattal; különben null).
  Future<Map<String, dynamic>?> lookupVehicle(String serviceOrgId, String plate) async {
    try {
      return await api.lookupVehicle(serviceOrgId, plate);
    } catch (_) {
      return null;
    }
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

  /// „Leadom ezt a fuvart”: csak hálózattal (a szerver dönt, hogy még leadható-e).
  /// Utána a telefonról is lekerül, a Munkáim frissül.
  Future<void> releaseLeg(DriverLeg leg, {String? reason}) async {
    log.info('work', 'Fuvar leadása: ${leg.legKey} (${leg.orderNo} #${leg.sequenceNo})${reason == null || reason.trim().isEmpty ? '' : ', indokkal'}');
    final draft = await local.inspectionForLeg(leg.legKey, 'PICKUP');
    if (draft != null && draft.status != 'DRAFT') {
      throw StateError('Ehhez az úthoz már van lezárt jegyzőkönyv, ezért nem adható le: szólj az irodának.');
    }
    // A telefonon felvett, még fel nem küldött fuvar: nincs kinek leadni, a telefonról törlődik.
    if (LocalRepository.isLocalLeg(leg.legKey)) {
      if (draft != null) await _discardDraft(draft.localId);
      await local.discardLocalOrder(leg.legKey);
      log.info('work', 'Még fel nem küldött fuvar törölve a telefonról: ${leg.legKey}');
      notifyListeners();
      unawaited(sync.refreshCount());
      return;
    }
    await api.release(leg.legKey, reason: reason);
    // Csak a sikeres leadás után: az elkezdett, még fel nem küldött jegyzőkönyv törlődik
    // (a fotóival, aláírásával együtt); aki a fuvart legközelebb viszi, újrakezdi.
    if (draft != null) await _discardDraft(draft.localId);
    try {
      await _refreshFromServer(full: false, why: 'leadás');
    } catch (e) {
      log.warn('work', 'A leadás után a munkalista most nem frissült', e);
    }
    notifyListeners();
  }

  Future<void> _discardDraft(String localId) async {
    for (final path in await local.discardDraft(localId)) {
      try {
        await File(path).delete();
      } catch (_) {
        // A fájl már nincs meg: nincs teendő.
      }
    }
    log.info('work', 'Leadás: az elkezdett jegyzőkönyv törölve a telefonról ($localId)');
  }

  /// A szolgálat nyitott útjai (csak hálózattal): ki viszi, felvehető / átvehető-e.
  Future<List<OpenLeg>> openLegs() => api.openLegs();

  /// „Átveszem”: mint a felvételnél, előbb minden letöltődik, ami offline kell,
  /// utána az átvétel; a Munkáim frissül.
  Future<void> takeOverAndDownload(DriverLeg leg) async {
    log.info('work', 'Fuvar átvétele másik sofőrtől: ${leg.legKey} (${leg.orderNo} #${leg.sequenceNo}, ${leg.registrationNumber})');
    final forms = await api.forms(leg.serviceOrgId);
    if (forms.isEmpty) throw StateError('Nincs aktív űrlap konfigurálva ehhez a sofőrszolgálathoz.');
    await local.cacheForms(leg.serviceOrgId, forms);
    await local.cachePreviousInspections(leg.legKey, await api.previousInspections(leg.legKey));
    await api.takeOver(leg.legKey);
    await local.cacheLegs([leg.copyWithStatus('ASSIGNED')]);
    try {
      await _refreshFromServer(full: false, why: 'átvétel');
    } catch (e) {
      log.warn('work', 'Az átvétel után a munkalista most nem frissült', e);
    }
    notifyListeners();
    log.info('work', 'Fuvar átvéve és letöltve: ${leg.legKey}');
  }

  /// A szolgálat jegyzőkönyv-típusa(i). Új jegyzőkönyvhöz csak az aktív ([activeOnly]);
  /// egy már megkezdett folytatásához a saját (akár azóta inaktivált) típusa is.
  Future<List<FormTypeConfig>> formsFor(DriverLeg leg, {bool activeOnly = false}) => local.forms(leg.serviceOrgId, activeOnly: activeOnly);

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
    log.info('insp', 'Jegyzőkönyv megnyitva: $phase ${draft.localId}, út ${leg.legKey}, form $formTypeId, másolás: $copy');
    return draft;
  }

  /// Local-first: a lezárás és az ebből következő fuvar-indítás/-lezárás egy
  /// lokális tranzakció, a hálózat nincs a kritikus úton. A szinkron a
  /// háttérben indul; az állapotát a SyncService jelzi a felületnek.
  /// Visszaadja az út új lokális státuszát.
  /// Miért nem vehető most át az autó (null: átvehető). Egyszerre csak egy autó
  /// lehet a sofőrnél, és későbbi napra tervezett út ma még nem indítható.
  Future<({String message, DriverLeg? running, bool laterDay})?> startBlocker(DriverLeg leg) async {
    final running = runningLeg(await local.cachedLegs(), except: leg.legKey);
    if (running != null) {
      return (
        message: 'Egyszerre csak egy autót vihetsz. Előbb add le ezt: ${running.registrationNumber} (${running.toPlace}).',
        running: running,
        laterDay: false,
      );
    }
    if (plannedForLaterDay(leg.plannedStart, DateTime.now())) {
      final t = leg.plannedStart!.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      return (
        message: 'Ez a fuvar ${t.year}.${two(t.month)}.${two(t.day)}. ${two(t.hour)}:${two(t.minute)} időpontra van tervezve, ma még nem veheted át.',
        running: null,
        laterDay: true,
      );
    }
    return null;
  }

  /// A felvétel új időpontja: azonnal a telefonon, a szinkron viszi fel (naplózva).
  Future<void> rescheduleLeg(DriverLeg leg, DateTime plannedStart, {String? reason}) async {
    await local.rescheduleLeg(leg.legKey, plannedStart, reason: reason);
    log.info('work', 'Felvétel időpontja módosítva a telefonon: ${leg.legKey} → ${plannedStart.toIso8601String()} (szinkronra vár)');
    notifyListeners();
    unawaited(sync.run());
  }

  /// [onStep] a képernyőnek mondja, hol tart a lezárás (a sofőr lássa, hogy halad).
  Future<String?> finalizeInspection(LocalInspectionDraft draft, FormTypeConfig form, {void Function(String step)? onStep}) async {
    onStep?.call('Adatok ellenőrzése…');
    if (draft.inspectionType == 'PICKUP') {
      // Az átvétel lezárása indítja az utat: itt is érvényes a tiltás (közben változhatott).
      final leg = await local.cachedLeg(LocalRepository.currentLegKey(draft.legKey));
      final blocker = leg == null ? null : await startBlocker(leg);
      if (blocker != null) throw StateError(blocker.message);
    }
    final result = await InspectionValidator(local).validate(draft, form);
    if (!result.valid) {
      log.warn('insp', 'Lezárás elutasítva: ${draft.inspectionType} ${draft.localId}', result.errors.join('; '));
      throw StateError(result.errors.join('\n'));
    }
    // Hol volt a telefon a lezáráskor (ha van helyengedély): a szerver ebből pótolja a pont nélküli megállót.
    onStep?.call('Helyzet rögzítése…');
    final fix = await positionProvider?.call();
    if (fix != null) {
      await local.setInspectionCompletionPosition(draft.localId, latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.accuracy);
    }
    onStep?.call('Mentés a telefonra…');
    final status = await local.completeInspectionAndTransition(draft.localId);
    log.info('insp', 'Jegyzőkönyv lezárva a telefonon: ${draft.inspectionType} ${draft.localId}, út ${draft.legKey} → $status');
    unawaited(sync.run());
    notifyListeners();
    return status;
  }

  /// A lezárt jegyzőkönyv javítása: azonnal a telefonon, a szinkron viszi fel.
  Future<void> correctInspection(LocalInspectionDraft draft, Map<String, ({Map<String, dynamic> value, List<String> optionIds})> changes,
      {String? generalNote, String? reason}) async {
    await local.correctInspection(draft.localId, changes, generalNote: generalNote, reason: reason);
    log.info('insp', 'Jegyzőkönyv javítva a telefonon: ${draft.inspectionType} ${draft.localId} (${changes.length} mező), szinkronra vár');
    notifyListeners();
    unawaited(sync.run());
  }

  /// Csak akkor kell, ha az átvételi jegyzőkönyv már lezárt, de a fuvar még
  /// nem indult el (egy korábbi appverzió után maradt állapot).
  Future<void> startLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'PICKUP');
    log.info('work', 'Fuvar indítása (utólag): ${leg.legKey}');
    unawaited(sync.run());
    notifyListeners();
  }

  Future<void> completeLeg(DriverLeg leg) async {
    await local.transitionLegAfterInspection(leg.legKey, 'DROPOFF');
    log.info('work', 'Fuvar lezárása (utólag): ${leg.legKey}');
    unawaited(sync.run());
    notifyListeners();
  }
}
