import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../data/fruit_categories.dart';
import 'ai_automation_client.dart';

/// Bundled generated history. Loading validates it; importing adds normal sales.
class CdoSampleSalesService {
  const CdoSampleSalesService();

  Future<CdoSampleSalesDataset> load() async {
    final String source = await rootBundle.loadString(
      'assets/data/cdo_sample_sales_2026.json',
    );
    return CdoSampleSalesDataset.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }
}

class CdoSampleSalesDataset {
  const CdoSampleSalesDataset({
    required this.label,
    required this.startDate,
    required this.endDate,
    required this.sales,
  });

  final String label;
  final DateTime startDate;
  final DateTime endDate;
  final List<LocalSale> sales;

  Future<int> importInto(AppDatabase database) =>
      database.importGeneratedSales(sales);

  factory CdoSampleSalesDataset.fromJson(Map<String, dynamic> json) {
    if (json['kind'] != 'synthetic_sales') {
      throw const FormatException('Expected clearly labeled sample sales.');
    }
    final DateTime start = DateTime.parse(json['startDate'] as String);
    final DateTime end = DateTime.parse(json['endDate'] as String);
    final Set<String> ids = <String>{};
    final List<LocalSale> sales = <LocalSale>[];
    for (final dynamic item in json['transactions'] as List<dynamic>) {
      final Map<String, dynamic> row = item as Map<String, dynamic>;
      final String id = row['cloudId'] as String;
      final int grams = row['weightGrams'] as int;
      final int price = row['unitPrice'] as int;
      final int total = row['totalPrice'] as int;
      final String timestamp = row['soldAt'] as String;
      final DateTime day = DateTime.parse(timestamp.substring(0, 10));
      if (!id.startsWith('sample_cdo_') ||
          !ids.add(id) ||
          grams <= 0 ||
          price <= 0 ||
          total != (grams * price / 1000).round() ||
          day.isBefore(start) ||
          day.isAfter(end) ||
          row['status'] != 'sold') {
        throw const FormatException('Invalid sample sales record.');
      }
      sales.add(
        LocalSale(
          cloudId: id,
          fruitName: row['fruitName'] as String,
          weightGrams: grams,
          unitPrice: price,
          totalPrice: total,
          status: 'sold',
          // Keep the example's Manila business date independent of the host timezone.
          soldAt: DateTime.parse(timestamp.substring(0, 19)),
        ),
      );
    }
    sales.sort((LocalSale a, LocalSale b) => b.soldAt.compareTo(a.soldAt));
    return CdoSampleSalesDataset(
      label: json['label'] as String,
      startDate: start,
      endDate: end,
      sales: List<LocalSale>.unmodifiable(sales),
    );
  }

  /// Transparent local illustration, not the vendor's trained AI model.
  /// The last four matching weekdays include zero-sale days in their average.
  AiAutomationResult forecast() {
    final DateTime windowStart = endDate.subtract(const Duration(days: 27));
    final Map<String, Map<DateTime, double>> totals =
        <String, Map<DateTime, double>>{};
    for (final LocalSale sale in sales) {
      if (!fruitCategoryNames.contains(sale.fruitName)) {
        continue;
      }
      final Map<DateTime, double> fruit = totals.putIfAbsent(
        sale.fruitName,
        () => <DateTime, double>{},
      );
      final DateTime date = DateTime(
        sale.soldAt.year,
        sale.soldAt.month,
        sale.soldAt.day,
      );
      if (date.isBefore(windowStart) || date.isAfter(endDate)) {
        continue;
      }
      fruit.update(
        date,
        (double current) => current + sale.weightGrams / 1000,
        ifAbsent: () => sale.weightGrams / 1000,
      );
    }
    final List<AiForecastPrediction> predictions = totals.entries.map((entry) {
      final List<double> daily = List<double>.generate(7, (int offset) {
        final DateTime target = endDate.add(Duration(days: offset + 1));
        double sum = 0;
        int count = 0;
        for (int day = 0; day < 28; day++) {
          final DateTime date = windowStart.add(Duration(days: day));
          if (date.weekday == target.weekday && !date.isBefore(startDate)) {
            sum += entry.value[date] ?? 0;
            count++;
          }
        }
        return double.parse((sum / math.max(1, count)).toStringAsFixed(3));
      });
      final double total = daily.fold(0, (double a, double b) => a + b);
      return AiForecastPrediction(
        fruit: entry.key,
        predictedKgTomorrow: daily.first,
        predictedKgTotal: total,
        dailyPredictions: daily,
        recommendation: 'Sample projection',
        confidence: 'Sample only',
        reason:
            'Average of the last four matching weekdays in generated data, including zero-sale days. Not actual demand.',
      );
    }).toList()..sort((a, b) => b.predictedKgTotal.compareTo(a.predictedKgTotal));
    return AiAutomationResult(
      summary:
          'Illustrative seven-day projection from generated CDO sample sales. '
          'Uses the last four matching weekdays for supported categories only. '
          'Generic Mango records need variety review and are excluded; '
          'this is not a forecast of actual vendor demand.',
      model: 'Four-week weekday average',
      source: 'Local sample data',
      predictions: predictions,
      coverage: AiForecastCoverage(
        transactionCount: sales
            .where((sale) => fruitCategoryNames.contains(sale.fruitName))
            .length,
        observedDays: sales
            .where((sale) => fruitCategoryNames.contains(sale.fruitName))
            .map((sale) {
              final DateTime date = sale.soldAt;
              return '${date.year}-${date.month}-${date.day}';
            })
            .toSet()
            .length,
        dataStart: startDate,
        dataEnd: endDate,
        fruits: totals.keys.toList()..sort(),
      ),
    );
  }
}
