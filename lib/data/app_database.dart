import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

enum AccountRole {
  owner,
  worker;

  static AccountRole parse(Object? value) {
    final String clean = (value ?? '').toString().trim().toLowerCase();
    return clean == worker.name ? worker : owner;
  }
}

class LocalFruit {
  const LocalFruit({
    required this.name,
    required this.iconKey,
    required this.price,
    required this.stock,
    required this.managed,
    this.dirty = false,
    this.updatedAt,
  });

  final String name;
  final String iconKey;
  final int price;
  final int stock;
  final bool managed;
  final bool dirty;
  final DateTime? updatedAt;

  factory LocalFruit.fromMap(Map<String, Object?> map) {
    return LocalFruit(
      name: map['name']! as String,
      iconKey: map['icon_key']! as String,
      price: map['price']! as int,
      stock: map['stock']! as int,
      managed: (map['managed']! as int) == 1,
      dirty: ((map['dirty'] as int?) ?? 0) == 1,
      updatedAt: DateTime.tryParse((map['updated_at'] as String?) ?? ''),
    );
  }
}

class LocalPriceChange {
  const LocalPriceChange({
    this.id,
    required this.fruitName,
    required this.oldPrice,
    required this.newPrice,
    required this.source,
    required this.actor,
    required this.deviceId,
    required this.note,
    required this.createdAt,
  });

  final int? id;
  final String fruitName;
  final int oldPrice;
  final int newPrice;
  final String source;
  final String actor;
  final String deviceId;
  final String note;
  final DateTime createdAt;

  factory LocalPriceChange.fromMap(Map<String, Object?> map) {
    return LocalPriceChange(
      id: map['id'] as int?,
      fruitName: map['fruit_name']! as String,
      oldPrice: map['old_price']! as int,
      newPrice: map['new_price']! as int,
      source: map['source']! as String,
      actor: map['actor']! as String,
      deviceId: map['device_id']! as String,
      note: map['note']! as String,
      createdAt: DateTime.parse(map['created_at']! as String),
    );
  }
}

class SeedFruit {
  const SeedFruit({
    required this.name,
    required this.iconKey,
    required this.price,
    required this.stock,
    required this.managed,
  });

  final String name;
  final String iconKey;
  final int price;
  final int stock;
  final bool managed;
}

class LocalAccount {
  const LocalAccount({
    required this.name,
    required this.email,
    required this.password,
    this.role = AccountRole.owner,
    this.ownerUid,
    this.firebaseUid,
  });

  final String name;
  final String email;
  final String password;
  final AccountRole role;
  final String? ownerUid;
  final String? firebaseUid;

  factory LocalAccount.fromMap(Map<String, Object?> map) {
    return LocalAccount(
      name: map['name']! as String,
      email: map['email']! as String,
      password: map['password']! as String,
      role: AccountRole.parse(map['role']),
      ownerUid: map['owner_uid'] as String?,
      firebaseUid: map['firebase_uid'] as String?,
    );
  }
}

class LocalSale {
  const LocalSale({
    this.id,
    this.cloudId,
    required this.fruitName,
    required this.weightGrams,
    required this.unitPrice,
    required this.totalPrice,
    required this.status,
    required this.soldAt,
    this.synced = false,
  });

  final int? id;
  final String? cloudId;
  final String fruitName;
  final int weightGrams;
  final int unitPrice;
  final int totalPrice;
  final String status;
  final DateTime soldAt;
  final bool synced;

  factory LocalSale.fromMap(Map<String, Object?> map) {
    return LocalSale(
      id: map['id'] as int?,
      cloudId: map['cloud_id'] as String?,
      fruitName: map['fruit_name']! as String,
      weightGrams: map['weight_grams']! as int,
      unitPrice: map['unit_price']! as int,
      totalPrice: map['total_price']! as int,
      status: map['status']! as String,
      soldAt: DateTime.parse(map['sold_at']! as String),
      synced: ((map['synced'] as int?) ?? 0) == 1,
    );
  }

  Map<String, Object?> toCloudMap({required String cloudId}) {
    return <String, Object?>{
      'cloudId': cloudId,
      'fruitName': fruitName,
      'weightGrams': weightGrams,
      'unitPrice': unitPrice,
      'totalPrice': totalPrice,
      'status': status,
      'soldAt': soldAt.toIso8601String(),
    };
  }
}

class LocalWorkerRequest {
  const LocalWorkerRequest({
    this.id,
    required this.requestId,
    required this.type,
    required this.status,
    required this.ownerUid,
    required this.workerUid,
    required this.workerName,
    this.saleCloudId,
    required this.originalPayload,
    required this.requestedPayload,
    required this.createdAt,
    this.reviewedAt,
    this.synced = false,
  });

  final int? id;
  final String requestId;
  final String type;
  final String status;
  final String ownerUid;
  final String workerUid;
  final String workerName;
  final String? saleCloudId;
  final String originalPayload;
  final String requestedPayload;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  final bool synced;

