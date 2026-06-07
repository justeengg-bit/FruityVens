import 'dart:convert';
import 'dart:developer' as developer;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_auth/firebase_auth.dart' as auth;
import 'package:http/http.dart' as http;

class AiForecastPrediction {
  const AiForecastPrediction({
    required this.fruit,
    required this.predictedKgTomorrow,
    required this.predictedKgTotal,
    required this.recommendation,
    required this.confidence,
    required this.reason,
  });

  final String fruit;
  final double predictedKgTomorrow;
  final double predictedKgTotal;
  final String recommendation;
  final String confidence;
  final String reason;

  factory AiForecastPrediction.fromJson(Map<String, Object?> json) {
    return AiForecastPrediction(
      fruit: json['fruit']?.toString() ?? '',
      predictedKgTomorrow: _doubleValue(json['predictedKgTomorrow']),
      predictedKgTotal: _doubleValue(json['predictedKgTotal']),
      recommendation: json['recommendation']?.toString() ?? '',
      confidence: json['confidence']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
    );
  }
}

class AiAutomationResult {
  const AiAutomationResult({
    required this.summary,
    required this.model,
    required this.source,
    this.predictions = const <AiForecastPrediction>[],
  });

  final String summary;
  final String model;
  final String source;
  final List<AiForecastPrediction> predictions;

  String get sourceLabel => '$source / $model';

  factory AiAutomationResult.fromJson(Map<String, Object?> json) {
    return AiAutomationResult(
      summary: json['summary'] as String? ?? 'AI automation returned no text.',
      model: json['model'] as String? ?? 'unknown model',
      source: json['source'] as String? ?? 'ai',
      predictions: _predictionList(json['predictions']),
    );
  }
}

double _doubleValue(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

List<AiForecastPrediction> _predictionList(Object? value) {
  if (value is! List<Object?>) {
    return const <AiForecastPrediction>[];
  }
  final List<AiForecastPrediction> predictions = <AiForecastPrediction>[];
  for (final Object? item in value) {
    if (item is! Map) {
      continue;
    }
    final Map<String, Object?> json = <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in item.entries)
        entry.key.toString(): entry.value,
    };
    final AiForecastPrediction prediction = AiForecastPrediction.fromJson(json);
    if (prediction.fruit.isNotEmpty) {
      predictions.add(prediction);
    }
  }
  return predictions;
}

class AiAutomationClient {
  const AiAutomationClient({
    this.forecastModel = const String.fromEnvironment(
      'FRUITYVENS_AI_MODEL',
      defaultValue: 'gemini-2.5-flash-lite',
    ),
    this.enableFirebaseAiFallback = const bool.fromEnvironment(
      'FRUITYVENS_ENABLE_FIREBASE_AI_FALLBACK',
      defaultValue: false,
    ),
    this.baseUrls = const String.fromEnvironment(
      'FRUITYVENS_AI_BASE_URL',
      defaultValue: 'http://127.0.0.1:8787,http://192.168.1.9:8787',
    ),
  });

  final String forecastModel;
  final bool enableFirebaseAiFallback;
  final String baseUrls;

  List<String> get _candidateBaseUrls {
    final List<String> urls = baseUrls
        .split(RegExp(r'[,;\s]+'))
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .map(
          (String value) => value.endsWith('/')
              ? value.substring(0, value.length - 1)
              : value,
        )
        .toList();
    return urls.isEmpty ? const <String>['http://127.0.0.1:8787'] : urls;
  }

