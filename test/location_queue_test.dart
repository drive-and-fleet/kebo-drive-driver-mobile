import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fleet_driver_app/local/local_database.dart';
import 'package:fleet_driver_app/local/local_repository.dart';
import 'package:fleet_driver_app/models/models.dart';

DriverLeg _leg(String key, {Object? sharing}) => DriverLeg.fromJson({
      'legKey': key,
      'status': 'IN_PROGRESS',
      'sequenceNo': 1,
      'orderVehicleId': 'ov-$key',
      'registrationNumber': 'ABC-123',
      'orderNo': 'FO-1',
      'serviceOrgId': '2',
      'fromAddress': 'A',
      'toAddress': 'B',
      if (sharing != null) 'locationSharing': sharing,
    });

void main() {
  late LocalRepository local;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final file = File('${await getDatabasesPath()}/fleet_driver.db');
    if (file.existsSync()) file.deleteSync();
    local = LocalRepository(LocalDatabase.instance);
  });

  test('a helyzetmegosztás jelzője a szervertől a helyi tárig és vissza', () async {
    await local.cacheLegs([_leg('ON', sharing: 1), _leg('OFF', sharing: false), _leg('OLD')]);
    final byKey = {for (final leg in await local.cachedLegs()) leg.legKey: leg.locationSharing};
    expect(byKey, {'ON': true, 'OFF': false, 'OLD': false});
    await local.setLegLocationSharing('ON', false);
    expect((await local.cachedLegs()).firstWhere((l) => l.legKey == 'ON').locationSharing, false);
  });

  test('a mért pontok sora: sorrend, a szerver mezőnevei, törlés, eldobás', () async {
    final t = DateTime.utc(2026, 9, 27, 10);
    await local.addLocationPoint('L1', latitude: 47.5, longitude: 19.0, accuracy: 30, speed: 12, heading: 90, recordedAt: t);
    await local.addLocationPoint('L1', latitude: 47.6, longitude: 19.1, accuracy: 25, speed: -1, heading: -1, recordedAt: t.add(const Duration(minutes: 1)));
    await local.addLocationPoint('L2', latitude: 47.7, longitude: 19.2, recordedAt: t);

    final batch = await local.pendingLocationPoints('L1');
    expect(batch.length, 2);
    expect(batch.first['latitude'], 47.5);
    expect(batch.first['accuracyM'], 30);
    expect(batch.first['speedMps'], 12);
    expect(batch.first['recordedAt'], '2026-09-27T10:00:00.000Z');
    // A „nem ismert” sebesség/irány (-1) nem megy fel.
    expect(batch.last.containsKey('speedMps'), false);
    expect(batch.last.containsKey('heading'), false);

    expect((await local.legsWithPendingLocations())..sort(), ['L1', 'L2']);
    await local.deleteLocationPoints([batch.first['id'] as int]);
    expect((await local.pendingLocationPoints('L1')).length, 1);
    await local.dropLocationPoints('L1');
    expect(await local.legsWithPendingLocations(), ['L2']);
  });

  test('az új fuvar ideiglenes kulcsa lecserélődik a pontokon is', () async {
    await local.addLocationPoint('local-abc', latitude: 47.1, longitude: 19.1, recordedAt: DateTime.utc(2026, 9, 27));
    await local.remapLegKey('local-abc', 'REAL-1', orderNo: 'ORD-1');
    expect((await local.pendingLocationPoints('REAL-1')).length, 1);
    expect((await local.pendingLocationPoints('local-abc')), isEmpty);
  });

  test('a lezáráskori helyzet a jegyzőkönyvhöz mentődik', () async {
    final db = await LocalDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('local_inspection', {
      'local_id': 'i-pos', 'leg_key': 'ON', 'form_type_id': 'f1', 'inspection_type': 'PICKUP',
      'status': 'DRAFT', 'created_at': now, 'updated_at': now,
    });
    expect(await local.inspectionCompletionPosition('i-pos'), isNull);
    await local.setInspectionCompletionPosition('i-pos', latitude: 47.25, longitude: 18.5, accuracy: 20);
    expect(await local.inspectionCompletionPosition('i-pos'), {'latitude': 47.25, 'longitude': 18.5, 'accuracyM': 20.0});
  });
}
