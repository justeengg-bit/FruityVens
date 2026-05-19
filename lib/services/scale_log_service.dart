import 'dart:convert';

import 'package:http/http.dart' as http;

class ScaleSaleLog {
  const ScaleSaleLog({
    required this.id,
    required this.fruitName,
    required this.weightGrams,
    required this.priceCentavos,
    required this.pricePerKgCentavos,
    required this.soldAt,
    required this.source,
    required this.dedupeKey,
  });

  final int id;
  final String fruitName;
  final int weightGrams;
  final int priceCentavos;
  final int pricePerKgCentavos;
  final DateTime soldAt;
  final String source;
  final String dedupeKey;

  String cloudId(String scaleBaseUrl) {
    final String normalizedSource = scaleBaseUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String normalizedLogKey = dedupeKey
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'scale_${normalizedSource}_$normalizedLogKey';
  }

  factory ScaleSaleLog.fromJson(Map<String, Object?> json) {
    final int id = _requiredInt(json['id'], 'id');
    final int weightGrams = _requiredCentavosSafeInt(
      json['weightGrams'] ?? json['weight'],
      'weightGrams',
    );
    final int priceCentavos = _moneyToCentavos(json['price']);
    final int pricePerKgCentavos = _moneyToCentavos(json['pricePerKg']);
    final String fruitName =
        _stringValue(json['fruitType']) ??
        _stringValue(json['fruit']) ??
        _stringValue(json['fruit_type']) ??
        'Unknown';
    final String source = _stringValue(json['source']) ?? 'scale';
    final String? timestamp = _stringValue(json['timestamp']);
    final String? date = _stringValue(json['date']);
    final String? time = _stringValue(json['time']);
    final String dateTimeKey = timestamp ?? '${date ?? ''}T${time ?? ''}';
    final DateTime soldAt =
        DateTime.tryParse(timestamp ?? '') ??
        DateTime.tryParse(dateTimeKey) ??
        DateTime.now();
    final String cleanFruitName = fruitName.trim().isEmpty
        ? 'Unknown'
        : fruitName.trim();

    return ScaleSaleLog(
      id: id,
      fruitName: cleanFruitName,
      weightGrams: weightGrams,
      priceCentavos: priceCentavos,
      pricePerKgCentavos: pricePerKgCentavos,
      soldAt: soldAt,
      source: source,
      dedupeKey:
          '$id|${dateTimeKey.trim().isEmpty ? 'no_timestamp' : dateTimeKey}|$cleanFruitName|$weightGrams|$priceCentavos|$source',
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

  static int _moneyToCentavos(Object? value) {
    final num? parsed = _numValue(value);
    if (parsed == null) {
      return 0;
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
  const ScaleLogService({
    this.timeout = const Duration(seconds: 3),
    http.Client? client,
  }) : _client = client;

  final Duration timeout;
  final http.Client? _client;

  Future<List<ScaleSaleLog>> fetchSales(String baseUrl) async {
    final Uri uri = _endpoint(baseUrl, '/sales');
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client.get(uri).timeout(timeout);
      if (response.statusCode == 404) {
        return const <ScaleSaleLog>[];
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ScaleLogException('Scale returned HTTP ${response.statusCode}.');
      }

      final Object? decoded = jsonDecode(response.body);
      if (decoded is! List<Object?>) {
        throw const ScaleLogException('Scale /sales did not return a list.');
      }

      final List<ScaleSaleLog> logs =
          decoded
              .whereType<Map<String, Object?>>()
              .map(ScaleSaleLog.fromJson)
              .toList()
            ..sort((ScaleSaleLog a, ScaleSaleLog b) => a.id.compareTo(b.id));
      return logs;
    } on ScaleLogException {
      rethrow;
    } catch (error) {
      throw ScaleLogException('Could not fetch scale logs: $error');
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  Uri _endpoint(String baseUrl, String path) {
    final String cleanBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (cleanBase.isEmpty) {
      throw const ScaleLogException('Scale API URL is not configured.');
    }
    final Uri? parsed = Uri.tryParse('$cleanBase$path');
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw const ScaleLogException('Scale API URL is invalid.');
    }
    return parsed;
  }
}

class ScaleLogException implements Exception {
  const ScaleLogException(this.message);

  final String message;

  @override
  String toString() => message;
}
