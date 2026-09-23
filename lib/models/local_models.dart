class LocalInspectionDraft {
  const LocalInspectionDraft({
    required this.localId,
    required this.legKey,
    required this.formTypeId,
    required this.inspectionType,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.serverId,
    this.copyFromServerId,
    this.copyFromLocalId,
  });

  final String localId;
  final String? serverId;
  final String legKey;
  final String formTypeId;
  final String inspectionType;
  final String? copyFromServerId;
  /// Lokális forrás: a feltöltéskor ennek a szerveroldali példányából másol a szerver.
  final String? copyFromLocalId;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory LocalInspectionDraft.fromMap(Map<String, dynamic> row) => LocalInspectionDraft(
        localId: '${row['local_id']}',
        serverId: row['server_id']?.toString(),
        legKey: '${row['leg_key']}',
        formTypeId: '${row['form_type_id']}',
        inspectionType: '${row['inspection_type']}',
        copyFromServerId: row['copy_from_server_id']?.toString(),
        copyFromLocalId: row['copy_from_local_id']?.toString(),
        status: '${row['status']}',
        createdAt: DateTime.parse('${row['created_at']}'),
        updatedAt: DateTime.parse('${row['updated_at']}'),
      );
}

class LocalDamage {
  const LocalDamage({
    required this.localId,
    required this.inspectionLocalId,
    required this.description,
    required this.baseline,
    this.serverId,
    this.sourceServerId,
    this.damageType,
    this.location,
    this.severity,
    this.isPreexisting,
  });

  final String localId;
  final String? serverId;
  final String inspectionLocalId;
  final String? sourceServerId;
  final String? damageType;
  final String? location;
  final String description;
  final String? severity;
  final bool? isPreexisting;
  final bool baseline;

  factory LocalDamage.fromMap(Map<String, dynamic> row) => LocalDamage(
        localId: '${row['local_id']}',
        serverId: row['server_id']?.toString(),
        inspectionLocalId: '${row['inspection_local_id']}',
        sourceServerId: row['source_server_id']?.toString(),
        damageType: row['damage_type']?.toString(),
        location: row['location']?.toString(),
        description: '${row['description']}',
        severity: row['severity']?.toString(),
        isPreexisting: row['is_preexisting'] == null ? null : row['is_preexisting'] == 1,
        baseline: row['baseline'] == 1,
      );
}

class LocalPhoto {
  const LocalPhoto({
    required this.localId,
    required this.inspectionLocalId,
    required this.photoType,
    required this.capturedAt,
    required this.baseline,
    this.serverId,
    this.damageLocalId,
    this.sourceServerId,
    this.localPath,
    this.storageKey,
  });

  final String localId;
  final String? serverId;
  final String inspectionLocalId;
  final String? damageLocalId;
  final String? sourceServerId;
  final String photoType;
  final String? localPath;
  final String? storageKey;
  final DateTime capturedAt;
  final bool baseline;

  factory LocalPhoto.fromMap(Map<String, dynamic> row) => LocalPhoto(
        localId: '${row['local_id']}',
        serverId: row['server_id']?.toString(),
        inspectionLocalId: '${row['inspection_local_id']}',
        damageLocalId: row['damage_local_id']?.toString(),
        sourceServerId: row['source_server_id']?.toString(),
        photoType: '${row['photo_type']}',
        localPath: row['local_path']?.toString(),
        storageKey: row['storage_key']?.toString(),
        capturedAt: DateTime.parse('${row['captured_at']}'),
        baseline: row['baseline'] == 1,
      );
}

class LocalSignature {
  const LocalSignature({
    required this.localId,
    required this.inspectionLocalId,
    required this.signerName,
    required this.localPath,
    required this.signedAt,
    this.serverId,
    this.signerRole,
    this.storageKey,
  });

  final String localId;
  final String? serverId;
  final String inspectionLocalId;
  final String signerName;
  final String? signerRole;
  final String localPath;
  final String? storageKey;
  final DateTime signedAt;

  factory LocalSignature.fromMap(Map<String, dynamic> row) => LocalSignature(
        localId: '${row['local_id']}',
        serverId: row['server_id']?.toString(),
        inspectionLocalId: '${row['inspection_local_id']}',
        signerName: '${row['signer_name']}',
        signerRole: row['signer_role']?.toString(),
        localPath: '${row['local_path']}',
        storageKey: row['storage_key']?.toString(),
        signedAt: DateTime.parse('${row['signed_at']}'),
      );
}

class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.operationType,
    required this.entityId,
    this.legKey,
    required this.state,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
  });

  final String id;
  final String operationType;
  final String entityId;
  /// A szakasz, amelyhez a művelet tartozik — a sorrendiség ezen belül kötelező.
  final String? legKey;
  final String state;
  final int attempts;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SyncOperation.fromMap(Map<String, dynamic> row) => SyncOperation(
        id: '${row['id']}',
        operationType: '${row['operation_type']}',
        entityId: '${row['entity_id']}',
        legKey: row['leg_key']?.toString(),
        state: '${row['state']}',
        attempts: row['attempts'] as int? ?? 0,
        lastError: row['last_error']?.toString(),
        createdAt: DateTime.parse('${row['created_at']}'),
        updatedAt: DateTime.tryParse('${row['updated_at']}') ?? DateTime.parse('${row['created_at']}'),
      );
}

/// Egy szakasz szinkronállapota a sofőrnek: mi van még csak a telefonon.
enum LegSyncState { synced, pending, running, error, conflict }
