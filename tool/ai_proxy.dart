import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final int port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final String model = Platform.environment['OPENAI_MODEL'] ?? 'gpt-5-mini';
  final String apiKey = await _readApiKey();
  final HttpServer server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln('FruityVens AI proxy listening on http://0.0.0.0:$port');
  stdout.writeln('Using OpenAI model: $model');

  await for (final HttpRequest request in server) {
    await _handleRequest(request, apiKey: apiKey, model: model);
  }
}

Future<String> _readApiKey() async {
  final File keyFile = File('API-KEY.txt');
  if (await keyFile.exists()) {
    final String key = (await keyFile.readAsString()).trim();
    if (key.isNotEmpty) {
      return key;
    }
  }

  final String? envKey = Platform.environment['OPENAI_API_KEY'];
  if (envKey != null && envKey.trim().isNotEmpty) {
    return envKey.trim();
  }

  throw StateError(
    'Missing OpenAI API key. Add it to API-KEY.txt or OPENAI_API_KEY.',
  );
}

Future<void> _handleRequest(
  HttpRequest request, {
  required String apiKey,
  required String model,
}) async {
  _addCorsHeaders(request.response);

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  if (request.method == 'GET' && request.uri.path == '/health') {
    _sendJson(request.response, <String, Object?>{'ok': true, 'model': model});
    return;
  }

  if (request.method != 'POST' || request.uri.path != '/forecast') {
    _sendJson(request.response, <String, Object?>{
      'error': 'Not found.',
    }, statusCode: HttpStatus.notFound);
    return;
  }

  try {
    final Object? payload = jsonDecode(await utf8.decoder.bind(request).join());
    if (payload is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object.');
    }

    final String summary = await _requestForecastSummary(
      payload,
      apiKey: apiKey,
      model: model,
    );
    _sendJson(request.response, <String, Object?>{
      'summary': summary,
      'source': 'OpenAI Responses API',
      'model': model,
    });
  } on FormatException catch (error) {
    _sendJson(request.response, <String, Object?>{
      'error': error.message,
    }, statusCode: HttpStatus.badRequest);
  } catch (error) {
    final String message = error.toString();
    _sendJson(request.response, <String, Object?>{
      'error': message.startsWith('OpenAI ')
          ? message
          : 'AI automation failed: $message',
    }, statusCode: HttpStatus.badGateway);
  }
}

Future<String> _requestForecastSummary(
  Map<String, Object?> payload, {
  required String apiKey,
  required String model,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('https://api.openai.com/v1/responses'),
    );
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.write(
      jsonEncode(<String, Object?>{
        'model': model,
        'instructions':
            'You are FruityVens AI automation. Analyze fruit inventory and sales data. If cameraEye metadata is present, treat it as a backend-only YOLOv8n stream source and do not ask the app to display the camera feed. Return one concise paragraph with demand forecast, restock advice, and pricing caution for the next 7 days.',
        'input': jsonEncode(payload),
      }),
    );

    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _formatOpenAiError(response.statusCode, body);
    }

    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw 'OpenAI returned invalid JSON.';
    }
    return _extractOutputText(decoded);
  } finally {
    client.close(force: true);
  }
}

String _extractOutputText(Map<String, Object?> response) {
  final Object? outputText = response['output_text'];
  if (outputText is String && outputText.trim().isNotEmpty) {
    return outputText.trim();
  }

  final Object? output = response['output'];
  if (output is List<Object?>) {
    final List<String> parts = <String>[];
    for (final Object? item in output) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final Object? content = item['content'];
      if (content is! List<Object?>) {
        continue;
      }
      for (final Object? part in content) {
        if (part is Map<String, Object?>) {
          final Object? text = part['text'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add(text.trim());
          }
        }
      }
    }
    if (parts.isNotEmpty) {
      return parts.join('\n');
    }
  }

  return 'AI automation completed, but no text output was returned.';
}

void _addCorsHeaders(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
    ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST, OPTIONS')
    ..set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Origin, Content-Type, Accept',
    );
}

void _sendJson(
  HttpResponse response,
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
}) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  response.close();
}

String _compact(String value) {
  final String oneLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 240 ? oneLine : '${oneLine.substring(0, 240)}...';
}

String _formatOpenAiError(int statusCode, String body) {
  String? message;
  String? type;
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) {
      final Object? error = decoded['error'];
      if (error is Map<String, Object?>) {
        final Object? rawMessage = error['message'];
        final Object? rawType = error['type'];
        if (rawMessage is String && rawMessage.trim().isNotEmpty) {
          message = rawMessage.trim();
        }
        if (rawType is String && rawType.trim().isNotEmpty) {
          type = rawType.trim();
        }
      }
    }
  } catch (_) {
    // Keep the compact raw response below when OpenAI returns non-JSON.
  }

  if (statusCode == HttpStatus.tooManyRequests &&
      type == 'insufficient_quota') {
    return 'OpenAI quota is exhausted for this API key. Check billing or use a key with available credits, then retry.';
  }
  if (statusCode == HttpStatus.unauthorized) {
    return 'OpenAI rejected the API key. Check API-KEY.txt or OPENAI_API_KEY, then restart the proxy.';
  }
  if (message != null) {
    return 'OpenAI returned HTTP $statusCode: $message';
  }
  return 'OpenAI returned HTTP $statusCode: ${_compact(body)}';
}
