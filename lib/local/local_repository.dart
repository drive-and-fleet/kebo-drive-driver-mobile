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
    final batch = db.batch();
    for (final leg in legs) {
      batch.insert('cached_leg', leg.toCacheMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<DriverLeg>> cachedLegs() async {
    final db = await _db;
    final rows = await db.query('cached_leg', orderBy: 'planned_start IS NULL, planned_start, sequence_no');
    return rows.map(DriverLeg.fromCacheMap).toList();
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
      final existing = await txn.query('cached_form_type', columns: ['id'], where: 'service_org_id = ?', whereArgs: [serviceOrgId]);
      final formIds = existing.map((row) => '${row['id']}').toList();
      for (final formId in formIds) {
        await txn.delete('cached_form_field', where: 'form_type_id = ?', whereArgs: [formId]);
        await txn.delete('cached_photo_requirement', where: 'form_type_id = ?', whereArgs: [formId]);
      }
      await txn.delete('cached_form_type', where: 'service_org_id = ?', whereArgs: [serviceOrgId]);

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

  Future<List<FormTypeConfig>> forms(String serviceOrgId) async {
    final db = await _db;
    final formRows = await db.query('cached_form_type', where: 'service_org_id = ?', whereArgs: [serviceOrgId], orderBy: 'name');
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
          'form_type_id': '${inspection['formTypeId']}',
          'inspection_type': '${inspection['inspectionType']}',
          'completed_at': inspection['completedAt']?.toString(),
        });
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
          });
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
          });
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
          });
        }
      }
    });
  }

  Future<List<PreviousInspection>> previousInspections(String legKey, String phase) async {
    final db = await _db;
    final rows = await db.query(
      'previous_inspection',
      where: 'leg_key = ? AND inspection_type = ?',
      whereArgs: [legKey, phase],
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

  Future<LocalInspectionDraft> createOrResumeInspection({
    required String legKey,
    required String formTypeId,
    required String phase,
    String? copyFromServerId,
  }) async {
    final db = await _db;
    final existing = await db.query(
      'local_inspection',
      where: 'leg_key = ? AND inspection_type = ? AND status IN (?, ?)',
      whereArgs: [legKey, phase, 'DRAFT', 'COMPLETED_LOCAL'],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (existing.isNotEmpty) return LocalInspectionDraft.fromMap(existing.first);

    final now = DateTime.now().toUtc().toIso8601String();
    final localId = _uuid.v4();
    await db.transaction((txn) async {
      await txn.insert('local_inspection', {
        'local_id': localId,
        'server_id': null,
        'leg_key': legKey,
        'form_type_id': formTypeId,
        'inspection_type': phase,
        'copy_from_server_id': copyFromServerId,
        'status': 'DRAFT',
        'created_at': now,
        'updated_at': now,
      });
      if (copyFromServerId != null) {
        await _copyBaseline(txn, localId, formTypeId, copyFromServerId);
      }
    });
    return (await inspection(localId))!;
  }

  Future<void> _copyBaseline(Transaction txn, String localId, String formTypeId, String sourceId) async {
    final allowedFields = await txn.query('cached_form_field', columns: ['field_definition_id'], where: 'form_type_id = ?', whereArgs: [formTypeId]);
    final allowed = allowedFields.map((row) => '${row['field_definition_id']}').toSet();
    final sourceValues = await txn.query('previous_value', where: 'inspection_server_id = ?', whereArgs: [sourceId]);
    for (final value in sourceValues) {
      final fieldId = '${value['field_definition_id']}';
      if (!allowed.contains(fieldId)) continue;
      await txn.insert('local_inspection_value', {
        'inspection_local_id': localId,
        'field_definition_id': fieldId,
        'value_text': value['value_text'],
        'value_number': value['value_number'],
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
      await txn.insert('local_photo', {
        'local_id': _uuid.v4(),
        'server_id': null,
        'inspection_local_id': localId,
        'damage_local_id': sourceDamage == null ? null : damageMap[sourceDamage],
        'source_server_id': '${photo['id']}',
        'photo_type': '${photo['photo_type']}',
        'local_path': null,
        'storage_key': photo['storage_key'],
        'captured_at': photo['captured_at'] ?? DateTime.now().toUtc().toIso8601String(),
        'baseline': 1,
      });
    }
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

  Future<void> saveInspectionValue(String localId, String fieldId, Map<String, dynamic> value, List<String> optionIds) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('local_inspection_value', {
        'inspection_local_id': localId,
        'field_definition_id': fieldId,
        'value_text': value['value_text'],
        'value_number': value['value_number'],
        'value_boolean': value['value_boolean'],
        'value_date': value['value_date'],
        'value_datetime': value['value_datetime'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('local_inspection_value_option', where: 'inspection_local_id = ? AND field_definition_id = ?', whereArgs: [localId, fieldId]);
      for (final optionId in optionIds) {
        await txn.insert('local_inspection_value_option', {
          'inspection_local_id': localId,
          'field_definition_id': fieldId,
          'option_id': optionId,
        });
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
    await db.insert('local_damage', {
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
    await db.insert('local_photo', {
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

  Future<void> addSignature({required String inspectionLocalId, required String signerName, String? signerRole, required String localPath}) async {
    final db = await _db;
    await db.insert('local_signature', {
      'local_id': _uuid.v4(),
      'server_id': null,
      'inspection_local_id': inspectionLocalId,
      'signer_name': signerName,
      'signer_role': signerRole,
      'local_path': localPath,
      'storage_key': null,
      'signed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> updateSignatureUpload(String localId, {required String serverId, required String storageKey}) async {
    final db = await _db;
    await db.update('local_signature', {'server_id': serverId, 'storage_key': storageKey}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markInspectionServerId(String localId, String serverId) async {
    final db = await _db;
    await db.update('local_inspection', {'server_id': serverId, 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markInspectionLocalComplete(String localId) async {
    final db = await _db;
    await db.update('local_inspection', {'status': 'COMPLETED_LOCAL', 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
    await enqueue('SYNC_INSPECTION', localId);
  }

  Future<void> markInspectionSynced(String localId) async {
    final db = await _db;
    await db.update('local_inspection', {'status': 'SYNCED', 'updated_at': DateTime.now().toUtc().toIso8601String()}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> enqueue(String type, String entityId) async {
    final db = await _db;
    final existing = await db.query('sync_operation', where: 'operation_type = ? AND entity_id = ? AND state IN (?, ?)', whereArgs: [type, entityId, 'PENDING', 'RUNNING'], limit: 1);
    if (existing.isNotEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('sync_operation', {
      'id': _uuid.v4(),
      'operation_type': type,
      'entity_id': entityId,
      'state': 'PENDING',
      'attempts': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<SyncOperation>> pendingOperations() async {
    final db = await _db;
    final rows = await db.query('sync_operation', where: 'state IN (?, ?)', whereArgs: ['PENDING', 'ERROR'], orderBy: 'created_at');
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
      ]) {
        await txn.delete(table);
      }
    });
  }
}

extension LocalRepositoryEditing on LocalRepository {
  Future<void> deletePhoto(String photoLocalId) async {
    final db = await _db;
    final rows = await db.query('local_photo', where: 'local_id = ?', whereArgs: [photoLocalId], limit: 1);
    if (rows.isEmpty || rows.first['baseline'] == 1) return;
    await db.delete('local_photo', where: 'local_id = ?', whereArgs: [photoLocalId]);
  }

  Future<void> deleteDamage(String damageLocalId) async {
    final db = await _db;
    final rows = await db.query('local_damage', where: 'local_id = ?', whereArgs: [damageLocalId], limit: 1);
    if (rows.isEmpty || rows.first['baseline'] == 1) return;
    await db.transaction((txn) async {
      await txn.delete('local_photo', where: 'damage_local_id = ? AND baseline = 0', whereArgs: [damageLocalId]);
      await txn.delete('local_damage', where: 'local_id = ?', whereArgs: [damageLocalId]);
    });
  }

  Future<void> deleteSignature(String signatureLocalId) async {
    final db = await _db;
    await db.delete('local_signature', where: 'local_id = ?', whereArgs: [signatureLocalId]);
  }
}
