import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class ReportExportService {
  const ReportExportService();

  static const MethodChannel _channel = MethodChannel(
    'fruityvens_app/report_saver',
  );

  Future<ReportExportResult> export(ReportExportData data) async {
    final Uint8List bytes = await buildPdf(data);
    final String fileName = data.fileName;

    if (Platform.isAndroid) {
      final String? path = await _channel.invokeMethod<String>(
        'savePdfWithPicker',
        <String, Object?>{'fileName': fileName, 'bytes': bytes},
      );
      return ReportExportResult(
        fileName: fileName,
        path: path ?? '',
        saved: path != null,
      );
    }

    final File file = File(fileName);
    await file.writeAsBytes(bytes, flush: true);
    return ReportExportResult(fileName: fileName, path: file.path);
  }

  Future<Uint8List> buildPdf(ReportExportData data) async {
    final pw.Document document = pw.Document();
    final PdfColor green = PdfColor.fromHex('#2E7D32');
    final PdfColor darkGreen = PdfColor.fromHex('#14351A');
    final PdfColor orange = PdfColor.fromHex('#EF6C00');
    final PdfColor pink = PdfColor.fromHex('#C2185B');
    final PdfColor muted = PdfColor.fromHex('#607D62');
    final List<PdfColor> chartColors = <PdfColor>[
      green,
      orange,
      pink,
      PdfColor.fromHex('#8D6E63'),
      darkGreen,
    ];

    document.addPage(
      pw.MultiPage(
        maxPages: 200,
        header: data.datasetLabel == null
            ? null
            : (pw.Context context) => pw.Text(
                'Includes generated sales for testing - see record labels',
                style: const pw.TextStyle(fontSize: 9),
              ),
        footer: (pw.Context context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(color: muted, fontSize: 9),
          ),
        ),
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(28),
          theme: pw.ThemeData.withFont(
            base: pw.Font.helvetica(),
            bold: pw.Font.helveticaBold(),
          ),
        ),
        build: (pw.Context context) {
          if (data.reportDate != null) {
            return <pw.Widget>[
              _header(data, green, muted),
              pw.SizedBox(height: 16),
              _metricWrap(data.dashboardMetrics, green, orange, width: 170),
              _sectionTitle('Sales by fruit', green),
              _tableOrEmpty(
                headers: const <String>[
                  'Fruit',
                  'Sales',
                  'Kg sold',
                  'Revenue',
                  'Avg PHP/kg',
                ],
                emptyMessage: 'No completed sales on this date.',
                rows: data.fruitSales
                    .map(
                      (ReportFruitSalesSummary fruit) => <String>[
                        fruit.name,
                        '${fruit.count}',
                        (fruit.weightGrams / 1000).toStringAsFixed(3),
                        reportMoney(fruit.revenueCentavos),
                        fruit.weightGrams == 0
                            ? '-'
                            : (fruit.revenueCentavos * 10 / fruit.weightGrams)
                                  .toStringAsFixed(2),
                      ],
                    )
                    .toList(),
              ),
              _sectionTitle('Transaction details', green),
              _bodyText(
                'Times use Asia/Manila (UTC+08:00). Revenue totals include completed sales only. Cancelled sales are listed for reference; removed and pending records are excluded.',
              ),
              pw.SizedBox(height: 8),
              _tableOrEmpty(
                headers: const <String>[
                  'Time',
                  'Fruit',
                  'Weight',
                  'Unit price',
                  'Total',
                  'Status',
                ],
                emptyMessage: 'No recorded sales for this date.',
                rows: data.transactions
                    .map(
                      (ReportTransaction sale) => <String>[
                        sale.time,
                        sale.fruit,
                        sale.weight,
                        sale.unitPrice ?? '-',
                        sale.price,
                        sale.status,
                      ],
                    )
                    .toList(),
              ),
            ];
          }
          return <pw.Widget>[
            _header(data, green, muted),
            pw.SizedBox(height: 16),
            _metricWrap(data.dashboardMetrics, green, orange),
            _sectionTitle('Inventory', green),
            _tableOrEmpty(
              headers: const <String>[
                'Fruit',
                'Price/unit',
                'Restock basis',
                'Signal',
              ],
              emptyMessage: 'No active fruits yet.',
              rows: data.inventory.map((ReportFruit fruit) {
                return <String>[
                  fruit.name,
                  fruit.pricePerKg,
                  fruit.restockBasis,
                  fruit.status,
                ];
              }).toList(),
            ),
            _sectionTitle('Forecast', green),
            _bodyText(data.forecastSummary),
            pw.SizedBox(height: 8),
            _tableOrEmpty(
              headers: const <String>['Focus', 'Expected', 'Action'],
              emptyMessage: 'No forecast yet.',
              rows: data.forecastRows
                  .map(
                    (ReportForecastRow row) => <String>[
                      row.name,
                      row.value,
                      row.action,
                    ],
                  )
                  .toList(),
            ),
            _sectionTitle('Analytics Bar Graph', green),
            _bodyText(data.analytics.chartTitle),
            pw.SizedBox(height: 10),
            data.analytics.hasChartData
                ? _stackedBarChart(data.analytics, chartColors)
                : _emptyBox('No sales in this range.'),
            pw.SizedBox(height: 10),
            _metricWrap(data.analyticsMetrics, green, orange),
            if (data.salesCounts.isNotEmpty) ...<pw.Widget>[
              _sectionTitle('Sales by fruit', green),
              _tableOrEmpty(
                headers: const <String>['Fruit', 'Completed sales'],
                emptyMessage: 'No completed sales in this range.',
                rows: data.salesCounts
                    .map(
                      (fruit) => <String>[fruit.name, fruit.count.toString()],
                    )
                    .toList(),
              ),
            ],
            _sectionTitle('Revenue Share', green),
            _tableOrEmpty(
              headers: const <String>['Fruit', 'Revenue'],
              emptyMessage: 'No revenue share yet.',
              rows: List<List<String>>.generate(
                data.analytics.shareLabels.length,
                (int index) => <String>[
                  data.analytics.shareLabels[index],
                  data.analytics.shareValues[index],
                ],
              ),
            ),
            _sectionTitle('Transaction History', green),
            _tableOrEmpty(
              headers: const <String>[
                'Fruit',
                'Weight',
                'Price',
                'Date',
                'Time',
                'Status',
              ],
              emptyMessage: 'No transaction history yet.',
              rows: data.transactions.map((ReportTransaction transaction) {
                return <String>[
                  transaction.fruit,
                  transaction.weight,
                  transaction.price,
                  transaction.date,
                  transaction.time,
                  transaction.status,
                ];
              }).toList(),
            ),
          ];
        },
      ),
    );

    return document.save();
  }

  pw.Widget _header(ReportExportData data, PdfColor green, PdfColor muted) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: green, width: 1),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Container(width: 8, height: 54, color: green),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text(
                  data.reportDate == null
                      ? 'FruityVens Report'
                      : 'FruityVens Daily Sales',
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (data.datasetLabel != null) ...<pw.Widget>[
                  pw.SizedBox(height: 6),
                  pw.Text(
                    data.datasetLabel!
                        .replaceAll('—', '-')
                        .replaceAll('–', '-')
                        .replaceAll('•', '-'),
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'This history includes generated sales for testing.',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ],
                pw.SizedBox(height: 4),
                if (data.reportDate != null) ...<pw.Widget>[
                  pw.Text(
                    'Sales date: ${data.displayReportDate}',
                    style: pw.TextStyle(
                      fontSize: 13,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (data.preparedBy?.isNotEmpty ?? false)
                    pw.Text(
                      'Prepared by: ${data.preparedBy}',
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  pw.SizedBox(height: 4),
                ],
                pw.Text(
                  data.reportDate == null
                      ? 'Generated ${data.displayDate}'
                      : 'Generated ${data.displayGeneratedAt} - Asia/Manila',
                  style: pw.TextStyle(color: muted, fontSize: 10),
                ),
                if (data.reportDate == null) ...<pw.Widget>[
                  pw.SizedBox(height: 6),
                  pw.Text(
                    'Fruit sales, pricing, forecasting, and analytics.',
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _sectionTitle(String title, PdfColor color) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 18, bottom: 8),
      child: pw.Text(
        title,
        style: pw.TextStyle(
          fontSize: 15,
          fontWeight: pw.FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  pw.Widget _bodyText(String text) {
    return pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 10, lineSpacing: 3),
    );
  }

  pw.Widget _metricWrap(
    List<ReportMetric> metrics,
    PdfColor green,
    PdfColor orange, {
    double width = 122,
  }) {
    return pw.Wrap(
      spacing: 8,
      runSpacing: 8,
      children: metrics.map((ReportMetric metric) {
        return pw.Container(
          width: width,
          padding: const pw.EdgeInsets.all(9),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: green, width: 0.5),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.Text(
                metric.label,
                style: pw.TextStyle(color: green, fontSize: 8),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                metric.value,
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                  color: metric.highlight ? orange : PdfColors.black,
                ),
              ),
              if (metric.note.isNotEmpty) ...<pw.Widget>[
                pw.SizedBox(height: 2),
                pw.Text(metric.note, style: const pw.TextStyle(fontSize: 8)),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  pw.Widget _table({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    );
  }

  pw.Widget _tableOrEmpty({
    required List<String> headers,
    required List<List<String>> rows,
    required String emptyMessage,
  }) {
    if (rows.isEmpty) {
      return _emptyBox(emptyMessage);
    }
    return _table(headers: headers, rows: rows);
  }

  pw.Widget _emptyBox(String message) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Text(
        message,
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
      ),
    );
  }

  pw.Widget _stackedBarChart(ReportAnalytics analytics, List<PdfColor> colors) {
    if (!analytics.hasChartData) {
      return _emptyBox('No sales in this range.');
    }
    final List<int> totals = List<int>.generate(analytics.labels.length, (
      int index,
    ) {
      return analytics.series.fold<int>(
        0,
        (int sum, List<int> values) => sum + values[index],
      );
    });
    final int maxTotal = totals.reduce((int a, int b) => a > b ? a : b);
    if (maxTotal <= 0) {
      return _emptyBox('No sales in this range.');
    }
    const double chartHeight = 110;

    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: List<pw.Widget>.generate(analytics.labels.length, (
          int index,
        ) {
          final List<pw.Widget> segments = <pw.Widget>[];
          for (
            int seriesIndex = analytics.series.length - 1;
            seriesIndex >= 0;
            seriesIndex--
          ) {
            final int value = analytics.series[seriesIndex][index];
            final double height = (chartHeight * value / maxTotal).clamp(
              2,
              chartHeight,
            );
            segments.add(
              pw.Container(
                width: 16,
                height: height,
                color: colors[seriesIndex % colors.length],
              ),
            );
          }
          return pw.Expanded(
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: <pw.Widget>[
                pw.Container(
                  height: chartHeight,
                  alignment: pw.Alignment.bottomCenter,
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.end,
                    children: segments,
                  ),
                ),
                pw.SizedBox(height: 5),
                pw.Text(
                  analytics.labels[index],
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 7),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class ReportExportResult {
  const ReportExportResult({
    required this.fileName,
    required this.path,
    this.saved = true,
  });

  final String fileName;
  final String path;
  final bool saved;
}

class ReportExportData {
  const ReportExportData({
    required this.generatedAt,
    required this.dashboardMetrics,
    required this.inventory,
    required this.forecastSummary,
    required this.forecastRows,
    required this.analytics,
    required this.analyticsMetrics,
    required this.transactions,
    this.datasetLabel,
    this.salesCounts = const <ReportFruitSalesCount>[],
    this.reportDate,
    this.preparedBy,
    this.dailySummary,
    this.fruitSales = const <ReportFruitSalesSummary>[],
  });

  final DateTime generatedAt;
  final DateTime? reportDate;
  final String? preparedBy;
  final ReportDailySummary? dailySummary;
  final List<ReportFruitSalesSummary> fruitSales;
  final String? datasetLabel;
  final List<ReportFruitSalesCount> salesCounts;
  final List<ReportMetric> dashboardMetrics;
  final List<ReportFruit> inventory;
  final String forecastSummary;
  final List<ReportForecastRow> forecastRows;
  final ReportAnalytics analytics;
  final List<ReportMetric> analyticsMetrics;
  final List<ReportTransaction> transactions;

  String get displayDate {
    final String day = generatedAt.day.toString().padLeft(2, '0');
    final String month = generatedAt.month.toString().padLeft(2, '0');
    return '$day/$month/${generatedAt.year}';
  }

  String get displayReportDate {
    final DateTime date = reportDate ?? generatedAt;
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  String get displayGeneratedAt {
    final DateTime clock = generatedAt.toUtc().add(const Duration(hours: 8));
    return '${clock.day.toString().padLeft(2, '0')}/${clock.month.toString().padLeft(2, '0')}/${clock.year} ${clock.hour.toString().padLeft(2, '0')}:${clock.minute.toString().padLeft(2, '0')}';
  }

  String get fileName {
    if (reportDate case final DateTime date) {
      return 'FruityVens_sales_${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.pdf';
    }
    final String day = generatedAt.day.toString().padLeft(2, '0');
    final String month = generatedAt.month.toString().padLeft(2, '0');
    final String prefix = datasetLabel == null
        ? 'FruityVens_report'
        : 'FruityVens_SAMPLE_report';
    return '${prefix}_$day-$month-${generatedAt.year}.pdf';
  }
}

String reportMoney(int centavos) {
  final String amount = (centavos / 100).toStringAsFixed(2);
  final List<String> parts = amount.split('.');
  final String whole = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (Match match) => ',',
  );
  return 'PHP $whole.${parts.last}';
}

class ReportDailySummary {
  const ReportDailySummary({
    required this.completedSales,
    required this.cancelledSales,
    required this.revenueCentavos,
    required this.weightGrams,
  });
  final int completedSales;
  final int cancelledSales;
  final int revenueCentavos;
  final int weightGrams;
}

class ReportFruitSalesSummary {
  const ReportFruitSalesSummary({
    required this.name,
    required this.count,
    required this.weightGrams,
    required this.revenueCentavos,
  });
  final String name;
  final int count;
  final int weightGrams;
  final int revenueCentavos;
}

class ReportFruitSalesCount {
  const ReportFruitSalesCount({required this.name, required this.count});

  final String name;
  final int count;
}

class ReportMetric {
  const ReportMetric(
    this.label,
    this.value,
    this.note, {
    this.highlight = false,
  });

  final String label;
  final String value;
  final String note;
  final bool highlight;
}

class ReportFruit {
  const ReportFruit({
    required this.name,
    required this.pricePerKg,
    required this.restockBasis,
    required this.status,
  });

  final String name;
  final String pricePerKg;
  final String restockBasis;
  final String status;
}

class ReportForecastRow {
  const ReportForecastRow({
    required this.name,
    required this.value,
    required this.action,
  });

  final String name;
  final String value;
  final String action;
}

class ReportAnalytics {
  const ReportAnalytics({
    required this.chartTitle,
    required this.labels,
    required this.series,
    required this.shareLabels,
    required this.shareValues,
  });

  final String chartTitle;
  final List<String> labels;
  final List<List<int>> series;
  final List<String> shareLabels;
  final List<String> shareValues;

  bool get hasChartData =>
      labels.isNotEmpty &&
      series.isNotEmpty &&
      series.any((List<int> values) => values.any((int value) => value > 0));
}

class ReportTransaction {
  const ReportTransaction({
    required this.fruit,
    required this.weight,
    required this.price,
    required this.date,
    required this.time,
    required this.status,
    this.unitPrice,
  });

  final String fruit;
  final String weight;
  final String price;
  final String date;
  final String time;
  final String status;
  final String? unitPrice;
}
