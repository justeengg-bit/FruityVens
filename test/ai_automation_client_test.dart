import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/services/ai_automation_client.dart';

void main() {
  test('forecast response preserves daily model predictions', () {
    final AiAutomationResult result = AiAutomationResult.fromJson(
      <String, Object?>{
        'summary': 'Forecast ready.',
        'model': 'XGBRegressor',
        'source': 'FruityVens ML Forecast Server',
        'dataCoverage': <String, Object?>{
          'transactionCount': 90,
          'observedDays': 30,
          'dataStart': '2026-01-01',
          'dataEnd': '2026-02-15',
          'fruits': <String>['Mango'],
        },
        'forecastStart': '2026-02-16',
        'forecastEnd': '2026-02-22',
        'validation': <String, Object?>{
          'evaluatedDays': 14,
          'maeKg': 0.24,
          'wapePercent': 18.3,
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
            'seasonality': <String, Object?>{
              'supply': <String, Object?>{
                'period': 'Q1',
                'seasonalIndex': 1.2,
                'geography': 'Northern Mindanao (Region X)',
              },
            },
          },
        ],
      },
    );

    expect(result.coverage!.observedDays, 30);
    expect(result.predictions, hasLength(1));
    expect(result.predictions.single.dailyPredictions, hasLength(7));
    expect(result.predictions.single.dailyPredictions.first, 1.25);
    expect(result.forecastStart, DateTime(2026, 2, 16));
    expect(result.forecastEnd, DateTime(2026, 2, 22));
    expect(result.validation!.evaluatedDays, 14);
    expect(result.validation!.maeKg, 0.24);
    expect(result.predictions.single.seasonality['supply'], isA<Map>());
  });

  test('forecast defaults to the hosted Render service', () {
    expect(
      const AiAutomationClient().baseUrls,
      'https://fruityvens.onrender.com',
    );
  });
}
