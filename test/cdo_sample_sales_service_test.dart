import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/data/app_database.dart';
import 'package:fruityvens_app/services/cdo_sample_sales_service.dart';
import 'package:fruityvens_app/services/ai_automation_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generated import adds normal sales once and preserves existing history',
    () async {
      final AppDatabase database = AppDatabase.inMemory();
      await database.addSale(
        cloudId: 'existing_sale',
        fruitName: 'Mango',
        weightGrams: 1000,
        unitPrice: 10000,
        totalPrice: 10000,
        soldAt: DateTime(2026, 6, 1),
      );
      final CdoSampleSalesDataset dataset = await const CdoSampleSalesService()
          .load();
      expect(await dataset.importInto(database), 1249);
      List<LocalSale> sales = await database.getSalesTransactions();
      expect(sales, hasLength(1250));
      expect(sales.every((sale) => sale.id != null), isTrue);
      final LocalSale generated = sales.first;
      await database.updateSaleStatus(id: generated.id!, status: 'cancelled');
      expect(await dataset.importInto(database), 0);
      sales = await database.getSalesTransactions();
      expect(sales, hasLength(1250));
      expect(
        sales.singleWhere((sale) => sale.cloudId == generated.cloudId).status,
        'cancelled',
      );
      expect(
        sales.singleWhere((sale) => sale.cloudId == 'existing_sale').totalPrice,
        10000,
      );
      final List<Map<String, Object?>> payloads = await database
          .getSalesSyncPayloads(deviceId: 'test_phone');
      expect(payloads, hasLength(1250));
      expect(
        payloads.where(
          (row) => row['cloudId'].toString().startsWith('sample_cdo_'),
        ),
        hasLength(1249),
      );
    },
  );

  test(
    'sample dataset is isolated, dated, unique and arithmetically consistent',
    () async {
      final AppDatabase database = AppDatabase.inMemory();
      final CdoSampleSalesDataset dataset = await const CdoSampleSalesService()
          .load();
      expect(dataset.startDate, DateTime(2026, 7, 1));
      expect(dataset.endDate, DateTime(2026, 10, 9));
      expect(dataset.sales.length, greaterThan(500));
      expect(
        dataset.sales.map((sale) => sale.cloudId).toSet().length,
        dataset.sales.length,
      );
      expect(dataset.sales.map((sale) => sale.fruitName).toSet().length, 9);
      expect(dataset.sales.every((sale) => sale.id == null), isTrue);
      expect(
        dataset.sales.every((sale) => sale.cloudId!.startsWith('sample_cdo_')),
        isTrue,
      );
      for (final LocalSale sale in dataset.sales) {
        expect(sale.soldAt.isBefore(dataset.startDate), isFalse);
        expect(sale.soldAt.isBefore(DateTime(2026, 10, 9, 12)), isTrue);
        expect(
          sale.totalPrice,
          (sale.unitPrice * sale.weightGrams / 1000).round(),
        );
      }
      expect(await database.getSalesTransactions(), isEmpty);
      final AiAutomationResult forecast = dataset.forecast();
      expect(forecast.coverage!.observedDays, 101);
      expect(forecast.predictions, hasLength(8));
      expect(
        forecast.predictions.any((prediction) => prediction.fruit == 'Mango'),
        isFalse,
      );
      expect(forecast.summary, contains('variety review'));
      expect(forecast.source, 'Local sample data');
      for (final AiForecastPrediction prediction in forecast.predictions) {
        expect(prediction.dailyPredictions, hasLength(7));
        expect(
          prediction.predictedKgTotal,
          closeTo(
            prediction.dailyPredictions.reduce((a, b) => a + b),
            0.000001,
          ),
        );
      }
    },
  );

  test('sample projection includes zero-sale matching weekdays', () {
    final CdoSampleSalesDataset dataset = CdoSampleSalesDataset(
      label: 'Sample',
      startDate: DateTime(2026, 9, 12),
      endDate: DateTime(2026, 10, 9),
      sales: <LocalSale>[
        LocalSale(
          fruitName: 'Banana',
          weightGrams: 8000,
          unitPrice: 5000,
          totalPrice: 40000,
          status: 'sold',
          soldAt: DateTime(2026, 10, 3),
        ),
      ],
    );
    final AiForecastPrediction prediction = dataset
        .forecast()
        .predictions
        .single;
    expect(prediction.predictedKgTomorrow, 2); // 8 kg across four Saturdays.
    expect(prediction.dailyPredictions.skip(1), everyElement(0));
  });
}
