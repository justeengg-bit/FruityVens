import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/services/cdo_sample_sales_service.dart';
import 'package:fruityvens_app/services/report_export_service.dart';

class _SampleReport extends ReportExportData {
  _SampleReport(this.outputPath, CdoSampleSalesDataset dataset)
    : super(
        generatedAt: DateTime(2026, 10, 9),
        datasetLabel: dataset.label,
        dashboardMetrics: const [],
        inventory: const [],
        forecastSummary: dataset.forecast().summary,
        forecastRows: const [],
        analytics: const ReportAnalytics(
          chartTitle: 'Sample sales',
          labels: [],
          series: [],
          shareLabels: [],
          shareValues: [],
        ),
        analyticsMetrics: const [],
        transactions: dataset.sales
            .map(
              (sale) => ReportTransaction(
                fruit: sale.fruitName,
                weight: '${sale.weightGrams / 1000} kg',
                price: 'PHP ${(sale.totalPrice / 100).toStringAsFixed(2)}',
                date: sale.soldAt.toIso8601String().substring(0, 10),
                time: 'Sample',
                status: 'Sample sale',
              ),
            )
            .toList(),
      );

  final String outputPath;
  @override
  String get fileName => outputPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full sample history exports with explicit sample provenance', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'fruityvens-report-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final CdoSampleSalesDataset dataset = await const CdoSampleSalesService()
        .load();
    final _SampleReport data = _SampleReport(
      '${directory.path}/sample.pdf',
      dataset,
    );
    expect(data.datasetLabel, contains('synthetic'));
    final ReportExportResult result = await const ReportExportService().export(
      data,
    );
    expect(result.saved, isTrue);
    final List<int> bytes = await File(result.path).readAsBytes();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(10000));
  });
}
