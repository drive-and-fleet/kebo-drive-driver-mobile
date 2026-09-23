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

  /// `plate` nélkül az összes felvehető fuvart adja vissza; a rendszám csak szűrő.
  Future<List<DriverLeg>> availableLegs({String? plate}) async {
    final raw = await _http.get(
      '/api/v1/driver/available-legs',
      token: await _token(),
      query: {if (plate != null && plate.trim().isNotEmpty) 'registrationNumber': plate},
    ) as List<dynamic>;
    return raw.map((e) => DriverLeg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<List<dynamic>> forms(String serviceOrgId) async =>
      (await _http.get('/api/v1/driver/services/$serviceOrgId/forms', token: await _token())) as List<dynamic>;

  Future<List<dynamic>> previousInspections(String legKey) async =>
      (await _http.get('/api/v1/driver/legs/$legKey/previous-inspections', token: await _token())) as List<dynamic>;

  Future<void> claim(String legKey) async {
    await _http.post('/api/v1/driver/legs/$legKey/claim', token: await _token());
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

  Future<void> saveValues(String inspectionId, List<Map<String, dynamic>> values) async {
    await _http.put('/api/v1/driver/inspections/$inspectionId/values', token: await _token(), body: {'values': values});
  }

  Future<String> addDamage(String inspectionId, Map<String, dynamic> damage) async {
    final raw = await _http.post('/api/v1/driver/inspections/$inspectionId/damages', token: await _token(), body: damage) as Map<String, dynamic>;
    return '${raw['id']}';
  }

  /// [kind]: PHOTO | DAMAGE | SIGNATURE — ez dönti el az objektumtár almappáját.
  Future<Map<String, dynamic>> presign(String inspectionId, String objectName, String contentType,
      {String kind = 'PHOTO'}) async {
    return Map<String, dynamic>.from(await _http.post(
      '/api/v1/driver/inspections/$inspectionId/uploads/presign',
      token: await _token(),
      body: {'objectName': objectName, 'contentType': contentType, 'kind': kind},
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

  Future<void> completeInspection(String inspectionId) async {
    await _http.post('/api/v1/driver/inspections/$inspectionId/complete', token: await _token());
  }
}
