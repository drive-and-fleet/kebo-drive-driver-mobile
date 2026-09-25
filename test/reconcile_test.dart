import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fleet_driver_app/local/local_database.dart';
import 'package:fleet_driver_app/local/local_repository.dart';
import 'package:fleet_driver_app/models/models.dart';

DriverLeg _leg(String key, String status) => DriverLeg.fromJson({
      'legKey': key,
      'status': status,
      'sequenceNo': 1,
      'orderVehicleId': 'ov-$key',
      'registrationNumber': 'ABC-123',
      'orderNo': 'FO-1',
      'serviceOrgId': '2',
      'fromAddress': 'A',
      'toAddress': 'B',
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

  test('a szerver listájából eltűnt fuvar eltűnik; helyi munkával REVOKED lesz; más nem változik', () async {
    await local.cacheLegs([
      _leg('KEEP', 'ASSIGNED'),
      _leg('GONE', 'ASSIGNED'),
      _leg('WORK', 'IN_PROGRESS'),
      _leg('DONE', 'COMPLETED'),
    ]);
    final db = await LocalDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('local_inspection', {
      'local_id': 'i1', 'leg_key': 'WORK', 'form_type_id': 'f1', 'inspection_type': 'DROPOFF',
      'status': 'DRAFT', 'created_at': now, 'updated_at': now,
    });

    await Future<void>.delayed(const Duration(milliseconds: 5));
    final fetchedAt = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // Letöltés közben felvett fuvar: nem tűnhet el.
    await local.cacheLegs([_leg('CLAIMED', 'ASSIGNED')]);

    final result = await local.reconcileAssigned({'KEEP'}, fetchedAt);
    expect(result.removed, ['GONE']);
    expect(result.revoked, ['WORK']);

    final byKey = {for (final leg in await local.cachedLegs()) leg.legKey: leg.status};
    expect(byKey, {'KEEP': 'ASSIGNED', 'WORK': 'REVOKED', 'DONE': 'COMPLETED', 'CLAIMED': 'ASSIGNED'});

    // Ha a szerver újra neki adja, a REVOKED helyére a szerver állapota kerül.
    await local.cacheLegs([_leg('WORK', 'IN_PROGRESS')]);
    expect((await local.cachedLeg('WORK'))!.status, 'IN_PROGRESS');
  });
}