  Future<AiAutomationResult> generateForecast({
    required List<Map<String, Object?>> inventory,
    required Map<String, Object?> salesSnapshot,
    List<Map<String, Object?>> transactions = const <Map<String, Object?>>[],
    Map<String, Object?>? cameraEye,
  }) async {
    final Map<String, Object?> forecastInput = <String, Object?>{
      'horizon_days': 7,
      'inventory': inventory,
      'salesSnapshot': salesSnapshot,
      if (transactions.isNotEmpty) 'transactions': transactions,
      if (cameraEye != null) 'cameraEye': cameraEye,
      'rules': const <String>[
        'Use only the supplied inventory and salesSnapshot values.',
        'Do not invent exact sales, customers, spoilage, or camera detections.',
        'Keep the recommendation aligned with fruit price and recent transactions.',
        'Do not assume remaining stock unless stockTracking is explicitly true.',
        'If data is limited, say confidence is low and explain what data is missing.',
      ],
    };

    final AiAutomationResult? gradientBoostingForecast =
        await _tryGradientBoostingForecast(forecastInput);
    if (gradientBoostingForecast != null) {
      return gradientBoostingForecast;
    }
    if (!enableFirebaseAiFallback) {
      throw const AiAutomationException(
        'Forecast server unavailable. Start the local forecast server, run adb reverse tcp:8787 tcp:8787, then try Generate forecast again.',
      );
    }

    final String prompt =
        '''
You are the forecasting assistant inside FruityVens, a mobile fruit vendor app.
The app already performs the numeric calculations. Your job is to explain the
forecast and give practical restock/price warnings based only on this JSON data.

Return only valid JSON with this shape:
{
  "summary": "3-5 concise sentences for the seller",
  "riskLevel": "low|medium|high",
  "confidence": "low|medium|high",
  "warnings": ["short warning"],
  "restockAdvice": ["short action"]
}

Input:
${jsonEncode(forecastInput)}
''';

    try {
      final GenerativeModel model =
          FirebaseAI.googleAI(
            appCheck: FirebaseAppCheck.instance,
          ).generativeModel(
            model: forecastModel,
            generationConfig: GenerationConfig(
              responseMimeType: 'application/json',
              temperature: 0.2,
              maxOutputTokens: 700,
            ),
            systemInstruction: Content.system(
              'You produce JSON-only operational forecasting advice for FruityVens.',
            ),
          );
      final GenerateContentResponse response = await model
          .generateContent(<Content>[Content.text(prompt)])
          .timeout(const Duration(seconds: 25));
      final String? responseText = response.text;
      if (responseText == null || responseText.trim().isEmpty) {
        throw const AiAutomationException('Firebase AI returned no forecast.');
      }
      final Map<String, Object?> decoded = _decodeJsonObject(responseText);
      final String summary = decoded['summary'] as String? ?? '';
      if (summary.trim().isEmpty) {
        throw const AiAutomationException(
          'Firebase AI returned a forecast without a summary.',
        );
      }
      return AiAutomationResult(
        summary: _formatForecastSummary(decoded),
        model: forecastModel,
        source: 'Firebase AI Logic',
      );
    } on AiAutomationException {
      rethrow;
    } catch (error, stackTrace) {
      developer.log(
        'Firebase AI forecast failed',
        name: 'FruityVensAI',
        error: error,
        stackTrace: stackTrace,
      );
      throw AiAutomationException(
        'Firebase AI forecast failed. Details: $error',
      );
    }
  }

  Future<AiAutomationResult?> _tryGradientBoostingForecast(
    Map<String, Object?> forecastInput,
  ) async {
    final String? token = await _firebaseIdTokenBestEffort();
    final List<String> connectionErrors = <String>[];

    for (final String baseUrl in _candidateBaseUrls) {
      final Uri uri = Uri.parse('$baseUrl/forecast');
      try {
        final Map<String, String> headers = <String, String>{
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        };
        final http.Response response = await http
            .post(uri, headers: headers, body: jsonEncode(forecastInput))
            .timeout(const Duration(seconds: 25));
        final Object? decoded = jsonDecode(response.body);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final String message = decoded is Map<String, Object?>
              ? decoded['detail']?.toString() ??
                    decoded['error']?.toString() ??
                    'Gradient Boosting forecast failed.'
              : 'Gradient Boosting forecast failed.';
          connectionErrors.add('$baseUrl: $message');
          continue;
        }
        if (decoded is! Map<String, Object?>) {
          connectionErrors.add('$baseUrl: invalid JSON response');
          continue;
        }
        final String summary = decoded['summary'] as String? ?? '';
        if (summary.trim().isEmpty) {
          connectionErrors.add('$baseUrl: empty forecast summary');
          continue;
        }
        return AiAutomationResult.fromJson(<String, Object?>{
          'summary': summary,
          'model': decoded['model'] as String? ?? 'GradientBoostingRegressor',
          'source':
              decoded['source'] as String? ?? 'FruityVens ML Forecast Server',
          'predictions': decoded['predictions'],
        });
      } catch (error) {
        connectionErrors.add('$baseUrl: $error');
      }
    }

