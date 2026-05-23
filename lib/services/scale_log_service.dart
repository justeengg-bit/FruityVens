import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

class ScaleSaleLog {
  const ScaleSaleLog({
    required this.databaseKey,
    required this.id,
    required this.fruitName,
    required this.weightGrams,
    required this.priceCentavos,
    required this.pricePerKgCentavos,
    required this.soldAt,
    required this.source,
    required this.dedupeKey,
  });

  final String databaseKey;
  final int id;
  final String fruitName;
  final int weightGrams;
  final int priceCentavos;
  final int pricePerKgCentavos;
  final DateTime soldAt;
  final String source;
  final String dedupeKey;

  String cloudId(String scaleDeviceId) {
    final String normalizedSource = scaleDeviceId
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String normalizedLogKey = dedupeKey
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'scale_${normalizedSource}_$normalizedLogKey';
  }

  factory ScaleSaleLog.fromFirebase({
    required String databaseKey,
    required Map<String, Object?> json,
  }) {
    final int id = _requiredInt(json['id'], 'id');
    final int weightGrams = _requiredCentavosSafeInt(
      json['weightGrams'] ?? json['weight'],
      'weightGrams',
    );
    final int priceCentavos = _moneyToCentavos(
      json['priceCentavos'] ?? json['price'],
      centsWhenInteger: json.containsKey('priceCentavos'),
    );
    final int pricePerKgCentavos = _moneyToCentavos(
      json['pricePerKgCentavos'] ?? json['pricePerKg'],
      centsWhenInteger: json.containsKey('pricePerKgCentavos'),
    );
    final String fruitName =
        _stringValue(json['fruitType']) ??
        _stringValue(json['fruit']) ??
        _stringValue(json['fruitName']) ??
        _stringValue(json['fruit_type']) ??
        'Unknown';
    final String source =
        _stringValue(json['sourceDeviceId']) ??
        _stringValue(json['source']) ??
        'scale';
    final String? soldAtValue =
        _stringValue(json['soldAt']) ?? _stringValue(json['timestamp']);
    final String? date = _stringValue(json['date']);
    final String? time = _stringValue(json['time']);
    final String dateTimeKey = soldAtValue ?? '${date ?? ''}T${time ?? ''}';
    final DateTime soldAt =
        DateTime.tryParse(soldAtValue ?? '') ??
        DateTime.tryParse(dateTimeKey) ??
        DateTime.now();
    final String cleanFruitName = fruitName.trim().isEmpty
        ? 'Unknown'
        : fruitName.trim();

    return ScaleSaleLog(
      databaseKey: databaseKey,
      id: id,
      fruitName: cleanFruitName,
      weightGrams: weightGrams,
      priceCentavos: priceCentavos,
      pricePerKgCentavos: pricePerKgCentavos,
      soldAt: soldAt,
      source: source,
      dedupeKey:
          '$databaseKey|$id|${dateTimeKey.trim().isEmpty ? 'no_timestamp' : dateTimeKey}|$cleanFruitName|$weightGrams|$priceCentavos|$source',
    );
  }

  static int _requiredInt(Object? value, String field) {
    final int? parsed = _intValue(value);
    if (parsed == null) {
      throw ScaleLogException('Scale sale is missing $field.');
    }
    return parsed;
  }

  static int _requiredCentavosSafeInt(Object? value, String field) {
    final num? parsed = _numValue(value);
    if (parsed == null) {
      throw ScaleLogException('Scale sale is missing $field.');
    }
    return parsed.round();
  }

  static int _moneyToCentavos(Object? value, {bool centsWhenInteger = false}) {
    final num? parsed = _numValue(value);
    if (parsed == null) {
      return 0;
    }
    if (centsWhenInteger) {
      return parsed.round();
    }
    return (parsed * 100).round();
  }

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static num? _numValue(Object? value) {
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value.trim());
    }
    return null;
  }

  static String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty || text.toLowerCase() == 'unknown' ? null : text;
  }
}

class ScaleLogService {
  const ScaleLogService({this.timeout = const Duration(seconds: 6)});

  final Duration timeout;

  bool get isAvailable => Firebase.apps.isNotEmpty;