  factory LocalWorkerRequest.fromMap(Map<String, Object?> map) {
    return LocalWorkerRequest(
      id: map['id'] as int?,
      requestId: map['request_id']! as String,
      type: map['type']! as String,
      status: map['status']! as String,
      ownerUid: map['owner_uid']! as String,
      workerUid: map['worker_uid']! as String,
      workerName: map['worker_name']! as String,
      saleCloudId: map['sale_cloud_id'] as String?,
      originalPayload: map['original_payload']! as String,
      requestedPayload: map['requested_payload']! as String,
      createdAt: DateTime.parse(map['created_at']! as String),
      reviewedAt: DateTime.tryParse((map['reviewed_at'] as String?) ?? ''),
      synced: ((map['synced'] as int?) ?? 0) == 1,
    );
  }

  Map<String, Object?> get requestedData {
    return _decodeJsonObject(requestedPayload);
  }

  Map<String, Object?> get originalData {
    return _decodeJsonObject(originalPayload);
  }

  Map<String, Object?> toCloudMap() {
    return <String, Object?>{
      'requestId': requestId,
      'type': type,
      'status': status,
      'ownerUid': ownerUid,
      'workerUid': workerUid,
      'workerName': workerName,
      if (saleCloudId != null && saleCloudId!.isNotEmpty)
        'saleCloudId': saleCloudId,
      'originalPayload': originalData,
      'requestedPayload': requestedData,
      'createdAt': createdAt.toIso8601String(),
      if (reviewedAt != null) 'reviewedAt': reviewedAt!.toIso8601String(),
    };
  }

  static Map<String, Object?> _decodeJsonObject(String value) {
    if (value.trim().isEmpty) {
      return <String, Object?>{};
    }
    final Object? decoded = jsonDecode(value);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }
}

class AppDatabase {
  AppDatabase() : _memory = false;

  AppDatabase.inMemory() : _memory = true;

