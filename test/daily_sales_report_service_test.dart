import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/data/app_database.dart';
import 'package:fruityvens_app/services/daily_sales_report_service.dart';
import 'package:fruityvens_app/services/report_export_service.dart';

LocalSale sale(
  DateTime time, {
  String fruit = 'Mango',
  String status = 'sold',
  int grams = 1250,
  int unitPrice = 6000,
  int revenue = 7500,
  String? cloudId,
}) => LocalSale(
  fruitName: fruit,
  weightGrams: grams,
  unitPrice: unitPrice,
  totalPrice: revenue,
  status: status,
  soldAt: time,
  cloudId: cloudId,
);

void main() {
  const DailySalesReportService service = DailySalesReportService();
  final DateTime day = DateTime(2026, 10, 9);
  ReportExportData build(List<LocalSale> sales) => service.build(
    reportDate: day,
    generatedAt: DateTime.utc(2026, 10, 11, 2, 30),
    sales: sales,
    preparedBy: 'owner@example.com',
  );

  test('filters the sales date using Manila midnight, not generation date', () {
    final ReportExportData report = build([
      sale(DateTime.utc(2026, 10, 8, 15, 59), fruit: 'Before'),
      sale(DateTime.utc(2026, 10, 8, 16), fruit: 'Start'),
      sale(DateTime.utc(2026, 10, 9, 15, 59), fruit: 'End'),
      sale(DateTime.utc(2026, 10, 9, 16), fruit: 'After'),
    ]);
    expect(report.transactions.map((t) => t.fruit), ['Start', 'End']);
    expect(report.transactions.map((t) => t.time), ['00:00', '23:59']);
    expect(report.transactions.every((t) => t.date == '09/10/2026'), isTrue);
    expect(report.fileName, 'FruityVens_sales_2026-10-09.pdf');
    expect(report.displayGeneratedAt, '11/10/2026 10:30');
  });

  test(
    'cancelled rows are visible but removed and pending rows are excluded',
    () {
      final DateTime time = DateTime.utc(2026, 10, 9, 4);
      final ReportExportData report = build([
        sale(time),
        sale(time, status: ' Cancelled '),
        sale(time, status: 'canceled'),
        sale(time, status: 'Removed'),
        sale(time, status: 'pending'),
        sale(time, status: 'unrecognized'),
      ]);
      expect(report.transactions, hasLength(3));
      expect(report.dailySummary!.completedSales, 1);
      expect(report.dailySummary!.cancelledSales, 2);
      expect(report.dailySummary!.weightGrams, 1250);
      expect(report.dailySummary!.revenueCentavos, 7500);
      expect(report.fruitSales.single.count, 1);
    },
  );

  test(
    'fruit totals use exact stored revenue and grams, ranked by revenue',
    () {
      final DateTime time = DateTime.utc(2026, 10, 9, 4);
      final ReportExportData report = build([
        sale(time.add(const Duration(hours: 1)), revenue: 7401),
        sale(time, fruit: 'Banana', grams: 2000, revenue: 7000),
        sale(time, grams: 1, revenue: 6),
      ]);
      expect(report.dailySummary!.revenueCentavos, 14407);
      expect(report.dailySummary!.weightGrams, 3251);
      expect(report.fruitSales.map((f) => f.name), ['Mango', 'Banana']);
      expect(report.fruitSales.first.revenueCentavos, 7407);
      expect(report.fruitSales.first.weightGrams, 1251);
      expect(report.transactions.last.price, 'PHP 74.01');
      expect(report.transactions.last.unitPrice, 'PHP 60.00/kg');
      expect(report.transactions[1].weight, '0.001 kg');
      expect(report.dashboardMetrics.first.value, 'PHP 144.07');
      expect(report.inventory, isEmpty);
      expect(report.forecastRows, isEmpty);
    },
  );

  test(
    'no-sales day has zero totals and no generated-data label from other days',
    () {
      final ReportExportData report = build([
        sale(DateTime.utc(2026, 10, 10, 4), cloudId: 'sample_cdo_otherday'),
      ]);
      expect(report.transactions, isEmpty);
      expect(report.dailySummary!.revenueCentavos, 0);
      expect(report.dailySummary!.completedSales, 0);
      expect(report.fruitSales, isEmpty);
      expect(report.datasetLabel, isNull);
      expect(report.dashboardMetrics[3].value, 'PHP 0.00');
      expect(report.dashboardMetrics[4].value, 'No sales');
    },
  );

  test('generated provenance applies only to selected generated rows', () {
    final DateTime time = DateTime.utc(2026, 10, 9, 4);
    final ReportExportData report = build([
      sale(time, cloudId: 'sample_cdo_today'),
      sale(time.add(const Duration(hours: 1))),
    ]);
    expect(report.datasetLabel, contains('generated'));
    expect(report.transactions.first.status, 'Completed (generated)');
    expect(report.transactions.last.status, 'Completed');
  });

  test(
    'daily PDF renders empty days and long multi-page transaction lists',
    () async {
      for (final int count in [0, 120]) {
        final ReportExportData report = build(
          List.generate(
            count,
            (int i) => sale(
              DateTime.utc(2026, 10, 9, 4).add(Duration(minutes: i)),
              fruit: 'Watermelon',
              status: i.isEven ? 'sold' : 'cancelled',
            ),
          ),
        );
        final List<int> bytes = await const ReportExportService().buildPdf(
          report,
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1000));
      }
    },
  );
}