  FirebaseDatabase? get _database {
    if (!isAvailable) {
      return null;
    }
    final FirebaseApp app = Firebase.app();
    final String? databaseURL = app.options.databaseURL;
    if (databaseURL == null || databaseURL.isEmpty) {
      return null;
    }
    return FirebaseDatabase.instanceFor(app: app, databaseURL: databaseURL);
  }

  Future<List<ScaleSaleLog>> fetchSales(String deviceId) async {
    final FirebaseDatabase? database = _database;
    final String cleanDeviceId = deviceId.trim();
    if (database == null) {
      throw const ScaleLogException(
        'Realtime Database is not configured for scale sync.',
      );
    }
    if (cleanDeviceId.isEmpty) {
      throw const ScaleLogException('Scale device ID is not configured.');
    }

    final DataSnapshot snapshot;
    try {
      snapshot = await database
          .ref('scaleSales/${_databaseKey(cleanDeviceId)}')
          .get()
          .timeout(timeout);
    } catch (error) {
      throw _readError(cleanDeviceId, error);
    }
    final Object? value = snapshot.value;
    if (value is! Map) {
      return const <ScaleSaleLog>[];
    }

    final List<ScaleSaleLog> logs = <ScaleSaleLog>[];
    for (final MapEntry<Object?, Object?> entry
        in value.cast<Object?, Object?>().entries) {
      final String databaseKey = entry.key.toString();
      final Object? item = entry.value;
      if (item is! Map) {
        continue;
      }
      final Map<String, Object?> json = <String, Object?>{
        for (final MapEntry<Object?, Object?> field
            in item.cast<Object?, Object?>().entries)
          field.key.toString(): field.value,
      };
      if (json['imported'] == true) {
        continue;
      }
      logs.add(ScaleSaleLog.fromFirebase(databaseKey: databaseKey, json: json));
    }

    logs.sort((ScaleSaleLog a, ScaleSaleLog b) {
      final int soldAtCompare = a.soldAt.compareTo(b.soldAt);
      if (soldAtCompare != 0) {
        return soldAtCompare;
      }
      return a.id.compareTo(b.id);
    });
    return logs;
  }

  Future<void> acknowledgeSales({
    required String deviceId,
    required Iterable<ScaleSaleLog> sales,
  }) async {
    final FirebaseDatabase? database = _database;
    final String cleanDeviceId = deviceId.trim();
    final List<ScaleSaleLog> logs = sales.toList(growable: false);
    if (database == null || cleanDeviceId.isEmpty || logs.isEmpty) {
      return;
    }

    final Map<String, Object?> updates = <String, Object?>{};
    for (final ScaleSaleLog log in logs) {
      final String base =
          'scaleSales/${_databaseKey(cleanDeviceId)}/${_databaseKey(log.databaseKey)}';
      updates['$base/imported'] = true;
      updates['$base/importedAt'] = ServerValue.timestamp;
    }
    try {
      await database.ref().update(updates).timeout(timeout);
    } catch (error) {
      throw _writeError(cleanDeviceId, error);
    }
  }

  String _databaseKey(String value) {
    return value.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
  }

  ScaleLogException _readError(String deviceId, Object error) {
    if (_isPermissionDenied(error)) {
      return ScaleLogException(
        'Realtime Database rules blocked scale read. Allow read/write on scaleSales/$deviceId.',
      );
    }
    return ScaleLogException('Could not read Firebase scale sales.');
  }

  ScaleLogException _writeError(String deviceId, Object error) {
    if (_isPermissionDenied(error)) {
      return ScaleLogException(
        'Realtime Database rules blocked scale import update. Allow write on scaleSales/$deviceId.',
      );
    }
    return ScaleLogException('Could not mark Firebase scale sales imported.');
  }

  bool _isPermissionDenied(Object error) {
    if (error is FirebaseException) {
      final String code = error.code.toLowerCase();
      final String message = (error.message ?? '').toLowerCase();
      return code == 'permission-denied' ||
          message.contains('permission denied') ||
          message.contains("doesn't have permission");
    }
    final String message = error.toString().toLowerCase();
    return message.contains('permission denied') ||
        message.contains("doesn't have permission");
  }
}

class ScaleLogException implements Exception {
  const ScaleLogException(this.message);

  final String message;

  @override
  String toString() => message;
}
