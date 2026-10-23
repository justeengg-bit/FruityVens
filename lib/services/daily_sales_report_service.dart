import '../data/app_database.dart';
import 'report_export_service.dart';

class DailySalesReportService {
  const DailySalesReportService();

  static DateTime businessClock(DateTime instant) =>
      instant.toUtc().add(const Duration(hours: 8));

  static DateTime businessDay(DateTime instant) {
    final DateTime clock = businessClock(instant);
    return DateTime(clock.year, clock.month, clock.day);
  }

  ReportExportData build({
    required DateTime reportDate,
    required DateTime generatedAt,
    required List<LocalSale> sales,
    String? preparedBy,
  }) {
    final DateTime day = DateTime(
      reportDate.year,
      reportDate.month,
      reportDate.day,
    );
    final List<LocalSale> selected =
        sales.where((LocalSale sale) {
            final DateTime soldDay = businessDay(sale.soldAt);
            final String status = sale.status.trim().toLowerCase();
            return soldDay == day &&
                (<String>{
                  'sold',
                  'sale',
                  'completed',
                  'done',
                  'paid',
                  'cancelled',
                  'canceled',
                }.contains(status));
          }).toList()
          ..sort((LocalSale a, LocalSale b) => a.soldAt.compareTo(b.soldAt));
    final List<LocalSale> completed = selected
        .where(
          (LocalSale sale) => !<String>{
            'cancelled',
            'canceled',
          }.contains(sale.status.trim().toLowerCase()),
        )
        .toList();
    final Map<String, List<LocalSale>> byFruit = <String, List<LocalSale>>{};
    for (final LocalSale sale in completed) {
      byFruit.putIfAbsent(sale.fruitName, () => <LocalSale>[]).add(sale);
    }
    final List<ReportFruitSalesSummary> fruits =
        byFruit.entries.map((entry) {
            return ReportFruitSalesSummary(
              name: entry.key,
              count: entry.value.length,
              weightGrams: entry.value.fold<int>(
                0,
                (int sum, LocalSale sale) => sum + sale.weightGrams,
              ),
              revenueCentavos: entry.value.fold<int>(
                0,
                (int sum, LocalSale sale) => sum + sale.totalPrice,
              ),
            );
          }).toList()
          ..sort((ReportFruitSalesSummary a, ReportFruitSalesSummary b) {
            final int revenueOrder = b.revenueCentavos.compareTo(
              a.revenueCentavos,
            );
            return revenueOrder == 0 ? a.name.compareTo(b.name) : revenueOrder;
          });
    final ReportDailySummary summary = ReportDailySummary(
      completedSales: completed.length,
      cancelledSales: selected.length - completed.length,
      revenueCentavos: completed.fold<int>(
        0,
        (int sum, LocalSale sale) => sum + sale.totalPrice,
      ),
      weightGrams: completed.fold<int>(
        0,
        (int sum, LocalSale sale) => sum + sale.weightGrams,
      ),
    );
    return ReportExportData(
      generatedAt: generatedAt,
      reportDate: day,
      preparedBy: preparedBy,
      dailySummary: summary,
      fruitSales: fruits,
      datasetLabel:
          selected.any(
            (LocalSale sale) =>
                sale.cloudId?.startsWith('sample_cdo_') ?? false,
          )
          ? 'Includes generated sales for testing'
          : null,
      dashboardMetrics: <ReportMetric>[
        ReportMetric(
          'Sales revenue',
          reportMoney(summary.revenueCentavos),
          'Completed sales only',
          highlight: true,
        ),
        ReportMetric(
          'Completed sales',
          '${summary.completedSales}',
          'Transactions',
        ),
        ReportMetric(
          'Weight sold',
          '${(summary.weightGrams / 1000).toStringAsFixed(3)} kg',
          'Completed sales',
        ),
        ReportMetric(
          'Average sale',
          reportMoney(
            summary.completedSales == 0
                ? 0
                : (summary.revenueCentavos / summary.completedSales).round(),
          ),
          'Revenue per transaction',
        ),
        ReportMetric(
          'Best seller',
          fruits.isEmpty ? 'No sales' : fruits.first.name,
          'Highest revenue',
        ),
        ReportMetric(
          'Cancelled sales',
          '${summary.cancelledSales}',
          'Excluded from totals',
        ),
      ],
      inventory: const <ReportFruit>[],
      forecastSummary: '',
      forecastRows: const <ReportForecastRow>[],
      analytics: const ReportAnalytics(
        chartTitle: '',
        labels: [],
        series: [],
        shareLabels: [],
        shareValues: [],
      ),
      analyticsMetrics: const <ReportMetric>[],
      transactions: selected.map((LocalSale sale) {
        final DateTime clock = businessClock(sale.soldAt);
        final bool cancelled = <String>{
          'cancelled',
          'canceled',
        }.contains(sale.status.trim().toLowerCase());
        final bool generated = sale.cloudId?.startsWith('sample_cdo_') ?? false;
        return ReportTransaction(
          fruit: sale.fruitName,
          weight: '${(sale.weightGrams / 1000).toStringAsFixed(3)} kg',
          price: reportMoney(sale.totalPrice),
          unitPrice: '${reportMoney(sale.unitPrice)}/kg',
          date:
              '${clock.day.toString().padLeft(2, '0')}/${clock.month.toString().padLeft(2, '0')}/${clock.year}',
          time:
              '${clock.hour.toString().padLeft(2, '0')}:${clock.minute.toString().padLeft(2, '0')}',
          status:
              '${cancelled ? 'Cancelled' : 'Completed'}${generated ? ' (generated)' : ''}',
        );
      }).toList(),
    );
  }
}
