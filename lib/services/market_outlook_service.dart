import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../data/app_database.dart';

const String marketMetricRetailPrice = 'retail_price';
const String marketMetricProductionVolume = 'production_volume';

enum MarketDirection {
  increasing,
  stable,
  decreasing;

  String get label => switch (this) {
    MarketDirection.increasing => 'Increasing',
    MarketDirection.stable => 'Stable',
    MarketDirection.decreasing => 'Decreasing',
  };
}

enum MarketConfidence {
  low,
  medium,
  high;

  String get label => switch (this) {
    MarketConfidence.low => 'Low',
    MarketConfidence.medium => 'Medium',
    MarketConfidence.high => 'High',
  };
}

class MarketSignal {
  const MarketSignal({
    required this.direction,
    required this.lastValue,
    required this.forecastValue,
    required this.forecastPeriod,
    required this.unit,
    required this.model,
    required this.validationMae,
    required this.validationWape,
    required this.validationPoints,
    required this.observationCount,
    required this.dataStart,
    required this.dataEnd,
    required this.geography,
    required this.geographyLevel,
    required this.variant,
    required this.sourceCommodity,
    required this.sourceTable,
    required this.sourceUrl,
    required this.confidence,
    this.usesCategoryFallback = false,
  });

  final MarketDirection direction;
  final double lastValue;
  final double forecastValue;
  final DateTime forecastPeriod;
  final String unit;
  final String model;
  final double validationMae;
  final double validationWape;
  final int validationPoints;
  final int observationCount;
  final DateTime dataStart;
  final DateTime dataEnd;
  final String geography;
  final String geographyLevel;
  final String variant;
  final String sourceCommodity;
  final String sourceTable;
  final String sourceUrl;
  final MarketConfidence confidence;
  final bool usesCategoryFallback;
}

class FruitMarketOutlook {
  const FruitMarketOutlook({required this.fruitName, this.price, this.supply});

  final String fruitName;
  final MarketSignal? price;
  final MarketSignal? supply;

  bool get hasSignal => price != null || supply != null;

  MarketConfidence get confidence {
    final List<MarketConfidence> labels = <MarketConfidence>[
      if (price != null) price!.confidence,
      if (supply != null) supply!.confidence,
    ];
    if (labels.contains(MarketConfidence.low)) {
      return MarketConfidence.low;
    }
    if (labels.contains(MarketConfidence.medium)) {
      return MarketConfidence.medium;
    }
    return labels.isEmpty ? MarketConfidence.low : MarketConfidence.high;
  }
}

class MarketOutlookDataset {
  const MarketOutlookDataset({
    required this.version,
    required this.importedAt,
    required this.location,
    required this.recordCount,
    required this.outlooks,
  });

  final String version;
  final DateTime importedAt;
  final String location;
  final int recordCount;
  final List<FruitMarketOutlook> outlooks;
}

class MarketOutlookService {
  const MarketOutlookService({this.assetBundle});

  static const String assetPath = 'assets/data/psa_market_history.json';
  static const String _datasetVersionSetting =
      'psa_market_history_dataset_version';
  static const String _datasetCountSetting = 'psa_market_history_record_count';

  final AssetBundle? assetBundle;

  Future<MarketOutlookDataset> load(
    AppDatabase database, {
    Iterable<String>? fruitNames,
  }) async {
    final String content = await (assetBundle ?? rootBundle).loadString(
      assetPath,
    );
    final Object? decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('PSA history asset is not a JSON object.');
    }
    final Map<String, Object?> document = _stringMap(decoded);
    final String version = document['datasetVersion']?.toString() ?? '';
    final DateTime importedAt =
        DateTime.tryParse(document['importedAt']?.toString() ?? '') ??
        DateTime.utc(2026, 1, 1);
    final String location =
        document['location']?.toString() ?? 'Cagayan de Oro City';
    final List<LocalMarketHistory> assetRecords = _recordsFromJson(
      document['records'],
      importedAt,
    );
    final String? storedVersion = await database.getSetting(
      _datasetVersionSetting,
    );
    final int storedCount =
        int.tryParse(await database.getSetting(_datasetCountSetting) ?? '') ??
        -1;
    final int databaseCount = await database.getMarketHistoryCount();
    if (storedVersion != version ||
        storedCount != assetRecords.length ||
        databaseCount != assetRecords.length) {
      await database.replaceMarketHistory(assetRecords);
      await database.saveSetting(_datasetVersionSetting, version);
      await database.saveSetting(
        _datasetCountSetting,
        assetRecords.length.toString(),
      );
    }

