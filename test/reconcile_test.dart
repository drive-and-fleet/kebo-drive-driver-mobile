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
}
