import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/data/app_database.dart';
import 'package:fruityvens_app/services/market_outlook_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('imports PSA history separately from sales transactions', () async {
    final AppDatabase database = AppDatabase.inMemory();
    addTearDown(database.close);

    final MarketOutlookDataset dataset = await const MarketOutlookService()
        .load(database);

    expect(dataset.version, 'psa-openstat-2010-2025-v1');
    expect(dataset.location, 'Cagayan de Oro City');
    expect(dataset.recordCount, 6860);
    expect(await database.getMarketHistoryCount(), dataset.recordCount);
    expect(await database.getSalesTransactions(), isEmpty);
  });

  test('prefers local data and labels mango category fallbacks', () async {
    final AppDatabase database = AppDatabase.inMemory();
    addTearDown(database.close);
    final MarketOutlookDataset dataset = await const MarketOutlookService()
        .load(
          database,
          fruitNames: const <String>[
            'Mango Carabao',
            'Indian Mango',
            'Apple Mango',
          ],
        );

    final FruitMarketOutlook carabao = dataset.outlooks.singleWhere(
      (FruitMarketOutlook item) => item.fruitName == 'Mango Carabao',
    );
    expect(carabao.price, isNotNull);
    expect(carabao.price!.geography, 'Cagayan de Oro City');
    expect(carabao.price!.observationCount, 96);
    expect(carabao.price!.dataEnd, DateTime(2025, 12));
    expect(carabao.price!.validationPoints, greaterThan(0));

    final FruitMarketOutlook indian = dataset.outlooks.singleWhere(
      (FruitMarketOutlook item) => item.fruitName == 'Indian Mango',
    );
    expect(indian.supply, isNotNull);
    expect(indian.supply!.usesCategoryFallback, isTrue);
    expect(indian.supply!.sourceCommodity, 'Mango');

    final FruitMarketOutlook appleMango = dataset.outlooks.singleWhere(
      (FruitMarketOutlook item) => item.fruitName == 'Apple Mango',
    );
    expect(appleMango.price, isNotNull);
    expect(appleMango.price!.usesCategoryFallback, isTrue);
    expect(appleMango.price!.sourceCommodity, contains('MANGO'));
    expect(appleMango.supply, isNotNull);
    expect(appleMango.supply!.usesCategoryFallback, isTrue);
    expect(appleMango.supply!.sourceCommodity, 'Mango');
  });

  test(
    'uses the closest sufficiently complete series for each metric',
    () async {
      final AppDatabase database = AppDatabase.inMemory();
      addTearDown(database.close);
      final MarketOutlookDataset dataset = await const MarketOutlookService()
          .load(database);

      final FruitMarketOutlook apple = dataset.outlooks.singleWhere(
        (FruitMarketOutlook item) => item.fruitName == 'Apple',
      );
      expect(apple.price!.geography, 'Northern Mindanao (Region X)');
      expect(apple.supply, isNull);

      final FruitMarketOutlook dragonFruit = dataset.outlooks.singleWhere(
        (FruitMarketOutlook item) => item.fruitName == 'Dragon Fruit',
      );
      expect(dragonFruit.price, isNull);
      expect(dragonFruit.supply!.geography, 'Misamis Oriental');
      expect(dragonFruit.supply!.observationCount, greaterThanOrEqualTo(16));
    },
  );
}