    final List<LocalMarketHistory> storedRecords = await database
        .getMarketHistory();
    return MarketOutlookDataset(
      version: version,
      importedAt: importedAt,
      location: location,
      recordCount: storedRecords.length,
      outlooks: buildOutlooks(storedRecords, fruitNames: fruitNames),
    );
  }

  List<FruitMarketOutlook> buildOutlooks(
    List<LocalMarketHistory> records, {
    Iterable<String>? fruitNames,
  }) {
    final Set<String> requested =
        fruitNames?.toSet() ??
        records.map((LocalMarketHistory record) => record.fruitName).toSet();
    final List<String> orderedFruits = requested.toList()..sort();
    return orderedFruits
        .map((String fruitName) {
          MarketSignal? price = _signalFor(
            records: records,
            fruitName: fruitName,
            metric: marketMetricRetailPrice,
            minimumObservations: 24,
            seasonLength: 12,
            recentWindow: 3,
            trendWindow: 12,
          );
          if (price == null && fruitName == 'Apple Mango') {
            price = _signalFor(
              records: records,
              fruitName: 'Mango',
              metric: marketMetricRetailPrice,
              minimumObservations: 24,
              seasonLength: 12,
              recentWindow: 3,
              trendWindow: 12,
              usesCategoryFallback: true,
            );
          }
          MarketSignal? supply = _signalFor(
            records: records,
            fruitName: fruitName,
            metric: marketMetricProductionVolume,
            minimumObservations: 16,
            seasonLength: 4,
            recentWindow: 4,
            trendWindow: 8,
          );
          if (supply == null &&
              (fruitName == 'Indian Mango' ||
                  fruitName == 'Mango Carabao' ||
                  fruitName == 'Apple Mango')) {
            supply = _signalFor(
              records: records,
              fruitName: 'Mango',
              metric: marketMetricProductionVolume,
              minimumObservations: 16,
              seasonLength: 4,
              recentWindow: 4,
              trendWindow: 8,
              usesCategoryFallback: true,
            );
          }
          return FruitMarketOutlook(
            fruitName: fruitName,
            price: price,
            supply: supply,
          );
        })
        .where((FruitMarketOutlook outlook) => outlook.hasSignal)
        .toList();
  }

  MarketSignal? _signalFor({
    required List<LocalMarketHistory> records,
    required String fruitName,
    required String metric,
    required int minimumObservations,
    required int seasonLength,
    required int recentWindow,
    required int trendWindow,
    bool usesCategoryFallback = false,
  }) {
    final Map<String, List<LocalMarketHistory>> bySeries =
        <String, List<LocalMarketHistory>>{};
    for (final LocalMarketHistory record in records) {
      if (record.fruitName != fruitName || record.metric != metric) {
        continue;
      }
      bySeries
          .putIfAbsent(record.seriesKey, () => <LocalMarketHistory>[])
          .add(record);
    }
    final List<List<LocalMarketHistory>> candidates = bySeries.values
        .where(
          (List<LocalMarketHistory> series) =>
              series.length >= minimumObservations,
        )
        .toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((List<LocalMarketHistory> a, List<LocalMarketHistory> b) {
      final LocalMarketHistory firstA = a.first;
      final LocalMarketHistory firstB = b.first;
      final int geographyComparison = _geographyRank(
        firstA.geographyLevel,
      ).compareTo(_geographyRank(firstB.geographyLevel));
      if (geographyComparison != 0) {
        return geographyComparison;
      }
      final int priorityComparison = firstA.seriesPriority.compareTo(
        firstB.seriesPriority,
      );
      if (priorityComparison != 0) {
        return priorityComparison;
      }
      return b.length.compareTo(a.length);
    });

    final List<LocalMarketHistory> selected =
        List<LocalMarketHistory>.of(candidates.first)
          ..sort((LocalMarketHistory a, LocalMarketHistory b) {
            return a.periodStart.compareTo(b.periodStart);
          });
    final List<double> values = selected
        .map((LocalMarketHistory record) => record.value)
        .toList();
    final _EvaluatedForecast evaluated = _evaluateForecast(
      values,
      seasonLength: seasonLength,
      recentWindow: recentWindow,
      trendWindow: trendWindow,
    );
    final LocalMarketHistory first = selected.first;
    final LocalMarketHistory last = selected.last;
    final double stableBand = math.max(
      last.value.abs() * 0.03,
      evaluated.mae * 0.5,
    );
    final double difference = evaluated.forecast - last.value;
    final MarketDirection direction = difference.abs() <= stableBand
        ? MarketDirection.stable
        : difference > 0
        ? MarketDirection.increasing
        : MarketDirection.decreasing;
    final MarketConfidence confidence = _confidenceFor(
      metric: metric,
      observations: selected.length,
      validationWape: evaluated.wape,
    );
    return MarketSignal(
      direction: direction,
      lastValue: last.value,
      forecastValue: evaluated.forecast,
      forecastPeriod: _nextPeriod(last.periodStart, last.periodGranularity),
      unit: last.unit,
      model: evaluated.model,
      validationMae: evaluated.mae,
      validationWape: evaluated.wape,
      validationPoints: evaluated.validationPoints,
      observationCount: selected.length,
      dataStart: first.periodStart,
      dataEnd: last.periodStart,
      geography: last.geography,
      geographyLevel: last.geographyLevel,
      variant: last.variant,
      sourceCommodity: last.sourceCommodity,
      sourceTable: last.sourceTable,
      sourceUrl: last.sourceUrl,
      confidence: confidence,
      usesCategoryFallback: usesCategoryFallback,
    );
  }

  _EvaluatedForecast _evaluateForecast(
    List<double> values, {
    required int seasonLength,
    required int recentWindow,
    required int trendWindow,
  }) {
    final List<_ForecastMethod> methods = <_ForecastMethod>[
      _ForecastMethod(
        label: 'Seasonal naive',
        predict: (List<double> history) =>
            history[history.length - seasonLength],
        minimumHistory: seasonLength,
      ),
      _ForecastMethod(
        label: '$recentWindow-period moving average',
        predict: (List<double> history) =>
            _mean(history.sublist(math.max(0, history.length - recentWindow))),
        minimumHistory: recentWindow,
      ),
      _ForecastMethod(
        label: '$trendWindow-period linear trend',
        predict: (List<double> history) =>
            _linearTrendForecast(history, trendWindow),
        minimumHistory: math.max(4, trendWindow ~/ 2),
      ),
    ];
    final int validationStart = math.max(
      seasonLength,
      values.length - math.min(24, values.length ~/ 3),
    );
    _EvaluatedForecast? best;
    for (final _ForecastMethod method in methods) {
      final List<double> errors = <double>[];
      double actualTotal = 0;
      for (int index = validationStart; index < values.length; index++) {
        final List<double> history = values.sublist(0, index);
        if (history.length < method.minimumHistory) {
          continue;
        }
        final double predicted = math.max(0, method.predict(history));
        errors.add((predicted - values[index]).abs());
        actualTotal += values[index].abs();
      }
      if (errors.isEmpty || values.length < method.minimumHistory) {
        continue;
      }
      final double mae = _mean(errors);
      final double wape = actualTotal <= 0
          ? double.infinity
          : errors.fold<double>(0, (double sum, double value) => sum + value) /
                actualTotal;
      final _EvaluatedForecast candidate = _EvaluatedForecast(
        forecast: math.max(0, method.predict(values)),
        model: method.label,
        mae: mae,
        wape: wape,
        validationPoints: errors.length,
      );
      if (best == null || candidate.mae < best.mae) {
        best = candidate;
      }
    }
    return best ??
        _EvaluatedForecast(
          forecast: values.last,
          model: 'Last observation',
          mae: 0,
          wape: double.infinity,
          validationPoints: 0,
        );
  }

  MarketConfidence _confidenceFor({
    required String metric,
    required int observations,
    required double validationWape,
  }) {
    final int highCoverage = metric == marketMetricRetailPrice ? 72 : 48;
    final int mediumCoverage = metric == marketMetricRetailPrice ? 36 : 20;
    if (observations >= highCoverage && validationWape <= 0.15) {
      return MarketConfidence.high;
    }
    if (observations >= mediumCoverage && validationWape <= 0.30) {
      return MarketConfidence.medium;
    }
    return MarketConfidence.low;
  }

  List<LocalMarketHistory> _recordsFromJson(
    Object? value,
    DateTime fallbackImportedAt,
  ) {
    if (value is! List) {
      return const <LocalMarketHistory>[];
    }
    final List<LocalMarketHistory> records = <LocalMarketHistory>[];
    for (final Object? item in value) {
      if (item is! Map) {
        continue;
      }
      final Map<String, Object?> map = _stringMap(item);
      final DateTime? periodStart = DateTime.tryParse(
        map['periodStart']?.toString() ?? '',
      );
      final double? numericValue = _doubleValue(map['value']);
      if (periodStart == null || numericValue == null) {
        continue;
      }
      records.add(
        LocalMarketHistory(
          seriesKey: map['seriesKey']?.toString() ?? '',
          fruitName: map['fruitName']?.toString() ?? '',
          variant: map['variant']?.toString() ?? '',
          metric: map['metric']?.toString() ?? '',
          geography: map['geography']?.toString() ?? '',
          geographyLevel: map['geographyLevel']?.toString() ?? '',
          periodStart: periodStart,
          periodGranularity: map['periodGranularity']?.toString() ?? '',
          value: numericValue,
          unit: map['unit']?.toString() ?? '',
          sourceAgency: map['sourceAgency']?.toString() ?? '',
          sourceTable: map['sourceTable']?.toString() ?? '',
          sourceUrl: map['sourceUrl']?.toString() ?? '',
          sourceCommodity: map['sourceCommodity']?.toString() ?? '',
          seriesPriority: _intValue(map['seriesPriority']),
          importedAt:
              DateTime.tryParse(map['importedAt']?.toString() ?? '') ??
              fallbackImportedAt,
        ),
      );
    }
    return records;
  }
}