  final bool _memory;
  Database? _db;
  final Map<String, LocalFruit> _memoryFruits = <String, LocalFruit>{};
  final Map<String, LocalAccount> _memoryAccounts = <String, LocalAccount>{};
  final Map<String, String> _memorySettings = <String, String>{};
  final List<LocalSale> _memorySales = <LocalSale>[];
  final List<LocalPriceChange> _memoryPriceChanges = <LocalPriceChange>[];
  final List<LocalWorkerRequest> _memoryWorkerRequests = <LocalWorkerRequest>[];
  int _memorySaleId = 0;
  int _memoryPriceChangeId = 0;
  int _memoryWorkerRequestId = 0;

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> get _database async {
    final Database? current = _db;
    if (current != null) {
      return current;
    }

    final Database opened;
    if (_memory) {
      opened = await openDatabase(
        inMemoryDatabasePath,
        version: 6,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      );
    } else {
      final String dbPath = await getDatabasesPath();
      opened = await openDatabase(
        p.join(dbPath, 'fruityvens.sqlite'),
        version: 6,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      );
    }
    _db = opened;
    return opened;
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE local_fruits (
        name TEXT PRIMARY KEY,
        icon_key TEXT NOT NULL,
        price INTEGER NOT NULL,
        stock INTEGER NOT NULL,
        managed INTEGER NOT NULL DEFAULT 1,
        dirty INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE sales_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cloud_id TEXT UNIQUE,
        fruit_name TEXT NOT NULL,
        weight_grams INTEGER NOT NULL,
        unit_price INTEGER NOT NULL,
        total_price INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'sold',
        sold_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        processed_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_insights (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'local',
        requires_internet INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    await _createAuthSchema(db);
    await _createSettingsSchema(db);
    await _createPriceHistorySchema(db);
    await _createWorkerRequestSchema(db);
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createAuthSchema(db);
    }
    if (oldVersion < 3) {
      await _createSettingsSchema(db);
    }
    if (oldVersion < 4) {
      await _addColumnIfMissing(
        db,
        table: 'sales_transactions',
        column: 'cloud_id',
        definition: 'TEXT',
      );
    }
    if (oldVersion < 5) {
      await _addColumnIfMissing(
        db,
        table: 'local_fruits',
        column: 'dirty',
        definition: 'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        db,
        table: 'local_fruits',
        column: 'updated_at',
        definition: "TEXT NOT NULL DEFAULT ''",
      );
      await _createPriceHistorySchema(db);
      await db.execute(
        'UPDATE local_fruits SET price = price * 100 WHERE price > 0',
      );
      await db.execute(
        "UPDATE local_fruits SET updated_at = datetime('now') "
        "WHERE updated_at = ''",
      );
      await db.execute(
        'UPDATE sales_transactions SET unit_price = unit_price * 100, '
        'total_price = total_price * 100 WHERE total_price > 0',
      );
    }
    if (oldVersion < 6) {
      await _addColumnIfMissing(
        db,
        table: 'local_accounts',
        column: 'role',
        definition: "TEXT NOT NULL DEFAULT 'owner'",
      );
      await _addColumnIfMissing(
        db,
        table: 'local_accounts',
        column: 'owner_uid',
        definition: 'TEXT',
      );
      await _addColumnIfMissing(
        db,
        table: 'local_accounts',
        column: 'firebase_uid',
        definition: 'TEXT',
      );
      await _createWorkerRequestSchema(db);
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_transactions_cloud_id '
      'ON sales_transactions(cloud_id) WHERE cloud_id IS NOT NULL',
    );
  }

  Future<void> _addColumnIfMissing(
    Database db, {
    required String table,
    required String column,
    required String definition,
  }) async {
    final List<Map<String, Object?>> columns = await db.rawQuery(
      'PRAGMA table_info($table)',
    );
    final bool exists = columns.any(
      (Map<String, Object?> row) => row['name'] == column,
    );
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  Future<void> _createAuthSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_accounts (
        email TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        password TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'owner',
        owner_uid TEXT,
        firebase_uid TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createSettingsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createPriceHistorySchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS price_change_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fruit_name TEXT NOT NULL,
        old_price INTEGER NOT NULL,
        new_price INTEGER NOT NULL,
        source TEXT NOT NULL,
        actor TEXT NOT NULL,
        device_id TEXT NOT NULL,
        note TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createWorkerRequestSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS worker_requests (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        owner_uid TEXT NOT NULL,
        worker_uid TEXT NOT NULL,
        worker_name TEXT NOT NULL,
        sale_cloud_id TEXT,
        original_payload TEXT NOT NULL,
        requested_payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        reviewed_at TEXT,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> seedFruitCatalog(List<SeedFruit> fruits) async {
    if (_memory) {
      for (final SeedFruit fruit in fruits) {
        _memoryFruits.putIfAbsent(
          fruit.name,
          () => LocalFruit(
            name: fruit.name,
            iconKey: fruit.iconKey,
            price: fruit.price,
            stock: fruit.stock,
            managed: fruit.managed,
            updatedAt: DateTime.now(),
          ),
        );
      }
      return;
    }

    final Database db = await _database;
    final Batch batch = db.batch();
    final String now = DateTime.now().toIso8601String();
    for (final SeedFruit fruit in fruits) {
      batch.insert('local_fruits', <String, Object?>{
        'name': fruit.name,
        'icon_key': fruit.iconKey,
        'price': fruit.price,
        'stock': fruit.stock,
        'managed': fruit.managed ? 1 : 0,
        'dirty': 0,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<void> saveAccount({
    required String name,
    required String email,
    required String password,
    AccountRole role = AccountRole.owner,
    String? ownerUid,
    String? firebaseUid,
  }) async {
    final String cleanEmail = email.trim().toLowerCase();
    if (_memory) {
      _memoryAccounts[cleanEmail] = LocalAccount(
        name: name,
        email: cleanEmail,
        password: password,
        role: role,
        ownerUid: ownerUid,
        firebaseUid: firebaseUid,
      );
      return;
    }

    final Database db = await _database;
    final String now = DateTime.now().toIso8601String();
    await db.insert('local_accounts', <String, Object?>{
      'email': cleanEmail,
      'name': name,
      'password': password,
      'role': role.name,
      'owner_uid': ownerUid,
      'firebase_uid': firebaseUid,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<LocalAccount?> getAccountByEmail(String email) async {
    final String cleanEmail = email.trim().toLowerCase();
    if (_memory) {
      return _memoryAccounts[cleanEmail];
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'local_accounts',
      where: 'email = ?',
      whereArgs: <Object>[cleanEmail],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return LocalAccount.fromMap(rows.first);
  }

  Future<bool> accountExists(String email) async {
    final LocalAccount? account = await getAccountByEmail(email);
    return account != null;
  }

  Future<void> saveSetting(String key, String value) async {
    if (_memory) {
      _memorySettings[key] = value;
      return;
    }

    final Database db = await _database;
    await db.insert('app_settings', <String, Object?>{
      'key': key,
      'value': value,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    if (_memory) {
      return _memorySettings[key];
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'app_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object>[key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value']! as String;
  }

  Future<List<LocalFruit>> getManagedFruits() async {
    if (_memory) {
      return _memoryFruits.values
          .where((LocalFruit fruit) => fruit.managed)
          .toList()
        ..sort((LocalFruit a, LocalFruit b) => a.name.compareTo(b.name));
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'local_fruits',
      where: 'managed = ?',
      whereArgs: <Object>[1],
      orderBy: 'name ASC',
    );
    return rows.map(LocalFruit.fromMap).toList();
  }

  Future<void> saveManagedFruit({
    required String name,
    required String iconKey,
    required int price,
    required int stock,
  }) async {
    if (_memory) {
      _memoryFruits[name] = LocalFruit(
        name: name,
        iconKey: iconKey,
        price: price,
        stock: stock,
        managed: true,
        dirty: true,
        updatedAt: DateTime.now(),
      );
      return;
    }

    final Database db = await _database;
    final String now = DateTime.now().toIso8601String();
    await db.insert('local_fruits', <String, Object?>{
      'name': name,
      'icon_key': iconKey,
      'price': price,
      'stock': stock,
      'managed': 1,
      'dirty': 1,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await enqueueSync(
      entityType: 'fruit',
      entityId: name,
      action: 'upsert',
      payload: '{"name":"$name","price":$price,"stock":$stock}',
    );
  }

  Future<void> saveManagedFruitFromCloud({
    required String name,
    required String iconKey,
    required int price,
    required int stock,
    required bool managed,
  }) async {
    if (_memory) {
      _memoryFruits[name] = LocalFruit(
        name: name,
        iconKey: iconKey,
        price: price,
        stock: stock,
        managed: managed,
        updatedAt: DateTime.now(),
      );
      return;
    }

    final Database db = await _database;
    await db.insert('local_fruits', <String, Object?>{
      'name': name,
      'icon_key': iconKey,
      'price': price,
      'stock': stock,
      'managed': managed ? 1 : 0,
      'dirty': 0,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateFruitPrice(String name, int price) async {
    if (_memory) {
      final LocalFruit? fruit = _memoryFruits[name];
      if (fruit != null) {
        _memoryFruits[name] = LocalFruit(
          name: fruit.name,
          iconKey: fruit.iconKey,
          price: price,
          stock: fruit.stock,
          managed: fruit.managed,
          dirty: true,
          updatedAt: DateTime.now(),
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'local_fruits',
      <String, Object?>{
        'price': price,
        'dirty': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'name = ?',
      whereArgs: <Object>[name],
    );
    await enqueueSync(
      entityType: 'fruit',
      entityId: name,
      action: 'price_update',
      payload: '{"name":"$name","price":$price}',
    );
  }

  Future<void> updateFruitInventory({
    required String name,
    required int price,
    required int stock,
  }) async {
    if (_memory) {
      final LocalFruit? fruit = _memoryFruits[name];
      if (fruit != null) {
        _memoryFruits[name] = LocalFruit(
          name: fruit.name,
          iconKey: fruit.iconKey,
          price: price,
          stock: stock,
          managed: fruit.managed,
          dirty: true,
          updatedAt: DateTime.now(),
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'local_fruits',
      <String, Object?>{
        'price': price,
        'stock': stock,
        'dirty': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'name = ?',
      whereArgs: <Object>[name],
    );
    await enqueueSync(
      entityType: 'fruit',
      entityId: name,
      action: 'inventory_update',
      payload: '{"name":"$name","price":$price,"stock":$stock}',
    );
  }

  Future<void> hideManagedFruit(String name) async {
    if (_memory) {
      final LocalFruit? fruit = _memoryFruits[name];
      if (fruit != null) {
        _memoryFruits[name] = LocalFruit(
          name: fruit.name,
          iconKey: fruit.iconKey,
          price: fruit.price,
          stock: fruit.stock,
          managed: false,
          dirty: true,
          updatedAt: DateTime.now(),
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'local_fruits',
      <String, Object?>{
        'managed': 0,
        'dirty': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'name = ?',
      whereArgs: <Object>[name],
    );
    await enqueueSync(
      entityType: 'fruit',
      entityId: name,
      action: 'remove',
      payload: '{"name":"$name"}',
    );
  }

  Future<int> addSale({
    String? cloudId,
    required String fruitName,
    required int weightGrams,
    required int unitPrice,
    required int totalPrice,
    String status = 'sold',
    DateTime? soldAt,
  }) async {
    final DateTime effectiveSoldAt = soldAt ?? DateTime.now();
    if (_memory) {
      if (cloudId != null) {
        for (final LocalSale sale in _memorySales) {
          if (sale.cloudId == cloudId && sale.id != null) {
            return sale.id!;
          }
        }
      }
      _memorySaleId += 1;
      _memorySales.insert(
        0,
        LocalSale(
          id: _memorySaleId,
          cloudId: cloudId,
          fruitName: fruitName,
          weightGrams: weightGrams,
          unitPrice: unitPrice,
          totalPrice: totalPrice,
          status: status,
          soldAt: effectiveSoldAt,
        ),
      );
      return _memorySaleId;
    }

    final Database db = await _database;
    if (cloudId != null) {
      final List<Map<String, Object?>> rows = await db.query(
        'sales_transactions',
        columns: <String>['id'],
        where: 'cloud_id = ?',
        whereArgs: <Object>[cloudId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return rows.first['id']! as int;
      }
    }
    final int id = await db.insert('sales_transactions', <String, Object?>{
      'cloud_id': cloudId,
      'fruit_name': fruitName,
      'weight_grams': weightGrams,
      'unit_price': unitPrice,
      'total_price': totalPrice,
      'status': status,
      'sold_at': effectiveSoldAt.toIso8601String(),
      'synced': 0,
    });
    await enqueueSync(
      entityType: 'transaction',
      entityId: id.toString(),
      action: 'insert',
      payload:
          '{"fruitName":"$fruitName","weightGrams":$weightGrams,"unitPrice":$unitPrice,"totalPrice":$totalPrice,"status":"$status","soldAt":"${effectiveSoldAt.toIso8601String()}"}',
    );
    return id;
  }

  Future<List<LocalSale>> getSalesTransactions({int? limit}) async {
    if (_memory) {
      final List<LocalSale> sales = List<LocalSale>.of(_memorySales);
      return limit == null ? sales : sales.take(limit).toList();
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'sales_transactions',
      orderBy: 'sold_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(LocalSale.fromMap).toList();
  }

  Future<void> updateSaleStatus({
    required int id,
    required String status,
  }) async {
    final String cleanStatus = status.trim().toLowerCase();
    if (cleanStatus.isEmpty) {
      return;
    }

    if (_memory) {
      final int index = _memorySales.indexWhere(
        (LocalSale sale) => sale.id == id,
      );
      if (index < 0) {
        return;
      }
      final LocalSale sale = _memorySales[index];
      _memorySales[index] = LocalSale(
        id: sale.id,
        cloudId: sale.cloudId,
        fruitName: sale.fruitName,
        weightGrams: sale.weightGrams,
        unitPrice: sale.unitPrice,
        totalPrice: sale.totalPrice,
        status: cleanStatus,
        soldAt: sale.soldAt,
        synced: false,
      );
      return;
    }

    final Database db = await _database;
    final int updated = await db.update(
      'sales_transactions',
      <String, Object?>{'status': cleanStatus, 'synced': 0},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    if (updated == 0) {
      return;
    }
    await enqueueSync(
      entityType: 'transaction',
      entityId: id.toString(),
      action: 'status_update',
      payload: '{"id":$id,"status":"$cleanStatus"}',
    );
  }

  Future<void> updateSale({
    int? id,
    String? cloudId,
    required String fruitName,
    required int weightGrams,
    required int unitPrice,
    required int totalPrice,
    required String status,
    required DateTime soldAt,
  }) async {
    final String cleanStatus = status.trim().toLowerCase();
    if (cleanStatus.isEmpty || (id == null && (cloudId ?? '').isEmpty)) {
      return;
    }

    if (_memory) {
      final int index = _memorySales.indexWhere((LocalSale sale) {
        if (id != null) {
          return sale.id == id;
        }
        return sale.cloudId == cloudId;
      });
      if (index < 0) {
        return;
      }
      final LocalSale sale = _memorySales[index];
      _memorySales[index] = LocalSale(
        id: sale.id,
        cloudId: sale.cloudId ?? cloudId,
        fruitName: fruitName,
        weightGrams: weightGrams,
        unitPrice: unitPrice,
        totalPrice: totalPrice,
        status: cleanStatus,
        soldAt: soldAt,
        synced: false,
      );
      _memorySales.sort((LocalSale a, LocalSale b) {
        return b.soldAt.compareTo(a.soldAt);
      });
      return;
    }

    final Database db = await _database;
    final String where = id != null ? 'id = ?' : 'cloud_id = ?';
    final List<Object> whereArgs = <Object>[id ?? cloudId!];
    final int updated = await db.update(
      'sales_transactions',
      <String, Object?>{
        if (cloudId != null && cloudId.isNotEmpty) 'cloud_id': cloudId,
        'fruit_name': fruitName,
        'weight_grams': weightGrams,
        'unit_price': unitPrice,
        'total_price': totalPrice,
        'status': cleanStatus,
        'sold_at': soldAt.toIso8601String(),
        'synced': 0,
      },
      where: where,
      whereArgs: whereArgs,
    );
    if (updated == 0) {
      return;
    }
    await enqueueSync(
      entityType: 'transaction',
      entityId: (id ?? cloudId!).toString(),
      action: 'sale_update',
      payload: jsonEncode(<String, Object?>{
        if (id != null) 'id': id,
        if (cloudId != null) 'cloudId': cloudId,
        'fruitName': fruitName,
        'weightGrams': weightGrams,
        'unitPrice': unitPrice,
        'totalPrice': totalPrice,
        'status': cleanStatus,
        'soldAt': soldAt.toIso8601String(),
      }),
    );
  }

  Future<LocalSale?> getSaleById(int id) async {
    if (_memory) {
      for (final LocalSale sale in _memorySales) {
        if (sale.id == id) {
          return sale;
        }
      }
      return null;
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'sales_transactions',
      where: 'id = ?',
      whereArgs: <Object>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return LocalSale.fromMap(rows.first);
  }

  Future<LocalSale?> getSaleByCloudId(String cloudId) async {
    if (_memory) {
      for (final LocalSale sale in _memorySales) {
        if (sale.cloudId == cloudId) {
          return sale;
        }
      }
      return null;
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'sales_transactions',
      where: 'cloud_id = ?',
      whereArgs: <Object>[cloudId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return LocalSale.fromMap(rows.first);
  }

  Future<bool> saleExistsByCloudId(String cloudId) async {
    if (_memory) {
      return _memorySales.any((LocalSale sale) => sale.cloudId == cloudId);
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'sales_transactions',
      columns: <String>['id'],
      where: 'cloud_id = ?',
      whereArgs: <Object>[cloudId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<LocalFruit?> getManagedFruit(String name) async {
    if (_memory) {
      return _memoryFruits[name];
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'local_fruits',
      where: 'name = ?',
      whereArgs: <Object>[name],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return LocalFruit.fromMap(rows.first);
  }

  Future<void> markFruitSynced(String name) async {
    if (_memory) {
      final LocalFruit? fruit = _memoryFruits[name];
      if (fruit != null) {
        _memoryFruits[name] = LocalFruit(
          name: fruit.name,
          iconKey: fruit.iconKey,
          price: fruit.price,
          stock: fruit.stock,
          managed: fruit.managed,
          dirty: false,
          updatedAt: fruit.updatedAt,
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'local_fruits',
      <String, Object?>{'dirty': 0},
      where: 'name = ?',
      whereArgs: <Object>[name],
    );
  }

  Future<void> markManagedFruitsSynced() async {
    if (_memory) {
      for (final MapEntry<String, LocalFruit> entry in _memoryFruits.entries) {
        final LocalFruit fruit = entry.value;
        if (!fruit.managed) {
          continue;
        }
        _memoryFruits[entry.key] = LocalFruit(
          name: fruit.name,
          iconKey: fruit.iconKey,
          price: fruit.price,
          stock: fruit.stock,
          managed: fruit.managed,
          dirty: false,
          updatedAt: fruit.updatedAt,
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'local_fruits',
      <String, Object?>{'dirty': 0},
      where: 'managed = ?',
      whereArgs: <Object>[1],
    );
  }

  Future<void> recordPriceChange({
    required String fruitName,
    required int oldPrice,
    required int newPrice,
    required String source,
    required String actor,
    required String deviceId,
    String note = '',
  }) async {
    if (oldPrice == newPrice) {
      return;
    }
    final DateTime now = DateTime.now();
    if (_memory) {
      _memoryPriceChangeId += 1;
      _memoryPriceChanges.insert(
        0,
        LocalPriceChange(
          id: _memoryPriceChangeId,
          fruitName: fruitName,
          oldPrice: oldPrice,
          newPrice: newPrice,
          source: source,
          actor: actor,
          deviceId: deviceId,
          note: note,
          createdAt: now,
        ),
      );
      return;
    }

    final Database db = await _database;
    await db.insert('price_change_history', <String, Object?>{
      'fruit_name': fruitName,
      'old_price': oldPrice,
      'new_price': newPrice,
      'source': source,
      'actor': actor,
      'device_id': deviceId,
      'note': note,
      'created_at': now.toIso8601String(),
    });
  }

  Future<List<LocalPriceChange>> getPriceChangeHistory({int? limit}) async {
    if (_memory) {
      final List<LocalPriceChange> changes = List<LocalPriceChange>.of(
        _memoryPriceChanges,
      );
      return limit == null ? changes : changes.take(limit).toList();
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'price_change_history',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(LocalPriceChange.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> getSalesSyncPayloads({
    required String deviceId,
  }) async {
    if (_memory) {
      for (int index = 0; index < _memorySales.length; index++) {
        final LocalSale sale = _memorySales[index];
        final String cloudId = sale.cloudId ?? '${deviceId}_${sale.id ?? 0}';
        if (sale.cloudId == null || !sale.synced) {
          _memorySales[index] = LocalSale(
            id: sale.id,
            cloudId: cloudId,
            fruitName: sale.fruitName,
            weightGrams: sale.weightGrams,
            unitPrice: sale.unitPrice,
            totalPrice: sale.totalPrice,
            status: sale.status,
            soldAt: sale.soldAt,
            synced: true,
          );
        }
      }
      return _memorySales
          .map((LocalSale sale) => sale.toCloudMap(cloudId: sale.cloudId!))
          .toList();
    }

    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      'sales_transactions',
      orderBy: 'sold_at ASC, id ASC',
    );
    final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
    final Batch batch = db.batch();
    for (final Map<String, Object?> row in rows) {
      final LocalSale sale = LocalSale.fromMap(row);
      final int? id = sale.id;
      if (id == null) {
        continue;
      }
      final String cloudId =
          sale.cloudId ?? '${deviceId}_${id.toString().padLeft(8, '0')}';
      if (sale.cloudId == null || !sale.synced) {
        batch.update(
          'sales_transactions',
          <String, Object?>{'cloud_id': cloudId, 'synced': 1},
          where: 'id = ?',
          whereArgs: <Object>[id],
        );
      }
      payloads.add(sale.toCloudMap(cloudId: cloudId));
    }
    await batch.commit(noResult: true);
    return payloads;
  }

  Future<void> saveSaleFromCloud(Map<String, Object?> sale) async {
    final String? cloudId = sale['cloudId'] as String?;
    final String? fruitName = sale['fruitName'] as String?;
    final int? weightGrams = _intValue(sale['weightGrams']);
    final int? unitPrice = _intValue(sale['unitPrice']);
    final int? totalPrice = _intValue(sale['totalPrice']);
    final String status = sale['status'] as String? ?? 'sold';
    final String? soldAt = sale['soldAt'] as String?;
    if (cloudId == null ||
        cloudId.isEmpty ||
        fruitName == null ||
        fruitName.isEmpty ||
        weightGrams == null ||
        unitPrice == null ||
        totalPrice == null ||
        soldAt == null ||
        DateTime.tryParse(soldAt) == null) {
      return;
    }

    if (_memory) {
      final int existingIndex = _memorySales.indexWhere(
        (LocalSale local) => local.cloudId == cloudId,
      );
      final LocalSale localSale = LocalSale(
        id: existingIndex >= 0 ? _memorySales[existingIndex].id : null,
        cloudId: cloudId,
        fruitName: fruitName,
        weightGrams: weightGrams,
        unitPrice: unitPrice,
        totalPrice: totalPrice,
        status: status,
        soldAt: DateTime.parse(soldAt),
        synced: true,
      );
      if (existingIndex >= 0) {
        _memorySales[existingIndex] = localSale;
      } else {
        _memorySales.add(localSale);
        _memorySales.sort((LocalSale a, LocalSale b) {
          return b.soldAt.compareTo(a.soldAt);
        });
      }
      return;
    }

    final Database db = await _database;
    await db.insert('sales_transactions', <String, Object?>{
      'cloud_id': cloudId,
      'fruit_name': fruitName,
      'weight_grams': weightGrams,
      'unit_price': unitPrice,
      'total_price': totalPrice,
      'status': status,
      'sold_at': soldAt,
      'synced': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveWorkerRequest({
    required String requestId,
    required String type,
    required String status,
    required String ownerUid,
    required String workerUid,
    required String workerName,
    String? saleCloudId,
    Map<String, Object?> originalPayload = const <String, Object?>{},
    required Map<String, Object?> requestedPayload,
    DateTime? createdAt,
    DateTime? reviewedAt,
    bool synced = false,
  }) async {
    final DateTime effectiveCreatedAt = createdAt ?? DateTime.now();
    final String originalJson = jsonEncode(originalPayload);
    final String requestedJson = jsonEncode(requestedPayload);
    if (_memory) {
      final int existingIndex = _memoryWorkerRequests.indexWhere(
        (LocalWorkerRequest request) => request.requestId == requestId,
      );
      final LocalWorkerRequest request = LocalWorkerRequest(
        id: existingIndex >= 0
            ? _memoryWorkerRequests[existingIndex].id
            : ++_memoryWorkerRequestId,
        requestId: requestId,
        type: type,
        status: status,
        ownerUid: ownerUid,
        workerUid: workerUid,
        workerName: workerName,
        saleCloudId: saleCloudId,
        originalPayload: originalJson,
        requestedPayload: requestedJson,
        createdAt: effectiveCreatedAt,
        reviewedAt: reviewedAt,
        synced: synced,
      );
      if (existingIndex >= 0) {
        _memoryWorkerRequests[existingIndex] = request;
      } else {
        _memoryWorkerRequests.insert(0, request);
      }
      return;
    }

    final Database db = await _database;
    await db.insert('worker_requests', <String, Object?>{
      'request_id': requestId,
      'type': type,
      'status': status,
      'owner_uid': ownerUid,
      'worker_uid': workerUid,
      'worker_name': workerName,
      'sale_cloud_id': saleCloudId,
      'original_payload': originalJson,
      'requested_payload': requestedJson,
      'created_at': effectiveCreatedAt.toIso8601String(),
      'reviewed_at': reviewedAt?.toIso8601String(),
      'synced': synced ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveWorkerRequestFromCloud(Map<String, Object?> request) async {
    final String? requestId = request['requestId'] as String?;
    final String? type = request['type'] as String?;
    final String? status = request['status'] as String?;
    final String? ownerUid = request['ownerUid'] as String?;
    final String? workerUid = request['workerUid'] as String?;
    final String workerName = request['workerName'] as String? ?? 'Worker';
    final String? createdAt = request['createdAt'] as String?;
    if (requestId == null ||
        requestId.isEmpty ||
        type == null ||
        type.isEmpty ||
        status == null ||
        status.isEmpty ||
        ownerUid == null ||
        ownerUid.isEmpty ||
        workerUid == null ||
        workerUid.isEmpty ||
        createdAt == null ||
        DateTime.tryParse(createdAt) == null) {
      return;
    }

    await saveWorkerRequest(
      requestId: requestId,
      type: type,
      status: status,
      ownerUid: ownerUid,
      workerUid: workerUid,
      workerName: workerName,
      saleCloudId: request['saleCloudId'] as String?,
      originalPayload: _mapValue(request['originalPayload']),
      requestedPayload: _mapValue(request['requestedPayload']),
      createdAt: DateTime.parse(createdAt),
      reviewedAt: DateTime.tryParse((request['reviewedAt'] as String?) ?? ''),
      synced: true,
    );
  }

  Future<List<LocalWorkerRequest>> getWorkerRequests({
    String? status,
    String? ownerUid,
  }) async {
    if (_memory) {
      final String? cleanStatus = status?.trim().toLowerCase();
      final List<LocalWorkerRequest> requests = _memoryWorkerRequests.where((
        LocalWorkerRequest request,
      ) {
        return (cleanStatus == null || request.status == cleanStatus) &&
            (ownerUid == null || request.ownerUid == ownerUid);
      }).toList();
      requests.sort((LocalWorkerRequest a, LocalWorkerRequest b) {
        return b.createdAt.compareTo(a.createdAt);
      });
      return requests;
    }

    final Database db = await _database;
    final List<String> whereParts = <String>[];
    final List<Object> whereArgs = <Object>[];
    if (status != null && status.trim().isNotEmpty) {
      whereParts.add('status = ?');
      whereArgs.add(status.trim().toLowerCase());
    }
    if (ownerUid != null && ownerUid.trim().isNotEmpty) {
      whereParts.add('owner_uid = ?');
      whereArgs.add(ownerUid.trim());
    }
    final List<Map<String, Object?>> rows = await db.query(
      'worker_requests',
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(LocalWorkerRequest.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> getWorkerRequestSyncPayloads({
    required String ownerUid,
  }) async {
    final List<LocalWorkerRequest> requests;
    if (_memory) {
      requests = _memoryWorkerRequests
          .where(
            (LocalWorkerRequest request) =>
                request.ownerUid == ownerUid && !request.synced,
          )
          .toList();
    } else {
      final Database db = await _database;
      final List<Map<String, Object?>> rows = await db.query(
        'worker_requests',
        where: 'owner_uid = ? AND synced = ?',
        whereArgs: <Object>[ownerUid, 0],
        orderBy: 'created_at ASC, id ASC',
      );
      requests = rows.map(LocalWorkerRequest.fromMap).toList();
    }
    return requests
        .map((LocalWorkerRequest request) => request.toCloudMap())
        .toList();
  }

  Future<void> markWorkerRequestSynced(String requestId) async {
    if (_memory) {
      final int index = _memoryWorkerRequests.indexWhere(
        (LocalWorkerRequest request) => request.requestId == requestId,
      );
      if (index >= 0) {
        final LocalWorkerRequest request = _memoryWorkerRequests[index];
        _memoryWorkerRequests[index] = LocalWorkerRequest(
          id: request.id,
          requestId: request.requestId,
          type: request.type,
          status: request.status,
          ownerUid: request.ownerUid,
          workerUid: request.workerUid,
          workerName: request.workerName,
          saleCloudId: request.saleCloudId,
          originalPayload: request.originalPayload,
          requestedPayload: request.requestedPayload,
          createdAt: request.createdAt,
          reviewedAt: request.reviewedAt,
          synced: true,
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'worker_requests',
      <String, Object?>{'synced': 1},
      where: 'request_id = ?',
      whereArgs: <Object>[requestId],
    );
  }

  Future<void> updateWorkerRequestStatus({
    required String requestId,
    required String status,
    DateTime? reviewedAt,
  }) async {
    final String cleanStatus = status.trim().toLowerCase();
    if (cleanStatus.isEmpty) {
      return;
    }
    final DateTime effectiveReviewedAt = reviewedAt ?? DateTime.now();
    if (_memory) {
      final int index = _memoryWorkerRequests.indexWhere(
        (LocalWorkerRequest request) => request.requestId == requestId,
      );
      if (index >= 0) {
        final LocalWorkerRequest request = _memoryWorkerRequests[index];
        _memoryWorkerRequests[index] = LocalWorkerRequest(
          id: request.id,
          requestId: request.requestId,
          type: request.type,
          status: cleanStatus,
          ownerUid: request.ownerUid,
          workerUid: request.workerUid,
          workerName: request.workerName,
          saleCloudId: request.saleCloudId,
          originalPayload: request.originalPayload,
          requestedPayload: request.requestedPayload,
          createdAt: request.createdAt,
          reviewedAt: effectiveReviewedAt,
          synced: false,
        );
      }
      return;
    }

    final Database db = await _database;
    await db.update(
      'worker_requests',
      <String, Object?>{
        'status': cleanStatus,
        'reviewed_at': effectiveReviewedAt.toIso8601String(),
        'synced': 0,
      },
      where: 'request_id = ?',
      whereArgs: <Object>[requestId],
    );
  }

  int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  Map<String, Object?> _mapValue(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    return <String, Object?>{};
  }

  Future<void> enqueueSync({
    required String entityType,
    required String entityId,
    required String action,
    required String payload,
  }) async {
    if (_memory) {
      return;
    }

    final Database db = await _database;
    await db.insert('sync_queue', <String, Object?>{
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'payload': payload,
      'attempts': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }
}
