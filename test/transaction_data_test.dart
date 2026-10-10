import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/main.dart';

void main() {
  test(
    'calculations preserve raw centavos and grams instead of display rounding',
    () {
      const TransactionData sale = TransactionData(
        'Mango',
        '1.2 kg',
        'PHP 1,200.00',
        'Oct 9, 2026',
        '10:00 AM',
        'Sold',
        weightGrams: 1234,
        totalPrice: 120000,
      );
      expect(sale.totalPriceCentavos, 120000);
      expect(sale.weightKg, 1.234);
      const TransactionData smallSale = TransactionData(
        'Calamansi',
        '0.0 kg',
        'PHP 2.00',
        'Oct 9, 2026',
        '10:00 AM',
        'Sold',
        weightGrams: 25,
        totalPrice: 200,
      );
      expect(smallSale.weightKg, 0.025);
    },
  );

  test('legacy demo money with grouping retains its full value', () {
    const TransactionData sale = TransactionData(
      'Mango',
      '1.2 kg',
      'PHP 1,234,567.89',
      'Oct 9, 2026',
      '10:00 AM',
      'Sold',
    );
    expect(sale.totalPriceCentavos, 123456789);
    expect(sale.weightKg, 1.2);
  });
}