class _ForecastMethod {
  const _ForecastMethod({
    required this.label,
    required this.predict,
    required this.minimumHistory,
  });

  final String label;
  final double Function(List<double> history) predict;
  final int minimumHistory;
}

class _EvaluatedForecast {
  const _EvaluatedForecast({
    required this.forecast,
    required this.model,
    required this.mae,
    required this.wape,
    required this.validationPoints,
  });

  final double forecast;
  final String model;
  final double mae;
  final double wape;
  final int validationPoints;
}

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) {
  return <String, Object?>{
    for (final MapEntry<dynamic, dynamic> entry in value.entries)
      entry.key.toString(): entry.value,
  };
}

int _geographyRank(String level) {
  return switch (level) {
    'city' => 0,
    'province' => 1,
    'region' => 2,
    'national' => 3,
    _ => 4,
  };
}

DateTime _nextPeriod(DateTime value, String granularity) {
  final int months = granularity == 'quarter' ? 3 : 1;
  return DateTime(value.year, value.month + months);
}

double _mean(List<double> values) {
  if (values.isEmpty) {
    return 0;
  }
  return values.fold<double>(0, (double sum, double value) => sum + value) /
      values.length;
}

double _linearTrendForecast(List<double> values, int window) {
  final List<double> sample = values.sublist(
    math.max(0, values.length - window),
  );
  if (sample.length < 2) {
    return sample.isEmpty ? 0 : sample.last;
  }
  final double meanX = (sample.length - 1) / 2;
  final double meanY = _mean(sample);
  double numerator = 0;
  double denominator = 0;
  for (int index = 0; index < sample.length; index++) {
    final double centeredX = index - meanX;
    numerator += centeredX * (sample[index] - meanY);
    denominator += centeredX * centeredX;
  }
  final double slope = denominator == 0 ? 0 : numerator / denominator;
  return meanY + slope * (sample.length - meanX);
}

double? _doubleValue(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

int _intValue(Object? value) {
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
