import 'dart:convert';
import 'dart:developer' as developer;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:http/http.dart' as http;

import 'fruit_detection_service.dart';

class AiAutomationResult {
  const AiAutomationResult({
    required this.summary,
    required this.model,
    required this.source,
  });

  final String summary;
  final String model;
  final String source;

  String get sourceLabel => '$source / $model';

  factory AiAutomationResult.fromJson(Map<String, Object?> json) {
    return AiAutomationResult(
      summary: json['summary'] as String? ?? 'AI automation returned no text.',
      model: json['model'] as String? ?? 'unknown model',
      source: json['source'] as String? ?? 'ai',
    );
  }
}

class AiAutomationClient {
  const AiAutomationClient({
    this.forecastModel = const String.fromEnvironment(
      'FRUITYVENS_AI_MODEL',
      defaultValue: 'gemini-2.5-flash-lite',
    ),
    this.baseUrls = const String.fromEnvironment(
      'FRUITYVENS_AI_BASE_URL',
      defaultValue: 'http://127.0.0.1:8787,http://192.168.1.9:8787',
    ),
  });

  final String forecastModel;
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
    Map<String, Object?>? cameraEye,
  }) async {
    final Map<String, Object?> forecastInput = <String, Object?>{
      'inventory': inventory,
      'salesSnapshot': salesSnapshot,
      if (cameraEye != null) 'cameraEye': cameraEye,
      'rules': const <String>[
        'Use only the supplied inventory and salesSnapshot values.',
        'Do not invent exact sales, customers, spoilage, or camera detections.',
        'Keep the recommendation aligned with fruit price and recent transactions.',
        'Do not assume remaining stock unless stockTracking is explicitly true.',
        'If data is limited, say confidence is low and explain what data is missing.',
      ],
    };

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
    String modelId = FruitDetectionService.defaultModelId,
  }) async {
    try {
      final FruitDetectionResult offlineResult = await FruitDetectionService(
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
      ).detectFromFile(imagePath);
      return <String, dynamic>{
        ...offlineResult.toJson(),
        'success': true,
        'source': offlineResult.modelVersion,
      };
    } on FruitDetectionException {
      // Fall through to the network proxy for development machines that still
      // run the Python/Ultralytics bridge.
    }

    final String requestBody = jsonEncode(<String, Object?>{
      'image_path': imagePath,
      'confidence': confidenceThreshold,
      'model_id': modelId,
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
