import 'dart:convert';
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

  test('a sofőr autó-módosítása: csak a módosított mező megy fel, összeolvad, és a frissítés nem írja vissza', () async {
    await local.cacheLegs([_leg('VEH1', 'ASSIGNED')]);
    expect(await local.updateLegVehicle('VEH1', registrationNumber: 'abc-123'), isFalse, reason: 'ugyanaz a rendszám, csak másképp írva');
    expect(await local.updateLegVehicle('VEH1', registrationNumber: 'xyz 987'), isTrue);
    expect(await local.updateLegVehicle('VEH1', extraEmail: 'Iroda@Pelda.hu'), isTrue);

    final ops = (await local.pendingOperations()).where((o) => o.operationType == 'UPDATE_VEHICLE').toList();
    expect(ops, hasLength(1), reason: 'a második módosítás az első műveletbe olvad');
    expect(jsonDecode(ops.single.payload!), {'registrationNumber': 'XYZ987', 'extraEmail': 'iroda@pelda.hu'});

    // A szerver még a régi adatot adja: amíg a módosítás nem ment fel, a telefoné nyer.
    await local.cacheLegs([_leg('VEH1', 'ASSIGNED')]);
    final leg = (await local.cachedLeg('VEH1'))!;
    expect(leg.registrationNumber, 'XYZ987');
    expect(leg.vehicleExtraEmail, 'iroda@pelda.hu');
  });

  test('a telefonon felvett új fuvar: helyben látszik, nem „tűnik el”, és a szinkron után a szerver kulcsára vált', () async {
    final payload = {
      'serviceOrgId': '2', 'fleetOrgId': '5', 'registrationNumber': 'new-001',
      'pickup': {'addressLine': 'Budapest, Fő u. 1.', 'companyName': 'Szerviz Kft.'},
      'dropoff': {'addressLine': 'Győr, Ipar u. 2.'},
    };
    final legKey = await local.createLocalOrder(payload, fleetName: 'Alfa Flotta');
    expect(LocalRepository.isLocalLeg(legKey), isTrue);
    final created = (await local.cachedLeg(legKey))!;
    expect(created.status, 'ASSIGNED');
    expect(created.registrationNumber, 'NEW001');
    expect(created.fromPlace, 'Szerviz Kft. – Budapest, Fő u. 1.');

    final op = (await local.pendingOperations()).singleWhere((o) => o.operationType == 'CREATE_ORDER');
    expect(jsonDecode(op.payload!)['deviceOperationId'], isNotEmpty);

    // A szerver listájában még nincs: a letöltés utáni rendbetétel nem törli.
    final result = await local.reconcileAssigned({'KEEP'}, DateTime.now().add(const Duration(seconds: 1)));
    expect(result.removed, isNot(contains(legKey)));
    expect(await local.cachedLeg(legKey), isNotNull);

    await local.remapLegKey(legKey, 'server-leg-1', orderNo: 'ORD-2026-TEST');
    expect(await local.cachedLeg(legKey), isNull);
    expect((await local.cachedLeg('server-leg-1'))!.orderNo, 'ORD-2026-TEST');
    expect(LocalRepository.currentLegKey(legKey), 'server-leg-1');
    final remapped = (await local.pendingOperations()).singleWhere((o) => o.operationType == 'CREATE_ORDER');
    expect(remapped.legKey, 'server-leg-1');
  });

  test('szerepenként egy szignó: az új lecseréli a régit, és a régi fájlja visszajön törlésre', () async {
    await local.cacheLegs([_leg('SIG1', 'ASSIGNED')]);
    final draft = await local.createOrResumeInspection(legKey: 'SIG1', formTypeId: 'f1', phase: 'PICKUP');
    expect(await local.addSignature(inspectionLocalId: draft.localId, signerName: 'Első', signerRole: 'HANDOVER', localPath: '/tmp/a.png'), isEmpty);
    final replaced = await local.addSignature(inspectionLocalId: draft.localId, signerName: 'Második', signerRole: 'HANDOVER', localPath: '/tmp/b.png');
    expect(replaced, ['/tmp/a.png']);
    final signatures = await local.signatures(draft.localId);
    expect(signatures.map((s) => s.signerName), ['Második']);
  });

  test('az általános megjegyzés mentődik, és a másolt jegyzőkönyv is megkapja', () async {
    await local.cacheLegs([_leg('NOTE1', 'IN_PROGRESS')]);
    final pickup = await local.createOrResumeInspection(legKey: 'NOTE1', formTypeId: 'f1', phase: 'PICKUP');
    await local.saveGeneralNote(pickup.localId, '  Karcos lökhárító, kulcs a portán  ');
    expect((await local.inspection(pickup.localId))!.generalNote, 'Karcos lökhárító, kulcs a portán');
    final dropoff = await local.createOrResumeInspection(legKey: 'NOTE1', formTypeId: 'f1', phase: 'DROPOFF', copyFromLocalId: pickup.localId);
    expect(dropoff.generalNote, 'Karcos lökhárító, kulcs a portán');
    await local.saveGeneralNote(dropoff.localId, '');
    expect((await local.inspection(dropoff.localId))!.generalNote, isNull);
  });

  // ── helyzetmegosztás (ugyanebben a fájlban: a tesztfájlok párhuzamosan futnak, és egy adatbázisfájlon osztoznak) ──

  test('a helyzetmegosztás jelzője a szervertől a helyi tárig és vissza', () async {
    DriverLeg shared(String key, Object? sharing) => DriverLeg.fromJson({
          'legKey': key, 'status': 'IN_PROGRESS', 'sequenceNo': 1, 'orderVehicleId': 'ov-$key', 'registrationNumber': 'ABC-123',
          'orderNo': 'FO-1', 'serviceOrgId': '2', 'fromAddress': 'A', 'toAddress': 'B', 'locationSharing': sharing,
        });
    await local.cacheLegs([shared('LS-ON', 1), shared('LS-OFF', false), shared('LS-OLD', null)]);
    bool sharingOf(List<DriverLeg> legs, String key) => legs.firstWhere((l) => l.legKey == key).locationSharing;
    var legs = await local.cachedLegs();
    expect([sharingOf(legs, 'LS-ON'), sharingOf(legs, 'LS-OFF'), sharingOf(legs, 'LS-OLD')], [true, false, false]);
    await local.setLegLocationSharing('LS-ON', false);
    legs = await local.cachedLegs();
    expect(sharingOf(legs, 'LS-ON'), false);
  });

  test('a mért pontok sora: sorrend, a szerver mezőnevei, törlés, eldobás', () async {
    final t = DateTime.utc(2026, 9, 27, 10);
    await local.addLocationPoint('P1', latitude: 47.5, longitude: 19.0, accuracy: 30, speed: 12, heading: 90, recordedAt: t);
    await local.addLocationPoint('P1', latitude: 47.6, longitude: 19.1, accuracy: 25, speed: -1, heading: -1, recordedAt: t.add(const Duration(minutes: 1)));
    await local.addLocationPoint('P2', latitude: 47.7, longitude: 19.2, recordedAt: t);

    final batch = await local.pendingLocationPoints('P1');
    expect(batch.length, 2);
    expect(batch.first['latitude'], 47.5);
    expect(batch.first['accuracyM'], 30);
    expect(batch.first['speedMps'], 12);
    expect(batch.first['recordedAt'], '2026-09-27T10:00:00.000Z');
    // A „nem ismert” sebesség/irány (-1) nem megy fel.
    expect(batch.last.containsKey('speedMps'), false);
    expect(batch.last.containsKey('heading'), false);

    expect((await local.legsWithPendingLocations()).toSet().containsAll({'P1', 'P2'}), true);
    await local.deleteLocationPoints([batch.first['id'] as int]);
    expect((await local.pendingLocationPoints('P1')).length, 1);
    await local.dropLocationPoints('P1');
    await local.dropLocationPoints('P2');
    expect(await local.pendingLocationPoints('P1'), isEmpty);
  });

  test('az új fuvar ideiglenes kulcsa a helyzetpontokon is lecserélődik', () async {
    await local.addLocationPoint('local-pos', latitude: 47.1, longitude: 19.1, recordedAt: DateTime.utc(2026, 9, 27));
    await local.remapLegKey('local-pos', 'REAL-POS', orderNo: 'ORD-1');
    expect((await local.pendingLocationPoints('REAL-POS')).length, 1);
    expect(await local.pendingLocationPoints('local-pos'), isEmpty);
    await local.dropLocationPoints('REAL-POS');
  });

  test('a lezáráskori helyzet a jegyzőkönyvhöz mentődik', () async {
    final db = await LocalDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('local_inspection', {
      'local_id': 'i-pos', 'leg_key': 'LS-ON', 'form_type_id': 'f1', 'inspection_type': 'PICKUP',
      'status': 'DRAFT', 'created_at': now, 'updated_at': now,
    });
    expect(await local.inspectionCompletionPosition('i-pos'), isNull);
    await local.setInspectionCompletionPosition('i-pos', latitude: 47.25, longitude: 18.5, accuracy: 20);
    expect(await local.inspectionCompletionPosition('i-pos'), {'latitude': 47.25, 'longitude': 18.5, 'accuracyM': 20.0});
  });

  test('javítás: lezárt jegyzőkönyv értéke a telefonon változik, a javítás sorba áll az indokkal; nyitottra tiltott', () async {
    await local.cacheLegs([_leg('CORR', 'IN_PROGRESS')]);
    final db = await LocalDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('local_inspection', {
      'local_id': 'c1', 'leg_key': 'CORR', 'form_type_id': 'f1', 'inspection_type': 'PICKUP',
      'status': 'SYNCED', 'server_id': '900', 'general_note': 'régi', 'created_at': now, 'updated_at': now,
    });
    await db.insert('local_inspection_value', {'inspection_local_id': 'c1', 'field_definition_id': 'km', 'value_number': 12500});

    await local.correctInspection('c1', {'km': (value: {'value_number': '12600'}, optionIds: const <String>[])},
        generalNote: 'új megjegyzés', reason: 'Elírtam');

    final values = await local.inspectionValues('c1');
    expect(LocalRepository.normalizeNumber(values['km']?['value_number']), LocalRepository.normalizeNumber('12600'));
    expect((await local.inspection('c1'))?.generalNote, 'új megjegyzés');
    final ops = await db.query('sync_operation', where: "operation_type = 'CORRECT_INSPECTION' AND entity_id = 'c1'");
    expect(ops.length, 1);
    expect(ops.first['leg_key'], 'CORR');
    expect((jsonDecode('${ops.first['payload']}') as Map)['reason'], 'Elírtam');
    expect(await local.pendingCorrections('c1'), 1);

    await db.insert('local_inspection', {
      'local_id': 'c2', 'leg_key': 'CORR', 'form_type_id': 'f1', 'inspection_type': 'DROPOFF',
      'status': 'DRAFT', 'created_at': now, 'updated_at': now,
    });
    await expectLater(local.correctInspection('c2', const {}), throwsA(isA<StateError>()));
  });
}
