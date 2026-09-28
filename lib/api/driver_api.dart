import 'dart:io';

import '../auth/auth_service.dart';
import '../models/models.dart';
import 'http_api.dart';

class DriverApi {
  DriverApi(this._http, this._auth);
  final HttpApi _http;
  final AuthService _auth;

  Future<String> _token() => _auth.validPlatformToken();

  Future<List<DriverLeg>> assigned() async {
    final raw = await _http.get('/api/v1/driver/legs', token: await _token()) as List<dynamic>;
    return raw.map((e) => DriverLeg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// A sofőr által teljesített utak az elmúlt [days] napból, a legújabb elöl.
  Future<List<DriverLeg>> completedLegs({int days = 90}) async {
    final raw = await _http.get('/api/v1/driver/legs/completed', token: await _token(), query: {'days': '$days'}) as List<dynamic>;
    return raw.map((e) => DriverLeg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// `plate` nélkül az összes felvehető fuvart adja vissza; a rendszám csak szűrő.
  Future<List<DriverLeg>> availableLegs({String? plate}) async {
    final raw = await _http.get(
      '/api/v1/driver/available-legs',
      token: await _token(),
      query: {if (plate != null && plate.trim().isNotEmpty) 'registrationNumber': plate},
    ) as List<dynamic>;
    return raw.map((e) => DriverLeg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// A szolgálat(ok) minden nyitott útja, azzal, hogy kinél van.
  Future<List<OpenLeg>> openLegs() async {
    final raw = await _http.get('/api/v1/driver/open-legs', token: await _token()) as List<dynamic>;
    return raw.map((e) => OpenLeg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// „Átveszem”: egy másik sofőr még el nem indított útja (ha a szolgálat engedi).
  Future<void> takeOver(String legKey) async {
    await _http.post('/api/v1/driver/legs/$legKey/take-over', token: await _token());
  }

  Future<List<dynamic>> forms(String serviceOrgId) async =>
      (await _http.get('/api/v1/driver/services/$serviceOrgId/forms', token: await _token())) as List<dynamic>;

  /// Hibajelentés a naplóval; a válasz a jelentés azonosítója.
  Future<String> submitBugReport(Map<String, dynamic> body) async {
    final result = await _http.post('/api/v1/driver/bug-reports', token: await _token(), body: body) as Map<String, dynamic>;
    return '${result['id']}';
  }

  /// Tevékenységnapló: a megnyitott képernyők egy csomagban (a szerver azonnal válaszol).
  Future<void> postActivity(List<Map<String, String>> entries, String? appVersion) async {
    await _http.post('/api/v1/driver/activity', token: await _token(), body: {
      'entries': entries,
      if (appVersion != null) 'appVersion': appVersion,
    });
  }

  /// Egy út lezárt jegyzőkönyvei, csak olvasásra (a teljesített út jegyzőkönyve már nincs a telefonon).
  Future<List<Map<String, dynamic>>> legInspections(String legKey) async =>
      ((await _http.get('/api/v1/driver/legs/$legKey/inspections', token: await _token())) as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Future<List<dynamic>> previousInspections(String legKey) async =>
      (await _http.get('/api/v1/driver/legs/$legKey/previous-inspections', token: await _token())) as List<dynamic>;

  Future<void> claim(String legKey) async {
    await _http.post('/api/v1/driver/legs/$legKey/claim', token: await _token());
  }

  /// A felvétel új időpontja (a szerver naplózza a régit és az újat, az indokkal).
  Future<void> rescheduleLeg(String legKey, Map<String, dynamic> payload) async {
    await _http.put('/api/v1/driver/legs/$legKey/planned-start', token: await _token(), body: payload);
  }

  /// Címjavaslatok gépelés közben (TomTom, Geoapify, tartalékként OpenStreetMap) – csak
  /// hálózattal. [geoapify]: volt-e Geoapify-találat (az ingyenes csomag kéri a nevét).
  Future<({List<String> labels, bool geoapify})> suggestAddresses(String query) async {
    final raw = (await _http.get('/api/v1/driver/geo/suggest', token: await _token(), query: {'q': query}) as List<dynamic>).cast<Map>();
    return (
      labels: raw.map((e) => '${e['label']}').where((label) => label.trim().isNotEmpty).toList(),
      geoapify: raw.any((e) => e['source'] == 'GEOAPIFY'),
    );
  }

  /// „Leadom”: a sofőr leveszi magáról a még el nem indított utat (az indok nem kötelező).
  Future<void> release(String legKey, {String? reason}) async {
    await _http.post('/api/v1/driver/legs/$legKey/release', token: await _token(), body: {
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    });
  }

  Future<void> start(String legKey) async {
    await _http.post('/api/v1/driver/legs/$legKey/start', token: await _token());
  }

  Future<void> complete(String legKey) async {
    await _http.post('/api/v1/driver/legs/$legKey/complete', token: await _token());
  }

  Future<List<Map<String, dynamic>>> serviceDrivers(String serviceOrgId, {String? query}) async {
    final raw = await _http.get(
      '/api/v1/driver/services/$serviceOrgId/drivers',
      token: await _token(),
      query: {'q': query},
    ) as List<dynamic>;
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> transfers() async {
    final raw = await _http.get('/api/v1/driver/transfers', token: await _token()) as List<dynamic>;
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> requestTransfer(String legKey, String toDriverId) async {
    await _http.post('/api/v1/driver/legs/$legKey/transfer', token: await _token(), body: {'toDriverId': toDriverId});
  }

  Future<void> approveTransfer(String id) async {
    await _http.post('/api/v1/driver/transfers/$id/approve', token: await _token());
  }

  Future<void> rejectTransfer(String id) async {
    await _http.post('/api/v1/driver/transfers/$id/reject', token: await _token());
  }

  Future<String> createInspection({
    required String legKey,
    required String formTypeId,
    required String inspectionType,
    required String deviceOperationId,
    String? copyFromInspectionId,
  }) async {
    final raw = await _http.post('/api/v1/driver/legs/$legKey/inspections', token: await _token(), body: {
      'formTypeId': formTypeId,
      'inspectionType': inspectionType,
      'deviceOperationId': deviceOperationId,
      if (copyFromInspectionId != null) 'copyFromInspectionId': copyFromInspectionId,
    }) as Map<String, dynamic>;
    return '${raw['id']}';
  }

  /// A mezőértékek és az általános megjegyzés ([generalNote]: null = nincs megjegyzés).
  Future<void> saveValues(String inspectionId, List<Map<String, dynamic>> values, {String? generalNote}) async {
    await _http.put('/api/v1/driver/inspections/$inspectionId/values', token: await _token(), body: {
      'values': values,
      'generalNote': generalNote,
    });
  }

  /// Az út autójának adatai, csak a sofőr által módosított mezők ([changes]:
  /// registrationNumber, userEmail, extraEmail; üres szöveg = törlés). Naplózva.
  Future<Map<String, dynamic>> updateLegVehicle(String legKey, Map<String, String?> changes) async {
    return Map<String, dynamic>.from(await _http.put('/api/v1/driver/legs/$legKey/vehicle', token: await _token(), body: {
      for (final entry in changes.entries) entry.key: entry.value ?? '',
    }) as Map);
  }

  /// A sofőrszolgálatok, amelyeknek a sofőr most tagja.
  Future<List<Map<String, dynamic>>> myServices() async {
    final raw = await _http.get('/api/v1/driver/my-services', token: await _token()) as List<dynamic>;
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// A sofőrszolgálat flottakezelő partnerei (új fuvarhoz).
  Future<List<Map<String, dynamic>>> fleets(String serviceOrgId) async {
    final raw = await _http.get('/api/v1/driver/services/$serviceOrgId/fleets', token: await _token()) as List<dynamic>;
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// A szolgálat gépjármű-nyilvántartása a rendszámról (null: nincs ilyen).
  Future<Map<String, dynamic>?> lookupVehicle(String serviceOrgId, String plate) async {
    final raw = await _http.get('/api/v1/driver/services/$serviceOrgId/vehicles/lookup', token: await _token(), query: {'plate': plate});
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  /// Új fuvar egy úttal a sofőrre (idempotens a `deviceOperationId` szerint).
  Future<Map<String, dynamic>> createOrder(Map<String, dynamic> payload) async {
    return Map<String, dynamic>.from(await _http.post('/api/v1/driver/orders', token: await _token(), body: payload) as Map);
  }

  Future<String> addDamage(String inspectionId, Map<String, dynamic> damage) async {
    final raw = await _http.post('/api/v1/driver/inspections/$inspectionId/damages', token: await _token(), body: damage) as Map<String, dynamic>;
    return '${raw['id']}';
  }

  /// [kind]: PHOTO | DAMAGE | SIGNATURE — ez dönti el az objektumtár almappáját.
  /// [storageKey]: retry-nál a korábban kiosztott kulcs, erre kér új URL-t.
  Future<Map<String, dynamic>> presign(String inspectionId, String objectName, String contentType,
      {String kind = 'PHOTO', String? storageKey}) async {
    return Map<String, dynamic>.from(await _http.post(
      '/api/v1/driver/inspections/$inspectionId/uploads/presign',
      token: await _token(),
      body: {
        'objectName': objectName,
        'contentType': contentType,
        'kind': kind,
        if (storageKey != null) 'storageKey': storageKey,
      },
    ) as Map);
  }

  Future<void> uploadToPresignedUrl(String url, File file, String contentType) async {
    await _http.putBytes(Uri.parse(url), await file.readAsBytes(), contentType);
  }

  Future<String> addPhoto(String inspectionId, Map<String, dynamic> photo) async {
    final raw = await _http.post('/api/v1/driver/inspections/$inspectionId/photos', token: await _token(), body: photo) as Map<String, dynamic>;
    return '${raw['id']}';
  }

  Future<String> addSignature(String inspectionId, Map<String, dynamic> signature) async {
    final raw = await _http.post('/api/v1/driver/inspections/$inspectionId/signatures', token: await _token(), body: signature) as Map<String, dynamic>;
    return '${raw['id']}';
  }

  /// [position]: hol volt a telefon a lezáráskor (latitude, longitude, accuracyM) – elhagyható.
  /// A lezárt jegyzőkönyv javítása: a szerver menti az előzményt, és újra kiküldi a levelet.
  Future<Map<String, dynamic>> correctInspection(String inspectionId, List<Map<String, dynamic>> values,
      {String? generalNote, String? reason, required String deviceOperationId}) async {
    return Map<String, dynamic>.from(await _http.post('/api/v1/driver/inspections/$inspectionId/corrections', token: await _token(), body: {
      'values': values,
      'generalNote': generalNote,
      if (reason != null) 'reason': reason,
      'deviceOperationId': deviceOperationId,
    }) as Map);
  }

  Future<void> completeInspection(String inspectionId, {Map<String, double>? position}) async {
    await _http.post('/api/v1/driver/inspections/$inspectionId/complete', token: await _token(), body: position ?? const <String, dynamic>{});
  }

  // ── push-értesítés és helyzetmegosztás ──

  Future<void> registerDevice(String token, {required String platform, String? appVersion}) async {
    await _http.post('/api/v1/driver/devices', token: await _token(), body: {'token': token, 'platform': platform, if (appVersion != null) 'appVersion': appVersion});
  }

  Future<void> unregisterDevice(String token) async {
    await _http.post('/api/v1/driver/devices/unregister', token: await _token(), body: {'token': token});
  }

  /// Megnyitották az appot: a jelvény számlálója nullázódik a szerveren is.
  Future<void> pushSeen() async {
    await _http.post('/api/v1/driver/devices/seen', token: await _token());
  }

  /// Egy köteg mért pont; a válasz: élő mód van-e, és mikor jöjjön a következő feltöltés.
  Future<Map<String, dynamic>> uploadLocations(String legKey, List<Map<String, dynamic>> points) async =>
      Map<String, dynamic>.from(await _http.post('/api/v1/driver/legs/$legKey/locations', token: await _token(), body: {'points': points}) as Map);
}
