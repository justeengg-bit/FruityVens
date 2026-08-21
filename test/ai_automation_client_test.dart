import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/services/ai_automation_client.dart';

void main() {
  test('forecast response preserves daily model predictions', () {
    final AiAutomationResult result = AiAutomationResult.fromJson(
      <String, Object?>{
        'summary': 'Forecast ready.',
        'model': 'GradientBoostingRegressor',
        'source': 'FruityVens ML Forecast Server',
        'dataCoverage': <String, Object?>{
          'transactionCount': 90,
          'observedDays': 30,
          'dataStart': '2026-01-01',
          'dataEnd': '2026-02-15',
          'fruits': <String>['Mango'],
        },
        'predictions': <Map<String, Object?>>[
          <String, Object?>{
            'fruit': 'Mango',
            'predictedKgTomorrow': 1.25,
            'predictedKgTotal': 8.4,
            'recommendation': 'Medium restock',
            'confidence': 'low',
            'reason': 'Measured from genuine sales.',
            'dailyPredictions': <double>[1.25, 1.1, 1.2, 1.3, 1.15, 1.25, 1.15],
          },
        ],
      },
    );

    expect(result.coverage!.observedDays, 30);
    expect(result.predictions, hasLength(1));
    expect(result.predictions.single.dailyPredictions, hasLength(7));
    expect(result.predictions.single.dailyPredictions.first, 1.25);
  });
}
