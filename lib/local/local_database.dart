import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'fleet_driver.db');
    _db = await openDatabase(
      path,
      version: 3,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _create,
      onUpgrade: _upgrade,
    );
    return _db!;
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE cached_leg (
        leg_key TEXT PRIMARY KEY,
        leg_id TEXT,
        status TEXT NOT NULL,
        sequence_no INTEGER NOT NULL,
        planned_start TEXT,
        planned_end TEXT,
        order_vehicle_id TEXT NOT NULL,
        registration_number TEXT NOT NULL,
        make TEXT,
        model TEXT,
        color TEXT,
        order_no TEXT NOT NULL,
        service_org_id TEXT NOT NULL,
        from_address TEXT NOT NULL,
        to_address TEXT NOT NULL,
        vehicle_user_name TEXT,
        vehicle_user_email TEXT,
        vehicle_user_phone TEXT,
        from_contact_name TEXT,
        from_contact_phone TEXT,
        to_contact_name TEXT,
        to_contact_phone TEXT,
        from_stop_type TEXT,
        to_stop_type TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE cached_form_type (
        id TEXT PRIMARY KEY,
        service_org_id TEXT NOT NULL,
        code TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE cached_form_field (
        binding_id TEXT PRIMARY KEY,
        form_type_id TEXT NOT NULL,
        field_definition_id TEXT NOT NULL,
        code TEXT NOT NULL,
        name TEXT NOT NULL,
        data_type TEXT NOT NULL,
        description TEXT,
        unit TEXT,
        required INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        phase TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE cached_form_option (
        id TEXT PRIMARY KEY,
        field_definition_id TEXT NOT NULL,
        code TEXT NOT NULL,
        label TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE cached_photo_requirement (
        id TEXT PRIMARY KEY,
        form_type_id TEXT NOT NULL,
        photo_type TEXT NOT NULL,
        phase TEXT NOT NULL,
        required INTEGER NOT NULL,
        min_count INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE previous_inspection (
        server_id TEXT PRIMARY KEY,
        leg_key TEXT NOT NULL,
        form_type_id TEXT NOT NULL,
        inspection_type TEXT NOT NULL,
        completed_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE previous_value (
        id TEXT PRIMARY KEY,
        inspection_server_id TEXT NOT NULL,
        field_definition_id TEXT NOT NULL,
        value_text TEXT,
        value_number TEXT,
        value_boolean INTEGER,
        value_date TEXT,
        value_datetime TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE previous_value_option (
        inspection_value_id TEXT NOT NULL,
        option_id TEXT NOT NULL,
        PRIMARY KEY (inspection_value_id, option_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE previous_damage (
        id TEXT PRIMARY KEY,
        inspection_server_id TEXT NOT NULL,
        damage_type TEXT,
        location TEXT,
        description TEXT NOT NULL,
        severity TEXT,
        is_preexisting INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE previous_photo (
        id TEXT PRIMARY KEY,
        inspection_server_id TEXT NOT NULL,
        damage_id TEXT,
        photo_type TEXT NOT NULL,
        storage_key TEXT,
        captured_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE local_inspection (
        local_id TEXT PRIMARY KEY,
        server_id TEXT,
        leg_key TEXT NOT NULL,
        form_type_id TEXT NOT NULL,
        inspection_type TEXT NOT NULL,
        copy_from_server_id TEXT,
        copy_from_local_id TEXT,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE local_inspection_value (
        inspection_local_id TEXT NOT NULL,
        field_definition_id TEXT NOT NULL,
        value_text TEXT,
        value_number TEXT,
        value_boolean INTEGER,
        value_date TEXT,
        value_datetime TEXT,
        PRIMARY KEY (inspection_local_id, field_definition_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE local_inspection_value_option (
        inspection_local_id TEXT NOT NULL,
        field_definition_id TEXT NOT NULL,
        option_id TEXT NOT NULL,
        PRIMARY KEY (inspection_local_id, field_definition_id, option_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE local_damage (
        local_id TEXT PRIMARY KEY,
        server_id TEXT,
        inspection_local_id TEXT NOT NULL,
        source_server_id TEXT,
        damage_type TEXT,
        location TEXT,
        description TEXT NOT NULL,
        severity TEXT,
        is_preexisting INTEGER,
        baseline INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE local_photo (
        local_id TEXT PRIMARY KEY,
        server_id TEXT,
        inspection_local_id TEXT NOT NULL,
        damage_local_id TEXT,
        source_server_id TEXT,
        photo_type TEXT NOT NULL,
        local_path TEXT,
        storage_key TEXT,
        captured_at TEXT NOT NULL,
        baseline INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE local_signature (
        local_id TEXT PRIMARY KEY,
        server_id TEXT,
        inspection_local_id TEXT NOT NULL,
        signer_name TEXT NOT NULL,
        signer_role TEXT,
        local_path TEXT NOT NULL,
        storage_key TEXT,
        signed_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_operation (
        id TEXT PRIMARY KEY,
        operation_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        leg_key TEXT,
        state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('CREATE INDEX idx_cached_leg_service ON cached_leg(service_org_id, status)');
    await db.execute('CREATE INDEX idx_local_inspection_leg ON local_inspection(leg_key, inspection_type)');
    await db.execute('CREATE INDEX idx_sync_operation_state ON sync_operation(state, created_at)');
  }

  /// v2: a sync sor szakaszonként rendezett (leg_key), a lokális forrásból
  /// másolt jegyzőkönyv a forrás szerveroldali példányából másol.
  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE sync_operation ADD COLUMN leg_key TEXT');
      await db.execute('ALTER TABLE local_inspection ADD COLUMN copy_from_local_id TEXT');
      await db.execute("UPDATE sync_operation SET leg_key = entity_id WHERE operation_type IN ('START_LEG','COMPLETE_LEG')");
      await db.execute('''
        UPDATE sync_operation
           SET leg_key = (SELECT leg_key FROM local_inspection WHERE local_id = sync_operation.entity_id)
         WHERE operation_type = 'SYNC_INSPECTION'
      ''');
    }
    // v3: a szakasz végpontjainak megállótípusa (körfuvar: WAIT).
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE cached_leg ADD COLUMN from_stop_type TEXT');
      await db.execute('ALTER TABLE cached_leg ADD COLUMN to_stop_type TEXT');
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
