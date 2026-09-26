import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/local_models.dart';
import '../models/models.dart';
import 'local_database.dart';

class LocalRepository {
  LocalRepository(this._database);
  final LocalDatabase _database;
  static const _uuid = Uuid();

  Future<Database> get _db => _database.database;

  Future<void> cacheLegs(Iterable<DriverLeg> legs) async {
    final db = await _db;
    // ponytail: a lokális státusz nyer, amíg a hozzá tartozó sync op le nem fut —
    // különben a szerver régi IN_PROGRESS-e visszahozná a "Fuvar lezárása" gombot.
    final pendingRows = await db.query('sync_operation',
        columns: ['entity_id'],
        where: "state IN ('PENDING','RUNNING','ERROR','CONFLICT') "
            "AND operation_type IN ('START_LEG','COMPLETE_LEG')");
    final pending = {for (final row in pendingRows) '${row['entity_id']}'};
    final localStatus = <String, String>{};
    if (pending.isNotEmpty) {
      for (final row in await db.query('cached_leg', columns: ['leg_key', 'status'])) {
        localStatus['${row['leg_key']}'] = '${row['status']}';
      }
    }
    // Az autó adatait a sofőr módosította, és még nem ment fel: a telefoné nyer,
    // amíg fel nem megy (különben a frissítés visszaírná a régit).
    final vehicleEdits = <String, Map<String, Object?>>{};
    final editRows = await db.rawQuery('''
      SELECT leg.order_vehicle_id AS ov, leg.registration_number, leg.vehicle_user_email, leg.vehicle_extra_email
        FROM sync_operation op JOIN cached_leg leg ON leg.leg_key = op.leg_key
       WHERE op.operation_type = 'UPDATE_VEHICLE' AND op.state IN ('PENDING','RUNNING','ERROR','CONFLICT')''');
    for (final row in editRows) {
      vehicleEdits['${row['ov']}'] = row;
    }
    final batch = db.batch();
    for (final leg in legs) {
      final map = leg.toCacheMap();
      if (pending.contains(leg.legKey) && localStatus[leg.legKey] != null && localStatus[leg.legKey] != 'REVOKED') {
        map['status'] = localStatus[leg.legKey];
      }
      final edit = vehicleEdits[leg.orderVehicleId];
      if (edit != null) {
        map['registration_number'] = edit['registration_number'];
        map['vehicle_user_email'] = edit['vehicle_user_email'];
        map['vehicle_extra_email'] = edit['vehicle_extra_email'];
      }
      batch.insert('cached_leg', map, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// A telefonon felvett, még fel nem küldött fuvar ideiglenes azonosítója ezzel kezdődik.
  static const localLegPrefix = 'local-';
  static bool isLocalLeg(String legKey) => legKey.startsWith(localLegPrefix);

  /// Rendszám a szerver szabálya szerint: szóköz és kötőjel nélkül, nagybetűvel.
  static String normalizePlate(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  /// A sofőr módosítja az út autójának adatait (rendszám, használó e-mail, további
  /// cím). Local-first: az autó minden útján azonnal átíródik a telefonon, és egy
  /// sync művelet viszi fel — csak a ténylegesen módosított mezőket, hogy az iroda
  /// közbeni módosítását ne írja felül. Több módosítás egy műveletbe olvad.
  /// Visszaadja, hogy volt-e változás.
  Future<bool> updateLegVehicle(String legKey, {String? registrationNumber, String? userEmail, String? extraEmail}) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query('cached_leg', where: 'leg_key = ?', whereArgs: [legKey], limit: 1);
      if (rows.isEmpty) throw StateError('Az út nincs a telefonon.');
      final current = rows.first;
      final changes = <String, String?>{};
      final column = <String, String>{};
      if (registrationNumber != null) {
        final plate = normalizePlate(registrationNumber);
        if (plate.isEmpty) throw StateError('A rendszám nem lehet üres.');
        if (plate != normalizePlate('${current['registration_number']}')) {
          changes['registrationNumber'] = plate;
          column['registration_number'] = plate;
        }
      }
      String? clean(String? v) => v == null || v.trim().isEmpty ? null : v.trim().toLowerCase();
      if (userEmail != null && clean(userEmail) != clean(current['vehicle_user_email']?.toString())) {
        changes['userEmail'] = clean(userEmail);
        column['vehicle_user_email'] = clean(userEmail) ?? '';
      }
      if (extraEmail != null && clean(extraEmail) != clean(current['vehicle_extra_email']?.toString())) {
        changes['extraEmail'] = clean(extraEmail);
        column['vehicle_extra_email'] = clean(extraEmail) ?? '';
      }
      if (changes.isEmpty) return false;

      final now = DateTime.now().toUtc().toIso8601String();
      await txn.update('cached_leg', {
        for (final entry in column.entries) entry.key: entry.value.isEmpty ? null : entry.value,
        'updated_at': now,
      }, where: 'order_vehicle_id = ?', whereArgs: [current['order_vehicle_id']]);

      // Még el nem indult művelet ugyanerre az autóra: a változások beleolvadnak.
      final open = await txn.rawQuery('''
        SELECT op.id, op.payload FROM sync_operation op JOIN cached_leg leg ON leg.leg_key = op.leg_key
         WHERE op.operation_type = 'UPDATE_VEHICLE' AND op.state IN ('PENDING','ERROR','CONFLICT')
           AND leg.order_vehicle_id = ? LIMIT 1''', [current['order_vehicle_id']]);
      if (open.isNotEmpty) {
        final merged = Map<String, dynamic>.from(jsonDecode('${open.first['payload'] ?? '{}'}') as Map)..addAll(changes);
        await txn.update('sync_operation', {'payload': jsonEncode(merged), 'state': 'PENDING', 'last_error': null, 'updated_at': now},
            where: 'id = ?', whereArgs: [open.first['id']]);
      } else {
        await txn.insert('sync_operation', {
          'id': _uuid.v4(), 'operation_type': 'UPDATE_VEHICLE', 'entity_id': legKey, 'leg_key': legKey, 'state': 'PENDING',
          'attempts': 0, 'last_error': null, 'payload': jsonEncode(changes), 'created_at': now, 'updated_at': now,
        });
      }
      return true;
    });
  }

  /// Új fuvar a telefonon (egyszerűsített: egy autó, A → B, egy út a sofőrre).
  /// Local-first: azonnal megjelenik a Munkáim között (ideiglenes azonosítóval),
  /// és indítható, jegyzőkönyvezhető; a szinkron hozza létre a szerveren, utána
  /// minden helyi hivatkozás a szerver azonosítójára vált. Visszaadja az út kulcsát.
  Future<String> createLocalOrder(Map<String, dynamic> payload, {required String fleetName}) async {
    final db = await _db;
    final operationId = _uuid.v4();
    final legKey = '$localLegPrefix$operationId';
    final pickup = Map<String, dynamic>.from(payload['pickup'] as Map);
    final dropoff = Map<String, dynamic>.from(payload['dropoff'] as Map);
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('cached_leg', {
        'leg_key': legKey, 'leg_id': null, 'status': 'ASSIGNED', 'sequence_no': 1,
        'planned_start': pickup['plannedFrom'], 'planned_end': dropoff['plannedFrom'],
        'order_vehicle_id': 'local-ov-$operationId', 'registration_number': normalizePlate('${payload['registrationNumber']}'),
        'make': payload['make'], 'model': payload['model'], 'color': payload['color'],
        'order_no': 'Új fuvar – $fleetName', 'service_org_id': '${payload['serviceOrgId']}',
        'from_address': '${pickup['addressLine']}', 'to_address': '${dropoff['addressLine']}',
        'from_company_name': pickup['companyName'], 'to_company_name': dropoff['companyName'],
        'from_contact_name': pickup['contactName'], 'from_contact_phone': pickup['contactPhone'],
        'to_contact_name': dropoff['contactName'], 'to_contact_phone': dropoff['contactPhone'],
        'from_stop_notes': pickup['notes'], 'to_stop_notes': dropoff['notes'],
        'vehicle_user_name': payload['userName'], 'vehicle_user_email': payload['userEmail'], 'vehicle_user_phone': payload['userPhone'],
        'vehicle_extra_email': payload['extraEmail'], 'vehicle_notes': payload['notes'],
        'updated_at': now,
      });
      await txn.insert('sync_operation', {
        'id': operationId, 'operation_type': 'CREATE_ORDER', 'entity_id': legKey, 'leg_key': legKey, 'state': 'PENDING',
        'attempts': 0, 'last_error': null, 'payload': jsonEncode({...payload, 'deviceOperationId': operationId}),
        'created_at': now, 'updated_at': now,
      });
    });
    return legKey;
  }

  /// A szerveren létrejött fuvar: az ideiglenes út-azonosító mindenhol a szerverére vált
  /// (az út, a jegyzőkönyvei és a még hátralévő szinkron-műveletei).
  /// Az app futása alatt átváltott ideiglenes → szerveroldali út-kulcsok: a nyitva
  /// lévő képernyők ezzel találják meg az utat az átváltás után is.
  static final Map<String, String> remappedLegKeys = {};
  static String currentLegKey(String legKey) => remappedLegKeys[legKey] ?? legKey;

  Future<void> remapLegKey(String temporary, String real, {required String orderNo}) async {
    remappedLegKeys[temporary] = real;
    final db = await _db;
    await db.transaction((txn) async {
      await txn.update('cached_leg', {'leg_key': real, 'order_no': orderNo}, where: 'leg_key = ?', whereArgs: [temporary]);
      await txn.update('local_inspection', {'leg_key': real}, where: 'leg_key = ?', whereArgs: [temporary]);
      await txn.update('sync_operation', {'leg_key': real}, where: 'leg_key = ?', whereArgs: [temporary]);
      await txn.update('sync_operation', {'entity_id': real}, where: 'entity_id = ?', whereArgs: [temporary]);
      await txn.update('location_point', {'leg_key': real}, where: 'leg_key = ?', whereArgs: [temporary]);
    });
  }

  // ── helyzetmegosztás: a mért pontok sora (local-first), a jegyzőkönyv lezárásakori pont ──

  Future<void> addLocationPoint(String legKey, {required double latitude, required double longitude, double? accuracy, double? speed, double? heading, required DateTime recordedAt}) async {
    final db = await _db;
    await db.insert('location_point', {
      'leg_key': legKey, 'latitude': latitude, 'longitude': longitude, 'accuracy': accuracy,
      'speed': speed, 'heading': heading, 'recorded_at': recordedAt.toUtc().toIso8601String(),
    });
  }

  /// A legrégebbi még fel nem küldött pontok ([limit] darab), a szerver formátumában; `id` a törléshez.
  Future<List<Map<String, dynamic>>> pendingLocationPoints(String legKey, {int limit = 200}) async {
    final db = await _db;
    final rows = await db.query('location_point', where: 'leg_key = ?', whereArgs: [legKey], orderBy: 'id', limit: limit);
    return [
      for (final r in rows)
        {
          'id': r['id'],
          'latitude': r['latitude'],
          'longitude': r['longitude'],
          if (r['accuracy'] != null) 'accuracyM': r['accuracy'],
          if (r['speed'] != null && (r['speed'] as num) >= 0) 'speedMps': r['speed'],
          if (r['heading'] != null && (r['heading'] as num) >= 0) 'heading': r['heading'],
          'recordedAt': r['recorded_at'],
        }
    ];
  }

  Future<void> deleteLocationPoints(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    await db.delete('location_point', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
  }

  /// Amit a szerver már nem fogad (az út véget ért, lekerült, vagy a megosztás kikapcsolt), eldobjuk.
  Future<void> dropLocationPoints(String legKey) async {
    final db = await _db;
    await db.delete('location_point', where: 'leg_key = ?', whereArgs: [legKey]);
  }

  Future<List<String>> legsWithPendingLocations() async {
    final db = await _db;
    return [for (final r in await db.rawQuery('SELECT DISTINCT leg_key FROM location_point')) '${r['leg_key']}'];
  }

  Future<void> setLegLocationSharing(String legKey, bool on) async {
    final db = await _db;
    await db.update('cached_leg', {'location_sharing': on ? 1 : 0}, where: 'leg_key = ?', whereArgs: [legKey]);
  }

  /// Hol volt a telefon, amikor a jegyzőkönyvet lezárta: a szerver ebből pótolja a térképi pont nélküli megállót.
  Future<void> setInspectionCompletionPosition(String localId, {required double latitude, required double longitude, double? accuracy}) async {
    final db = await _db;
    await db.update('local_inspection', {'completed_latitude': latitude, 'completed_longitude': longitude, 'completed_accuracy': accuracy},
        where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<Map<String, double>?> inspectionCompletionPosition(String localId) async {
    final db = await _db;
    final rows = await db.query('local_inspection', columns: ['completed_latitude', 'completed_longitude', 'completed_accuracy'],
        where: 'local_id = ?', whereArgs: [localId], limit: 1);
    if (rows.isEmpty || rows.first['completed_latitude'] == null || rows.first['completed_longitude'] == null) return null;
    return {
      'latitude': (rows.first['completed_latitude'] as num).toDouble(),
      'longitude': (rows.first['completed_longitude'] as num).toDouble(),
      if (rows.first['completed_accuracy'] != null) 'accuracyM': (rows.first['completed_accuracy'] as num).toDouble(),
    };
  }

  // ── új fuvarhoz: a sofőr szolgálatai és azok flottakezelő partnerei (offline is) ──

  Future<void> cacheServices(List<Map<String, dynamic>> services) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('cached_service');
      for (final s in services) {
        await txn.insert('cached_service', {'id': '${s['id']}', 'name': '${s['name']}'});
      }
    });
  }

  Future<List<Map<String, String>>> services() async {
    final db = await _db;
    return [for (final r in await db.query('cached_service', orderBy: 'name')) {'id': '${r['id']}', 'name': '${r['name']}'}];
  }

  Future<void> cacheFleets(String serviceOrgId, List<Map<String, dynamic>> fleets) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('cached_fleet', where: 'service_org_id = ?', whereArgs: [serviceOrgId]);
      for (final f in fleets) {
        await txn.insert('cached_fleet', {'service_org_id': serviceOrgId, 'id': '${f['id']}', 'name': '${f['name']}'});
      }
    });
  }

  Future<List<Map<String, String>>> fleets(String serviceOrgId) async {
    final db = await _db;
    return [
      for (final r in await db.query('cached_fleet', where: 'service_org_id = ?', whereArgs: [serviceOrgId], orderBy: 'name'))
        {'id': '${r['id']}', 'name': '${r['name']}'},
    ];
  }

  /// A szerver teljes listája a sofőr még elvégzendő útjairól ([serverKeys])
  /// alapján rendbe teszi a telefont: ami itt még elvégzendő (kiosztva / folyamatban),
  /// de a szerver már nem adja (lemondták, visszavették, átadták), az eltűnik.
  /// Ha viszont van hozzá még fel nem töltött helyi munka (nyitott vagy lezárt, de
  /// nem szinkronizált jegyzőkönyv, függő művelet), nem töröljük: REVOKED lesz,
  /// hogy a sofőr lássa, és semmi ne vesszen el. Csak a letöltés indulása
  /// ([fetchedAt]) előtt frissült sorokat érinti, így egy közben felvett fuvar
  /// nem tűnik el.
  Future<({List<String> removed, List<String> revoked})> reconcileAssigned(Set<String> serverKeys, DateTime fetchedAt) async {
    final db = await _db;
    final removed = <String>[];
    final revoked = <String>[];
    await db.transaction((txn) async {
      final rows = await txn.query('cached_leg',
          columns: ['leg_key', 'status'],
          // A telefonon felvett, még fel nem küldött fuvar még nincs a szerveren: nem „tűnt el”.
          where: "status IN ('PLANNED','ASSIGNED','IN_PROGRESS','REVOKED') AND updated_at < ? AND leg_key NOT LIKE '$localLegPrefix%'",
          whereArgs: [fetchedAt.toUtc().toIso8601String()]);
      for (final row in rows) {
        final legKey = '${row['leg_key']}';
        if (serverKeys.contains(legKey)) continue;
        final work = Sqflite.firstIntValue(await txn.rawQuery('''
          SELECT (SELECT COUNT(*) FROM sync_operation WHERE leg_key = ? AND state <> 'DONE')
               + (SELECT COUNT(*) FROM local_inspection WHERE leg_key = ? AND status <> 'SYNCED') AS count
        ''', [legKey, legKey])) ?? 0;
        if (work > 0) {
          if (row['status'] != 'REVOKED') {
            await txn.update('cached_leg', {'status': 'REVOKED', 'updated_at': DateTime.now().toUtc().toIso8601String()},
                where: 'leg_key = ?', whereArgs: [legKey]);
            revoked.add(legKey);
          }
        } else {
          await txn.delete('cached_leg', where: 'leg_key = ?', whereArgs: [legKey]);
          removed.add(legKey);
        }
      }
    });
    return (removed: removed, revoked: revoked);
  }

  Future<Set<String>> cachedLegKeys() async {
    final db = await _db;
    return {for (final row in await db.query('cached_leg', columns: ['leg_key'])) '${row['leg_key']}'};
  }

  Future<bool> hasForms(String serviceOrgId) async {
    final db = await _db;
    return (await db.query('cached_form_type', columns: ['id'], where: 'service_org_id = ?', whereArgs: [serviceOrgId], limit: 1)).isNotEmpty;
  }

  Future<List<DriverLeg>> cachedLegs() async {
    final db = await _db;
    final rows = await db.query('cached_leg', orderBy: 'planned_start IS NULL, planned_start, sequence_no');
    return rows.map(DriverLeg.fromCacheMap).toList();
  }

  /// Körfuvar: az odaút ([outbound]) visszaútja, ha a telefonon van (vagyis ennél
  /// a sofőrnél): ugyanaz a jármű, a várakozó megállóból induló következő út.
  Future<DriverLeg?> returnLegFor(DriverLeg outbound) async {
    if (!outbound.isOutbound) return null;
    final db = await _db;
    final rows = await db.query(
      'cached_leg',
      where: "order_vehicle_id = ? AND sequence_no > ? AND status != 'CANCELLED' "
          "AND (from_stop_waits = 1 OR (from_stop_waits IS NULL AND from_stop_type = 'WAIT'))",
      whereArgs: [outbound.orderVehicleId, outbound.sequenceNo],
      orderBy: 'sequence_no',
      limit: 1,
    );
    return rows.isEmpty ? null : DriverLeg.fromCacheMap(rows.first);
  }

  Future<DriverLeg?> cachedLeg(String legKey) async {
    final db = await _db;
    final rows = await db.query('cached_leg', where: 'leg_key = ?', whereArgs: [legKey], limit: 1);
    return rows.isEmpty ? null : DriverLeg.fromCacheMap(rows.first);
  }

  Future<void> updateLegStatus(String legKey, String status) async {
    final db = await _db;
    await db.update(
      'cached_leg',
      {'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'leg_key = ?',
      whereArgs: [legKey],
    );
  }

  Future<void> cacheForms(String serviceOrgId, List<dynamic> rawForms) async {
    final db = await _db;
    await db.transaction((txn) async {
      // A szerver csak az aktív jegyzőkönyv-típust küldi (szolgálatonként egyet).
      // Ha az iroda közben másikat aktivált, a régit nem dobjuk el, amíg egy
      // helyi jegyzőkönyv hivatkozik rá (félkész vagy még fel nem töltött, vagy
      // csak megtekinthető): az inaktív marad, új jegyzőkönyvet viszont nem kap.
      final incoming = {
        for (final raw in rawForms.cast<Map<String, dynamic>>()) '${Map<String, dynamic>.from(raw['form'] as Map)['id']}'
      };
      final existing = await txn.query('cached_form_type', columns: ['id'], where: 'service_org_id = ?', whereArgs: [serviceOrgId]);
      for (final formId in existing.map((row) => '${row['id']}')) {
        final used = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM local_inspection WHERE form_type_id = ?', [formId])) ?? 0;
        if (incoming.contains(formId) || used == 0) {
          await txn.delete('cached_form_field', where: 'form_type_id = ?', whereArgs: [formId]);
          await txn.delete('cached_photo_requirement', where: 'form_type_id = ?', whereArgs: [formId]);
          await txn.delete('cached_form_type', where: 'id = ?', whereArgs: [formId]);
        } else {
          await txn.update('cached_form_type', {'active': 0}, where: 'id = ?', whereArgs: [formId]);
        }
      }

      final now = DateTime.now().toUtc().toIso8601String();
      for (final raw in rawForms.cast<Map<String, dynamic>>()) {
        final form = Map<String, dynamic>.from(raw['form'] as Map);
        final formId = '${form['id']}';
        await txn.insert('cached_form_type', {
          'id': formId,
          'service_org_id': '${form['serviceOrgId']}',
          'code': '${form['code']}',
          'name': '${form['name']}',
          'description': form['description']?.toString(),
          'active': 1,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        for (final fieldRaw in (raw['fields'] as List? ?? const [])) {
          final wrapper = Map<String, dynamic>.from(fieldRaw as Map);
          final binding = Map<String, dynamic>.from(wrapper['binding'] as Map);
          final definition = Map<String, dynamic>.from(wrapper['definition'] as Map);
          await txn.insert('cached_form_field', {
            'binding_id': '${binding['id']}',
            'form_type_id': formId,
            'field_definition_id': '${definition['id']}',
            'code': '${definition['code']}',
            'name': '${definition['name']}',
            'data_type': '${definition['dataType']}',
            'description': definition['description']?.toString(),
            'unit': definition['unit']?.toString(),
            'required': binding['required'] == true ? 1 : 0,
            'sort_order': int.tryParse('${binding['sortOrder']}') ?? 0,
            'phase': '${binding['phase']}',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          for (final optionRaw in (wrapper['options'] as List? ?? const [])) {
            final option = Map<String, dynamic>.from(optionRaw as Map);
            await txn.insert('cached_form_option', {
              'id': '${option['id']}',
              'field_definition_id': '${definition['id']}',
              'code': '${option['code']}',
              'label': '${option['label']}',
              'sort_order': int.tryParse('${option['sortOrder']}') ?? 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        for (final photoRaw in (raw['photos'] as List? ?? const [])) {
          final photo = Map<String, dynamic>.from(photoRaw as Map);
          await txn.insert('cached_photo_requirement', {
            'id': '${photo['id']}',
            'form_type_id': formId,
            'photo_type': '${photo['photoType']}',
            'phase': '${photo['phase']}',
            'required': photo['required'] == true ? 1 : 0,
            'min_count': int.tryParse('${photo['minCount']}') ?? 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// A szolgálat jegyzőkönyv-típusai a telefonon. [activeOnly]: csak az aktív
  /// (új jegyzőkönyvhöz); nélküle a régiek is, amelyekre helyi jegyzőkönyv hivatkozik.
  Future<List<FormTypeConfig>> forms(String serviceOrgId, {bool activeOnly = false}) async {
    final db = await _db;
    final formRows = await db.query('cached_form_type',
        where: activeOnly ? 'service_org_id = ? AND active = 1' : 'service_org_id = ?', whereArgs: [serviceOrgId], orderBy: 'name');
    final result = <FormTypeConfig>[];
    for (final form in formRows) {
      final formId = '${form['id']}';
      final fieldRows = await db.query('cached_form_field', where: 'form_type_id = ?', whereArgs: [formId], orderBy: 'sort_order');
      final fields = <FormFieldConfig>[];
      for (final field in fieldRows) {
        final optionRows = await db.query('cached_form_option', where: 'field_definition_id = ?', whereArgs: [field['field_definition_id']], orderBy: 'sort_order');
        fields.add(FormFieldConfig(
          formTypeId: formId,
          fieldDefinitionId: '${field['field_definition_id']}',
          code: '${field['code']}',
          name: '${field['name']}',
          dataType: '${field['data_type']}',
          required: field['required'] == 1,
          sortOrder: field['sort_order'] as int? ?? 0,
          phase: '${field['phase']}',
          description: field['description']?.toString(),
          unit: field['unit']?.toString(),
          options: optionRows.map((option) => FormOption(
            id: '${option['id']}',
            code: '${option['code']}',
            label: '${option['label']}',
            sortOrder: option['sort_order'] as int? ?? 0,
          )).toList(),
        ));
      }
      final photoRows = await db.query('cached_photo_requirement', where: 'form_type_id = ?', whereArgs: [formId]);
      result.add(FormTypeConfig(
        id: formId,
        serviceOrgId: serviceOrgId,
        code: '${form['code']}',
        name: '${form['name']}',
        description: form['description']?.toString(),
        fields: fields,
        photoRequirements: photoRows.map((photo) => PhotoRequirement(
          photoType: '${photo['photo_type']}',
          phase: '${photo['phase']}',
          required: photo['required'] == 1,
          minCount: photo['min_count'] as int? ?? 0,
        )).toList(),
      ));
    }
    return result;
  }

  Future<void> cachePreviousInspections(String legKey, List<dynamic> raw) async {
    final db = await _db;
    await db.transaction((txn) async {
      final old = await txn.query('previous_inspection', columns: ['server_id'], where: 'leg_key = ?', whereArgs: [legKey]);
      for (final row in old) {
        final id = '${row['server_id']}';
        final valueRows = await txn.query('previous_value', columns: ['id'], where: 'inspection_server_id = ?', whereArgs: [id]);
        for (final value in valueRows) {
          await txn.delete('previous_value_option', where: 'inspection_value_id = ?', whereArgs: [value['id']]);
        }
        await txn.delete('previous_value', where: 'inspection_server_id = ?', whereArgs: [id]);
        await txn.delete('previous_damage', where: 'inspection_server_id = ?', whereArgs: [id]);
        await txn.delete('previous_photo', where: 'inspection_server_id = ?', whereArgs: [id]);
      }
      await txn.delete('previous_inspection', where: 'leg_key = ?', whereArgs: [legKey]);

      for (final itemRaw in raw) {
        final item = Map<String, dynamic>.from(itemRaw as Map);
        final inspection = Map<String, dynamic>.from(item['inspection'] as Map);
        final serverId = '${inspection['id']}';
        await txn.insert('previous_inspection', {
          'server_id': serverId,
          'leg_key': legKey,
          'general_note': inspection['generalNote']?.toString(),
          'form_type_id': '${inspection['formTypeId']}',
          'inspection_type': '${inspection['inspectionType']}',
          'completed_at': inspection['completedAt']?.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final valueRaw in (item['values'] as List? ?? const [])) {
          final value = Map<String, dynamic>.from(valueRaw as Map);
          await txn.insert('previous_value', {
            'id': '${value['id']}',
            'inspection_server_id': serverId,
            'field_definition_id': '${value['fieldDefinitionId']}',
            'value_text': value['valueText']?.toString(),
            'value_number': value['valueNumber']?.toString(),
            'value_boolean': value['valueBoolean'] == null ? null : (value['valueBoolean'] == true ? 1 : 0),
            'value_date': value['valueDate']?.toString(),
            'value_datetime': value['valueDatetime']?.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final optionRaw in (item['options'] as List? ?? const [])) {
          final option = Map<String, dynamic>.from(optionRaw as Map);
          await txn.insert('previous_value_option', {
            'inspection_value_id': '${option['inspectionValueId']}',
            'option_id': '${option['optionId']}',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final damageRaw in (item['damages'] as List? ?? const [])) {
          final damage = Map<String, dynamic>.from(damageRaw as Map);
          await txn.insert('previous_damage', {
            'id': '${damage['id']}',
            'inspection_server_id': serverId,
            'damage_type': damage['damageType']?.toString(),
            'location': damage['location']?.toString(),
            'description': '${damage['description'] ?? ''}',
            'severity': damage['severity']?.toString(),
            'is_preexisting': damage['isPreexisting'] == null ? null : (damage['isPreexisting'] == true ? 1 : 0),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final photoRaw in (item['photos'] as List? ?? const [])) {
          final photo = Map<String, dynamic>.from(photoRaw as Map);
          await txn.insert('previous_photo', {
            'id': '${photo['id']}',
            'inspection_server_id': serverId,
            'damage_id': photo['damageId']?.toString(),
            'photo_type': '${photo['photoType']}',
            'storage_key': photo['storageKey']?.toString(),
            'captured_at': photo['capturedAt']?.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<List<PreviousInspection>> previousInspections(String legKey) async {
    final db = await _db;
    final rows = await db.query(
      'previous_inspection',
      where: 'leg_key = ?',
      whereArgs: [legKey],
      orderBy: 'completed_at DESC',
    );
    final result = <PreviousInspection>[];
    for (final row in rows) {
      final serverId = '${row['server_id']}';
      final values = await db.query('previous_value', where: 'inspection_server_id = ?', whereArgs: [serverId]);
      final damages = await db.query('previous_damage', where: 'inspection_server_id = ?', whereArgs: [serverId]);
      final photos = await db.query('previous_photo', where: 'inspection_server_id = ?', whereArgs: [serverId]);
      result.add(PreviousInspection(
        serverId: serverId,
        formTypeId: '${row['form_type_id']}',
        inspectionType: '${row['inspection_type']}',
        completedAt: row['completed_at'] == null ? null : DateTime.tryParse('${row['completed_at']}'),
        values: values,
        damages: damages,
        photos: photos,
      ));
    }
    return result;
  }

  /// Az út lokálisan már kitöltött jegyzőkönyvei — ezekből offline is lehet
  /// másolni, akkor is, ha a szinkron még nem futott le.
  /// Az egyetlen másolható forrás [phase]-hez ([leg] úton): leadásnál a
  /// út saját átvételi jegyzőkönyve, átvételnél az autó előző (nem lemondott)
  /// útjának leadási jegyzőkönyve. A telefonon rögzített példány elsőbbséget
  /// kap, így internet nélkül is másolható; ha nincs, a szerverről letöltött.
  Future<CopySource?> copySourceFor(DriverLeg leg, String phase) async {
    final db = await _db;
    final sourceType = phase == 'DROPOFF' ? 'PICKUP' : 'DROPOFF';
    String? sourceLegKey;
    int? sourceSequenceNo;
    if (phase == 'DROPOFF') {
      sourceLegKey = leg.legKey;
      sourceSequenceNo = leg.sequenceNo;
    } else {
      final previous = await db.query(
        'cached_leg',
        columns: ['leg_key', 'sequence_no'],
        where: 'order_vehicle_id = ? AND sequence_no < ? AND status != ?',
        whereArgs: [leg.orderVehicleId, leg.sequenceNo, 'CANCELLED'],
        orderBy: 'sequence_no DESC',
        limit: 1,
      );
      if (previous.isNotEmpty) {
        sourceLegKey = '${previous.first['leg_key']}';
        sourceSequenceNo = previous.first['sequence_no'] as int?;
      }
    }
    if (sourceLegKey != null) {
      final local = await db.query(
        'local_inspection',
        where: 'leg_key = ? AND inspection_type = ? AND status IN (?, ?)',
        whereArgs: [sourceLegKey, sourceType, 'COMPLETED_LOCAL', 'SYNCED'],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (local.isNotEmpty) {
        final draft = LocalInspectionDraft.fromMap(local.first);
        return CopySource(
          localId: draft.localId,
          inspectionType: sourceType,
          sameLeg: phase == 'DROPOFF',
          legSequenceNo: sourceSequenceNo,
          at: draft.updatedAt,
          synced: draft.status == 'SYNCED',
        );
      }
    }
    final server = await db.query(
      'previous_inspection',
      where: 'leg_key = ? AND inspection_type = ?',
      whereArgs: [leg.legKey, sourceType],
      orderBy: 'completed_at DESC',
      limit: 1,
    );
    if (server.isEmpty) return null;
    return CopySource(
      serverId: '${server.first['server_id']}',
      inspectionType: sourceType,
      sameLeg: phase == 'DROPOFF',
      legSequenceNo: sourceSequenceNo,
      at: server.first['completed_at'] == null ? null : DateTime.tryParse('${server.first['completed_at']}'),
    );
  }

  /// Csak DRAFT-ot folytat: a lezárt jegyzőkönyv nem nyílik újra szerkesztésre.
  /// A keresés és a beszúrás egy tranzakcióban fut, így dupla érintés sem hoz
  /// létre két piszkozatot ugyanarra az útra és fázisra.
  Future<LocalInspectionDraft> createOrResumeInspection({
    required String legKey,
    required String formTypeId,
    required String phase,
    String? copyFromServerId,
    String? copyFromLocalId,
  }) async {
    final db = await _db;
    final localId = await db.transaction((txn) async {
      final existing = await txn.query(
        'local_inspection',
        columns: ['local_id', 'status'],
        where: 'leg_key = ? AND inspection_type = ?',
        whereArgs: [legKey, phase],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (existing.isNotEmpty) {
        if (existing.first['status'] == 'DRAFT') return '${existing.first['local_id']}';
        throw StateError('Ehhez az úthoz már van lezárt ${phase == 'PICKUP' ? 'átvételi' : 'leadási'} jegyzőkönyv.');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final id = _uuid.v4();
      await txn.insert('local_inspection', {
        'local_id': id,
        'server_id': null,
        'leg_key': legKey,
        'form_type_id': formTypeId,
        'inspection_type': phase,
        'copy_from_server_id': copyFromServerId,
        'copy_from_local_id': copyFromServerId == null ? copyFromLocalId : null,
        'status': 'DRAFT',
        'created_at': now,
        'updated_at': now,
      });
      if (copyFromServerId != null) {
        await _copyBaseline(txn, id, formTypeId, phase, copyFromServerId);
      } else if (copyFromLocalId != null) {
        await _copyFromLocal(txn, id, formTypeId, phase, copyFromLocalId);
      }
      // Az általános megjegyzés is átkerül; a sofőr lezárás előtt átírhatja.
      final sourceNote = copyFromServerId != null
          ? (await txn.query('previous_inspection', columns: ['general_note'], where: 'server_id = ?', whereArgs: [copyFromServerId], limit: 1))
          : copyFromLocalId != null
              ? (await txn.query('local_inspection', columns: ['general_note'], where: 'local_id = ?', whereArgs: [copyFromLocalId], limit: 1))
              : const <Map<String, Object?>>[];
      final note = sourceNote.isEmpty ? null : sourceNote.first['general_note']?.toString();
      if (note != null && note.trim().isNotEmpty) {
        await txn.update('local_inspection', {'general_note': note}, where: 'local_id = ?', whereArgs: [id]);
      }
      return id;
    });
    return (await inspection(localId))!;
  }

  /// A cél fázisába tartozó mezők — a szerver a többit elutasítja.
  Future<Set<String>> _phaseFieldIds(DatabaseExecutor db, String formTypeId, String phase) async {
    final rows = await db.query('cached_form_field',
        columns: ['field_definition_id'],
        where: "form_type_id = ? AND phase IN ('BOTH', ?)",
        whereArgs: [formTypeId, phase]);
    return rows.map((row) => '${row['field_definition_id']}').toSet();
  }

  Future<Set<String>> phaseFieldIds(String formTypeId, String phase) async => _phaseFieldIds(await _db, formTypeId, phase);

  Future<void> _copyBaseline(Transaction txn, String localId, String formTypeId, String phase, String sourceId) async {
    final allowed = await _phaseFieldIds(txn, formTypeId, phase);
    final sourceValues = await txn.query('previous_value', where: 'inspection_server_id = ?', whereArgs: [sourceId]);
    for (final value in sourceValues) {
      final fieldId = '${value['field_definition_id']}';
      if (!allowed.contains(fieldId)) continue;
      await txn.insert('local_inspection_value', {
        'inspection_local_id': localId,
        'field_definition_id': fieldId,
        'value_text': value['value_text'],
        'value_number': value['value_number'],
        // A previous_value már 1/0 INTEGER-t tárol — változatlanul átvehető.
        'value_boolean': value['value_boolean'],
        'value_date': value['value_date'],
        'value_datetime': value['value_datetime'],
      });
      final optionRows = await txn.query('previous_value_option', where: 'inspection_value_id = ?', whereArgs: [value['id']]);
      for (final option in optionRows) {
        await txn.insert('local_inspection_value_option', {
          'inspection_local_id': localId,
          'field_definition_id': fieldId,
          'option_id': option['option_id'],
        });
      }
    }

    final damageMap = <String, String>{};
    final sourceDamages = await txn.query('previous_damage', where: 'inspection_server_id = ?', whereArgs: [sourceId]);
    for (final damage in sourceDamages) {
      final newId = _uuid.v4();
      damageMap['${damage['id']}'] = newId;
      await txn.insert('local_damage', {
        'local_id': newId,
        'server_id': null,
        'inspection_local_id': localId,
        'source_server_id': '${damage['id']}',
        'damage_type': damage['damage_type'],
        'location': damage['location'],
        'description': damage['description'],
        'severity': damage['severity'],
        'is_preexisting': damage['is_preexisting'],
        'baseline': 1,
      });
    }
    final sourcePhotos = await txn.query('previous_photo', where: 'inspection_server_id = ?', whereArgs: [sourceId]);
    for (final photo in sourcePhotos) {
      final sourceDamage = photo['damage_id']?.toString();
      // Csak sérülésfotó másolható: a kötelező járműfotókat a leadáskori
      // állapotról újra el kell készíteni.
      if (sourceDamage == null) continue;
      await txn.insert('local_photo', {
        'local_id': _uuid.v4(),
        'server_id': null,
        'inspection_local_id': localId,
        'damage_local_id': damageMap[sourceDamage],
        'source_server_id': '${photo['id']}',
        'photo_type': '${photo['photo_type']}',
        'local_path': null,
        'storage_key': photo['storage_key'],
        'captured_at': photo['captured_at'] ?? DateTime.now().toUtc().toIso8601String(),
        'baseline': 1,
      });
    }
  }

  /// Lokális jegyzőkönyvből másol, ugyanazzal a szabállyal, mint a szerver. A
  /// sérülések és sérülésfotók `baseline` sorok: feltöltéskor a szerver maga
  /// másolja őket a forrás szerveroldali példányából (copy_from_local_id →
  /// a forrás server_id-ja). Így semmi nem töltődik fel kétszer, és a forrás
  /// másolt (helyi fájl nélküli) sérülésfotói sem vesznek el.
  Future<void> _copyFromLocal(Transaction txn, String localId, String formTypeId, String phase, String sourceLocalId) async {
    final allowed = await _phaseFieldIds(txn, formTypeId, phase);

    final sourceValues = await txn.query('local_inspection_value', where: 'inspection_local_id = ?', whereArgs: [sourceLocalId]);
    for (final value in sourceValues) {
      final fieldId = '${value['field_definition_id']}';
      if (!allowed.contains(fieldId)) continue;
      await txn.insert('local_inspection_value', {
        ...value,
        'inspection_local_id': localId,
      });
      final optionRows = await txn.query('local_inspection_value_option',
          where: 'inspection_local_id = ? AND field_definition_id = ?', whereArgs: [sourceLocalId, fieldId]);
      for (final option in optionRows) {
        await txn.insert('local_inspection_value_option', {
          'inspection_local_id': localId,
          'field_definition_id': fieldId,
          'option_id': option['option_id'],
        });
      }
    }

    final damageMap = <String, String>{};
    for (final damage in await txn.query('local_damage', where: 'inspection_local_id = ?', whereArgs: [sourceLocalId])) {
      final newId = _uuid.v4();
      damageMap['${damage['local_id']}'] = newId;
      await txn.insert('local_damage', {
        ...damage,
        'local_id': newId,
        'server_id': null,
        'inspection_local_id': localId,
        'source_server_id': damage['server_id'],
        'baseline': 1,
      });
    }
    for (final photo in await txn.query('local_photo', where: 'inspection_local_id = ?', whereArgs: [sourceLocalId])) {
      final sourceDamage = photo['damage_local_id']?.toString();
      if (sourceDamage == null) continue; // csak sérülésfotó másolható
      await txn.insert('local_photo', {
        ...photo,
        'local_id': _uuid.v4(),
        'server_id': null,
        'inspection_local_id': localId,
        'damage_local_id': damageMap[sourceDamage],
        'source_server_id': photo['server_id'],
        'baseline': 1,
      });
    }
  }

  /// Az általános megjegyzés mentése (csak nyitott jegyzőkönyvön).
  Future<void> saveGeneralNote(String localId, String? note) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _assertDraft(txn, localId);
      await txn.update('local_inspection', {
        'general_note': note?.trim().isEmpty ?? true ? null : note!.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, where: 'local_id = ?', whereArgs: [localId]);
    });
  }

  Future<LocalInspectionDraft?> inspection(String localId) async {
    final db = await _db;
    final rows = await db.query('local_inspection', where: 'local_id = ?', whereArgs: [localId], limit: 1);
    return rows.isEmpty ? null : LocalInspectionDraft.fromMap(rows.first);
  }

  Future<LocalInspectionDraft?> inspectionForLeg(String legKey, String phase) async {
    final db = await _db;
    final rows = await db.query('local_inspection', where: 'leg_key = ? AND inspection_type = ?', whereArgs: [legKey, phase], orderBy: 'created_at DESC', limit: 1);
    return rows.isEmpty ? null : LocalInspectionDraft.fromMap(rows.first);
  }

  Future<Map<String, Map<String, dynamic>>> inspectionValues(String localId) async {
    final db = await _db;
    final rows = await db.query('local_inspection_value', where: 'inspection_local_id = ?', whereArgs: [localId]);
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final fieldId = '${row['field_definition_id']}';
      final options = await db.query('local_inspection_value_option', columns: ['option_id'], where: 'inspection_local_id = ? AND field_definition_id = ?', whereArgs: [localId, fieldId]);
      result[fieldId] = {...row, 'option_ids': options.map((option) => '${option['option_id']}').toList()};
    }
    return result;
  }

  /// Minden szerkesztés csak piszkozaton engedett: a lezárt jegyzőkönyv
  /// tartalma már a sync sorban van, utólagos változás soha nem jutna fel.
  Future<void> _assertDraft(DatabaseExecutor db, String localId) async {
    final rows = await db.query('local_inspection', columns: ['status'], where: 'local_id = ?', whereArgs: [localId], limit: 1);
    if (rows.isEmpty) throw StateError('Hiányzó lokális jegyzőkönyv: $localId');
    if (rows.first['status'] != 'DRAFT') throw StateError('A jegyzőkönyv már le van zárva, nem módosítható.');
  }

  /// Az üres érték (kiürített mező, minden opció levéve) nem egy üres sor,
  /// hanem a sor hiánya — a szerver az üres értéket érvénytelennek tekintené.
  static bool isEmptyValue(Map<String, dynamic> value, List<String> optionIds) {
    bool blank(Object? v) => v == null || (v is String && v.trim().isEmpty);
    return optionIds.isEmpty &&
        blank(value['value_text']) &&
        blank(value['value_number']) &&
        value['value_boolean'] == null &&
        blank(value['value_date']) &&
        blank(value['value_datetime']);
  }

  /// Tizedesvessző → pont, hogy a szerver számként fogadja el.
  static String? normalizeNumber(Object? raw) {
    if (raw == null) return null;
    final text = '$raw'.trim().replaceAll(',', '.');
    return text.isEmpty ? null : text;
  }

  Future<void> saveInspectionValue(String localId, String fieldId, Map<String, dynamic> value, List<String> optionIds) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _assertDraft(txn, localId);
      await txn.delete('local_inspection_value_option', where: 'inspection_local_id = ? AND field_definition_id = ?', whereArgs: [localId, fieldId]);
      if (isEmptyValue(value, optionIds)) {
        await txn.delete('local_inspection_value', where: 'inspection_local_id = ? AND field_definition_id = ?', whereArgs: [localId, fieldId]);
      } else {
        await txn.insert('local_inspection_value', {
          'inspection_local_id': localId,
          'field_definition_id': fieldId,
          'value_text': value['value_text'],
          'value_number': normalizeNumber(value['value_number']),
          'value_boolean': value['value_boolean'] == null ? null : (value['value_boolean'] == true ? 1 : 0),
          'value_date': value['value_date'],
          'value_datetime': value['value_datetime'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final optionId in optionIds) {
          await txn.insert('local_inspection_value_option', {
            'inspection_local_id': localId,
            'field_definition_id': fieldId,
            'option_id': optionId,
          });
        }
      }
      await txn.update('local_inspection', {'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
    });
  }

  Future<List<LocalDamage>> damages(String localId) async {
    final db = await _db;
    final rows = await db.query('local_damage', where: 'inspection_local_id = ?', whereArgs: [localId], orderBy: 'baseline DESC, local_id');
    return rows.map(LocalDamage.fromMap).toList();
  }

  Future<LocalDamage> addDamage({required String inspectionLocalId, required String description, String? damageType, String? location, String? severity, bool? isPreexisting}) async {
    final db = await _db;
    final id = _uuid.v4();
    await db.transaction((txn) async {
      await _assertDraft(txn, inspectionLocalId);
      await txn.insert('local_damage', {
        'local_id': id,
        'server_id': null,
        'inspection_local_id': inspectionLocalId,
        'source_server_id': null,
        'damage_type': damageType,
        'location': location,
        'description': description,
        'severity': severity,
        'is_preexisting': isPreexisting == null ? null : (isPreexisting ? 1 : 0),
        'baseline': 0,
      });
    });
    return (await damages(inspectionLocalId)).firstWhere((damage) => damage.localId == id);
  }

  Future<void> setDamageServerId(String localId, String serverId) async {
    final db = await _db;
    await db.update('local_damage', {'server_id': serverId}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<List<LocalPhoto>> photos(String localId) async {
    final db = await _db;
    final rows = await db.query('local_photo', where: 'inspection_local_id = ?', whereArgs: [localId], orderBy: 'captured_at');
    return rows.map(LocalPhoto.fromMap).toList();
  }

  Future<void> addPhoto({required String inspectionLocalId, required String photoType, required String localPath, String? damageLocalId}) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _assertDraft(txn, inspectionLocalId);
      await txn.insert('local_photo', {
        'local_id': _uuid.v4(),
        'server_id': null,
        'inspection_local_id': inspectionLocalId,
        'damage_local_id': damageLocalId,
        'source_server_id': null,
        'photo_type': photoType,
        'local_path': localPath,
        'storage_key': null,
        'captured_at': DateTime.now().toUtc().toIso8601String(),
        'baseline': 0,
      });
    });
  }

  /// A presign-nal kapott kulcs a PUT ELŐTT mentődik: retry-nál ugyanerre a
  /// kulcsra kérünk új URL-t, így nem keletkezik árva vagy duplikált objektum.
  Future<void> reservePhotoKey(String localId, String storageKey) async {
    final db = await _db;
    await db.update('local_photo', {'storage_key': storageKey}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> updatePhotoUpload(String localId, {required String serverId, required String storageKey}) async {
    final db = await _db;
    await db.update('local_photo', {'server_id': serverId, 'storage_key': storageKey}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<List<LocalSignature>> signatures(String localId) async {
    final db = await _db;
    final rows = await db.query('local_signature', where: 'inspection_local_id = ?', whereArgs: [localId], orderBy: 'signed_at');
    return rows.map(LocalSignature.fromMap).toList();
  }

  /// Egy jegyzőkönyvön szerepenként (átadó / átvevő) egy szignó van: az új
  /// ugyanabban a tranzakcióban lecseréli a régit. Visszaadja a lecserélt
  /// szignók képfájljait, hogy a hívó törölhesse őket.
  Future<List<String>> addSignature({required String inspectionLocalId, required String signerName, String? signerRole, required String localPath}) async {
    final db = await _db;
    return db.transaction((txn) async {
      await _assertDraft(txn, inspectionLocalId);
      final previous = await txn.query('local_signature',
          columns: ['local_id', 'local_path'],
          where: signerRole == null ? 'inspection_local_id = ? AND signer_role IS NULL' : 'inspection_local_id = ? AND signer_role = ?',
          whereArgs: signerRole == null ? [inspectionLocalId] : [inspectionLocalId, signerRole]);
      for (final row in previous) {
        await txn.delete('local_signature', where: 'local_id = ?', whereArgs: [row['local_id']]);
      }
      await txn.insert('local_signature', {
        'local_id': _uuid.v4(),
        'server_id': null,
        'inspection_local_id': inspectionLocalId,
        'signer_name': signerName,
        'signer_role': signerRole,
        'local_path': localPath,
        'storage_key': null,
        'signed_at': DateTime.now().toUtc().toIso8601String(),
      });
      return [for (final row in previous) '${row['local_path']}'];
    });
  }

  Future<void> reserveSignatureKey(String localId, String storageKey) async {
    final db = await _db;
    await db.update('local_signature', {'storage_key': storageKey}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> updateSignatureUpload(String localId, {required String serverId, required String storageKey}) async {
    final db = await _db;
    await db.update('local_signature', {'server_id': serverId, 'storage_key': storageKey}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markInspectionServerId(String localId, String serverId) async {
    final db = await _db;
    await db.update('local_inspection', {'server_id': serverId, 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
  }

  /// A jegyzőkönyv lezárása és az ebből következő út-állapotváltás EGY
  /// tranzakció: vagy minden lokális változás és sync művelet létrejön, vagy
  /// semmi. PICKUP lezárása elindítja a fuvart (ASSIGNED → IN_PROGRESS),
  /// DROPOFF lezárása lezárja (IN_PROGRESS → COMPLETED_PENDING_SYNC).
  /// Visszaadja az út új lokális státuszát.
  Future<String?> completeInspectionAndTransition(String localId) async {
    final db = await _db;
    return db.transaction((txn) async {
      await _assertDraft(txn, localId);
      final row = (await txn.query('local_inspection', where: 'local_id = ?', whereArgs: [localId], limit: 1)).first;
      final legKey = '${row['leg_key']}';
      final phase = '${row['inspection_type']}';
      await txn.update('local_inspection', {'status': 'COMPLETED_LOCAL', 'updated_at': DateTime.now().toUtc().toIso8601String()},
          where: 'local_id = ?', whereArgs: [localId]);
      await _enqueue(txn, 'SYNC_INSPECTION', localId, legKey);
      return _transitionLeg(txn, legKey, phase);
    });
  }

  /// Ha a szükséges jegyzőkönyv már lezárt (egy korábbi appverzió lezárása
  /// nem indította el / nem zárta le a fuvart), csak az út-állapotváltás.
  Future<String?> transitionLegAfterInspection(String legKey, String phase) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query('local_inspection',
          columns: ['status'],
          where: 'leg_key = ? AND inspection_type = ?',
          whereArgs: [legKey, phase],
          orderBy: 'created_at DESC',
          limit: 1);
      if (rows.isEmpty || !['COMPLETED_LOCAL', 'SYNCED'].contains(rows.first['status'])) {
        throw StateError(phase == 'PICKUP'
            ? 'A fuvar indításához előbb zárd le az átvételi jegyzőkönyvet.'
            : 'A fuvar lezárásához előbb zárd le a leadási jegyzőkönyvet.');
      }
      return _transitionLeg(txn, legKey, phase);
    });
  }

  Future<String?> _transitionLeg(Transaction txn, String legKey, String phase) async {
    final legRows = await txn.query('cached_leg', columns: ['status'], where: 'leg_key = ?', whereArgs: [legKey], limit: 1);
    final status = legRows.isEmpty ? null : '${legRows.first['status']}';
    final now = DateTime.now().toUtc().toIso8601String();
    if (phase == 'PICKUP' && status == 'ASSIGNED') {
      await txn.update('cached_leg', {'status': 'IN_PROGRESS', 'updated_at': now}, where: 'leg_key = ?', whereArgs: [legKey]);
      await _enqueue(txn, 'START_LEG', legKey, legKey);
      return 'IN_PROGRESS';
    }
    if (phase == 'DROPOFF' && status == 'IN_PROGRESS') {
      await txn.update('cached_leg', {'status': 'COMPLETED_PENDING_SYNC', 'updated_at': now}, where: 'leg_key = ?', whereArgs: [legKey]);
      await _enqueue(txn, 'COMPLETE_LEG', legKey, legKey);
      return 'COMPLETED_PENDING_SYNC';
    }
    return status;
  }

  Future<void> markInspectionSynced(String localId) async {
    final db = await _db;
    await db.update('local_inspection', {'status': 'SYNCED', 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
  }

  /// Nem-baseline elemek, amelyek még nem értek fel a szerverre. Szerveroldalon
  /// már lezárt jegyzőkönyvnél csak akkor mondhatjuk SYNCED-et, ha ez 0.
  /// A telefon állapota szövegként a hibajelentés végére: azonosítók, állapotok
  /// és hibák — mezőértékek, nevek, fotók nélkül.
  Future<String> diagnostics() async {
    final db = await _db;
    final out = StringBuffer();
    final ops = await db.query('sync_operation', where: "state <> 'DONE'", orderBy: 'created_at');
    final done = Sqflite.firstIntValue(await db.rawQuery("SELECT COUNT(*) FROM sync_operation WHERE state = 'DONE'")) ?? 0;
    out.writeln('Függő szinkron műveletek: ${ops.length} (kész: $done)');
    for (final o in ops) {
      out.writeln('  ${o['operation_type']} ${o['entity_id']} út=${o['leg_key'] ?? '-'} állapot=${o['state']} '
          'próbák=${o['attempts']} létrehozva=${o['created_at']} frissítve=${o['updated_at']}'
          '${o['last_error'] == null ? '' : ' hiba: ${o['last_error']}'}');
    }
    final legs = await db.query('cached_leg', orderBy: 'planned_start IS NULL, planned_start, sequence_no');
    out.writeln('Utak a telefonon: ${legs.length}');
    for (final l in legs) {
      out.writeln('  ${l['leg_key']} ${l['order_no']} #${l['sequence_no']} ${l['registration_number']} '
          'jármű=${l['order_vehicle_id']} állapot=${l['status']} tervezett=${l['planned_start'] ?? '-'} frissítve=${l['updated_at']}');
    }
    final inspections = await db.query('local_inspection', orderBy: 'updated_at');
    out.writeln('Jegyzőkönyvek a telefonon: ${inspections.length}');
    for (final i in inspections) {
      final id = '${i['local_id']}';
      final photos = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM local_photo WHERE inspection_local_id = ?', [id])) ?? 0;
      final damages = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM local_damage WHERE inspection_local_id = ?', [id])) ?? 0;
      out.writeln('  $id ${i['inspection_type']} út=${i['leg_key']} állapot=${i['status']} szerver=${i['server_id'] ?? '-'} '
          'form=${i['form_type_id']} másolás=${i['copy_from_server_id'] ?? i['copy_from_local_id'] ?? '-'} '
          'fotó=$photos sérülés=$damages feltöltetlen=${await unsyncedItemCount(id)} frissítve=${i['updated_at']}');
    }
    return out.toString();
  }

  Future<int> unsyncedItemCount(String localId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT '
      '(SELECT COUNT(*) FROM local_damage WHERE inspection_local_id = ? AND baseline = 0 AND server_id IS NULL) + '
      '(SELECT COUNT(*) FROM local_photo WHERE inspection_local_id = ? AND baseline = 0 AND server_id IS NULL) + '
      '(SELECT COUNT(*) FROM local_signature WHERE inspection_local_id = ? AND server_id IS NULL) AS count',
      [localId, localId, localId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> _enqueue(DatabaseExecutor db, String type, String entityId, String legKey) async {
    // Egy még élő (akár hibás vagy ütköző) művelet mellé nem kerül második
    // ugyanarra az entitásra — az ugyanazt kétszer küldené fel.
    final existing = await db.query('sync_operation',
        where: 'operation_type = ? AND entity_id = ? AND state IN (?, ?, ?, ?)',
        whereArgs: [type, entityId, 'PENDING', 'RUNNING', 'ERROR', 'CONFLICT'],
        limit: 1);
    if (existing.isNotEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('sync_operation', {
      'id': _uuid.v4(),
      'operation_type': type,
      'entity_id': entityId,
      'leg_key': legKey,
      'state': 'PENDING',
      'attempts': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Strictly in enqueue order, CONFLICT included. The queue is an ordered log
  /// per leg (protocol upload, then leg start, then leg complete): SyncService
  /// lets a CONFLICT, failed or not-yet-due operation block the rest of the
  /// SAME leg, while other legs keep going.
  Future<List<SyncOperation>> pendingOperations() async {
    final db = await _db;
    final rows = await db.query('sync_operation',
        where: 'state IN (?, ?, ?)', whereArgs: ['PENDING', 'ERROR', 'CONFLICT'], orderBy: 'created_at, rowid');
    return rows.map(SyncOperation.fromMap).toList();
  }

  Future<int> pendingCount() async {
    final db = await _db;
    final rows = await db.rawQuery("SELECT COUNT(*) AS count FROM sync_operation WHERE state IN ('PENDING','ERROR','CONFLICT')");
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> operationRunning(String id) async {
    final db = await _db;
    await db.rawUpdate("UPDATE sync_operation SET state='RUNNING', attempts=attempts+1, updated_at=? WHERE id=?", [DateTime.now().toUtc().toIso8601String(), id]);
  }

  Future<void> operationDone(String id) async {
    final db = await _db;
    await db.update('sync_operation', {'state': 'DONE', 'last_error': null, 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> operationError(String id, String error, {bool conflict = false}) async {
    final db = await _db;
    await db.update('sync_operation', {
      'state': conflict ? 'CONFLICT' : 'ERROR',
      'last_error': error.length > 1000 ? error.substring(0, 1000) : error,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> retryOperation(String id) async {
    final db = await _db;
    await db.update('sync_operation', {'state': 'PENDING', 'last_error': null, 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'id = ?', whereArgs: [id]);
  }

  // Feltétel nélküli reset induláskor: minden feltöltési lépés idempotens
  // (inspection és damage: deviceOperationId, fotó és aláírás: a PUT előtt
  // lefoglalt storageKey, values: upsert, complete/start/complete leg: no-op).
  Future<void> resetStuckRunningOperations() async {
    final db = await _db;
    await db.rawUpdate("UPDATE sync_operation SET state='PENDING', updated_at=? WHERE state='RUNNING'",
        [DateTime.now().toUtc().toIso8601String()]);
  }

  /// Utanként a legrosszabb nyitott művelet — ezt látja a sofőr.
  Future<Map<String, LegSyncState>> legSyncStates() async {
    final db = await _db;
    final rows = await db.query('sync_operation', columns: ['leg_key', 'state'], where: "state <> 'DONE' AND leg_key IS NOT NULL");
    const rank = {'PENDING': 1, 'RUNNING': 2, 'ERROR': 3, 'CONFLICT': 4};
    const byRank = {1: LegSyncState.pending, 2: LegSyncState.running, 3: LegSyncState.error, 4: LegSyncState.conflict};
    final worst = <String, int>{};
    for (final row in rows) {
      final key = '${row['leg_key']}';
      final value = rank['${row['state']}'] ?? 1;
      if (value > (worst[key] ?? 0)) worst[key] = value;
    }
    return {for (final entry in worst.entries) entry.key: byRank[entry.value]!};
  }

  Future<List<SyncOperation>> allOpenOperations() async {
    final db = await _db;
    final rows = await db.query('sync_operation', where: "state <> 'DONE'", orderBy: 'created_at DESC');
    return rows.map(SyncOperation.fromMap).toList();
  }

  Future<void> clearDriverData() async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final table in [
        'local_signature', 'local_photo', 'local_damage', 'local_inspection_value_option',
        'local_inspection_value', 'local_inspection', 'sync_operation', 'previous_value_option',
        'previous_value', 'previous_damage', 'previous_photo', 'previous_inspection',
        'cached_photo_requirement', 'cached_form_option', 'cached_form_field', 'cached_form_type', 'cached_leg',
        'location_point',
      ]) {
        await txn.delete(table);
      }
    });
  }
}

extension LocalRepositoryEditing on LocalRepository {
  Future<void> deletePhoto(String photoLocalId) async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query('local_photo', where: 'local_id = ?', whereArgs: [photoLocalId], limit: 1);
      if (rows.isEmpty || rows.first['baseline'] == 1) return;
      await _assertDraft(txn, '${rows.first['inspection_local_id']}');
      await txn.delete('local_photo', where: 'local_id = ?', whereArgs: [photoLocalId]);
    });
  }

  Future<void> deleteDamage(String damageLocalId) async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query('local_damage', where: 'local_id = ?', whereArgs: [damageLocalId], limit: 1);
      if (rows.isEmpty || rows.first['baseline'] == 1) return;
      await _assertDraft(txn, '${rows.first['inspection_local_id']}');
      await txn.delete('local_photo', where: 'damage_local_id = ? AND baseline = 0', whereArgs: [damageLocalId]);
      await txn.delete('local_damage', where: 'local_id = ?', whereArgs: [damageLocalId]);
    });
  }

  /// Törli a szignót (csak nyitott jegyzőkönyvön); visszaadja a képfájlját.
  Future<String?> deleteSignature(String signatureLocalId) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query('local_signature', where: 'local_id = ?', whereArgs: [signatureLocalId], limit: 1);
      if (rows.isEmpty) return null;
      await _assertDraft(txn, '${rows.first['inspection_local_id']}');
      await txn.delete('local_signature', where: 'local_id = ?', whereArgs: [signatureLocalId]);
      return rows.first['local_path']?.toString();
    });
  }
}
