import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// YOLOv8 model inference engine using Python subprocess
class YoloModelEngine {
  final String modelPath;
  final String pythonScript;
  static const String defaultPythonScript = '''
import sys
import json
from ultralytics import YOLO

def run_inference(image_path, model_path, conf=0.5):
    model = YOLO(model_path)
    results = model.predict(source=image_path, conf=conf, verbose=False)
    
    detections = []
    for result in results:
        for box in result.boxes:
            detection = {
                "name": result.names[int(box.cls)],
                "confidence": float(box.conf),
                "box": [float(x) for x in box.xyxy[0].tolist()],
                "x": float(box.xywh[0][0]),
                "y": float(box.xywh[0][1]),
                "width": float(box.xywh[0][2]),
                "height": float(box.xywh[0][3]),
            }
            detections.append(detection)
    
    return {
        "detections": detections,
        "success": True,
        "image_width": result.orig_shape[1],
        "image_height": result.orig_shape[0],
    }

if __name__ == "__main__":
    image_path = sys.argv[1]
    model_path = sys.argv[2]
    conf = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    
    try:
        result = run_inference(image_path, model_path, conf)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e), "success": False}))
''';

  YoloModelEngine({required this.modelPath, required this.pythonScript});

  /// Run inference on an image
  Future<Map<String, dynamic>> inferImage(
    String imagePath, {
    double confidence = 0.5,
  }) async {
    try {
      final processResult = await Process.run('python', [
        '-c',
        pythonScript,
        imagePath,
        modelPath,
        confidence.toString(),
      ], runInShell: true);

      if (processResult.exitCode != 0) {
        throw Exception('Python process failed: ${processResult.stderr}');
      }

      final output =
          jsonDecode(processResult.stdout as String) as Map<String, dynamic>;
      return output;
    } catch (e) {
      throw Exception('Model inference failed: $e');
    }
  }
}

Future<void> main(List<String> args) async {
  final int port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final String modelPath =
      Platform.environment['MODEL_PATH'] ?? 'models/best.pt';
  final bool useModel = Platform.environment['USE_MODEL'] == 'true';
  final String model = Platform.environment['OPENAI_MODEL'] ?? 'gpt-4-mini';
  final String? apiKey = await _readApiKey();

  final HttpServer server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln('FruityVens AI proxy listening on http://0.0.0.0:$port');
  if (useModel) {
    stdout.writeln('Model inference: YOLOv8 @ $modelPath');
  } else {
    stdout.writeln('Using OpenAI model: $model');
  }

  final modelEngine = useModel
      ? YoloModelEngine(
          modelPath: modelPath,
          pythonScript: YoloModelEngine.defaultPythonScript,
        )
      : null;

  await for (final HttpRequest request in server) {
    unawaited(
      _handleRequest(
        request,
        apiKey: apiKey,
        model: model,
        modelEngine: modelEngine,
      ),
    );
  }
}

Future<String?> _readApiKey() async {
  final File keyFile = File('API-KEY.txt');
  if (await keyFile.exists()) {
    final String key = (await keyFile.readAsString()).trim();
    if (key.isNotEmpty) return key;
  }

  final String? envKey = Platform.environment['OPENAI_API_KEY'];
  if (envKey != null && envKey.trim().isNotEmpty) {
    return envKey.trim();
  }

  return null;
}

Future<void> _handleRequest(
  HttpRequest request, {
  required String? apiKey,
  required String model,
  required YoloModelEngine? modelEngine,
}) async {
  _addCorsHeaders(request.response);

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  try {
    if (request.method == 'GET' && request.uri.path == '/health') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write(
          jsonEncode({
            'status': 'healthy',
            'model_engine': modelEngine != null,
          }),
        )
        ..close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/detect') {
      if (modelEngine == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write(jsonEncode({'error': 'Model engine not enabled'}))
          ..close();
        return;
      }

      final body = await _readRequestBody(request);
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final imagePath = payload['image_path'] as String?;
      final confidence = (payload['confidence'] as num?)?.toDouble() ?? 0.5;

      if (imagePath == null || imagePath.isEmpty) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write(jsonEncode({'error': 'Missing image_path'}))
          ..close();
        return;
      }

      final result = await modelEngine.inferImage(
        imagePath,
        confidence: confidence,
      );

      request.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(result))
        ..close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/forecast') {
      if (apiKey == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write(jsonEncode({'error': 'API key not configured'}))
          ..close();
        return;
      }

      // Handle forecast request with OpenAI or local model
      await _readRequestBody(request);
      // Implementation would go here
      request.response
        ..statusCode = HttpStatus.ok
        ..write(
          jsonEncode({
            'summary': 'Forecast generated',
            'model': model,
            'source': 'ai',
          }),
        )
        ..close();
      return;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..write(jsonEncode({'error': 'Not found'}))
      ..close();
  } catch (error) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write(jsonEncode({'error': error.toString()}))
      ..close();
  }
}

Future<String> _readRequestBody(HttpRequest request) async {
  final buffer = <int>[];
  await for (final chunk in request) {
    buffer.addAll(chunk);
  }
  return utf8.decode(buffer);
}

void _addCorsHeaders(HttpResponse response) {
  response.headers.add('Access-Control-Allow-Origin', '*');
  response.headers.add(
    'Access-Control-Allow-Methods',
    'GET, POST, OPTIONS, PUT, DELETE',
  );
  response.headers.add(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization',
  );
}