    if (connectionErrors.isNotEmpty) {
      developer.log(
        'Gradient Boosting forecast server unavailable: ${connectionErrors.join(' | ')}',
        name: 'FruityVensAI',
      );
    }
    return null;
  }

  Future<String?> _firebaseIdTokenBestEffort() async {
    try {
      final auth.User? user = auth.FirebaseAuth.instance.currentUser;
      if (user == null) {
        return null;
      }
      return user.getIdToken();
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _decodeJsonObject(String responseText) {
    String cleanText = responseText.trim();
    if (cleanText.startsWith('```')) {
      cleanText = cleanText.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      cleanText = cleanText.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final Object? decoded = jsonDecode(cleanText);
    if (decoded is! Map<String, Object?>) {
      throw const AiAutomationException(
        'Firebase AI returned invalid forecast data.',
      );
    }
    return decoded;
  }

  String _formatForecastSummary(Map<String, Object?> decoded) {
    final String summary = (decoded['summary'] as String? ?? '').trim();
    final String riskLevel = (decoded['riskLevel'] as String? ?? '').trim();
    final String confidence = (decoded['confidence'] as String? ?? '').trim();
    final List<String> warnings = _stringList(decoded['warnings']);
    final List<String> restockAdvice = _stringList(decoded['restockAdvice']);

    final StringBuffer buffer = StringBuffer(summary);
    if (riskLevel.isNotEmpty || confidence.isNotEmpty) {
      buffer.write('\n\n');
      if (riskLevel.isNotEmpty) {
        buffer.write('Risk: $riskLevel');
      }
      if (riskLevel.isNotEmpty && confidence.isNotEmpty) {
        buffer.write(' | ');
      }
      if (confidence.isNotEmpty) {
        buffer.write('Confidence: $confidence');
      }
    }
    if (warnings.isNotEmpty) {
      buffer.write('\n\nWarnings: ${warnings.join(' ')}');
    }
    if (restockAdvice.isNotEmpty) {
      buffer.write('\n\nRestock advice: ${restockAdvice.join(' ')}');
    }
    return buffer.toString();
  }

  List<String> _stringList(Object? value) {
    if (value is! List<Object?>) {
      return const <String>[];
    }
    return value
        .whereType<String>()
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> detectFruits({
    required String imagePath,
    double confidenceThreshold = 0.5,
  }) async {
    final String requestBody = jsonEncode(<String, Object?>{
      'image_path': imagePath,
      'confidence': confidenceThreshold,
    });
    final List<String> connectionErrors = <String>[];

    for (final String baseUrl in _candidateBaseUrls) {
      final Uri uri = Uri.parse('$baseUrl/detect');
      try {
        final http.Response response = await http
            .post(
              uri,
              headers: const <String, String>{
                'Content-Type': 'application/json',
              },
              body: requestBody,
            )
            .timeout(const Duration(seconds: 30));

        final Object? decoded = jsonDecode(response.body);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final String message = decoded is Map<String, Object?>
              ? decoded['error'] as String? ?? 'Fruit detection failed.'
              : 'Fruit detection failed.';
          throw AiAutomationException(message);
        }
        if (decoded is! Map<String, Object?>) {
          throw const AiAutomationException(
            'Fruit detection returned invalid data.',
          );
        }
        return decoded;
      } on AiAutomationException {
        rethrow;
      } catch (error) {
        connectionErrors.add('$baseUrl: $error');
      }
    }

    throw AiAutomationException(
      'Fruit detection service is not reachable. Make sure the AI proxy is running with model support. Tried: ${connectionErrors.join(' | ')}',
    );
  }
}

class AiAutomationException implements Exception {
  const AiAutomationException(this.message);

  final String message;

  @override
  String toString() => message;
}
