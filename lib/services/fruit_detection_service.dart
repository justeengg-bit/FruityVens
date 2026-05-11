import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

class FruitDetectionModel {
  const FruitDetectionModel({
    required this.id,
    required this.title,
    required this.assetPath,
    required this.description,
    required this.precision,
    this.recommended = false,
  });

  final String id;
  final String title;
  final String assetPath;
  final String description;
  final String precision;
  final bool recommended;

  String get fileName => assetPath.split('/').last;
}

/// Represents a detected fruit in an image
class FruitDetection {
  const FruitDetection({
    required this.label,
    required this.confidence,
    required this.boundingBox,
    this.x = 0.0,
    this.y = 0.0,
    this.width = 0.0,
    this.height = 0.0,
  });

  /// The detected fruit class/label
  final String label;

  /// Confidence score (0.0 to 1.0)
  final double confidence;

  /// Bounding box coordinates [x1, y1, x2, y2]
  final List<double> boundingBox;

  /// Center X coordinate in original image pixels
  final double x;

  /// Center Y coordinate in original image pixels
  final double y;

  /// Width in original image pixels
  final double width;

  /// Height in original image pixels
  final double height;

  factory FruitDetection.fromJson(Map<String, dynamic> json) {
    final List<dynamic> bbox = json['box'] as List<dynamic>? ?? [];
    return FruitDetection(
      label: json['name'] as String? ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      boundingBox: bbox.map((e) => (e as num).toDouble()).toList(),
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toDouble() ?? 0.0,
      height: (json['height'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': label,
    'confidence': confidence,
    'box': boundingBox,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  @override
  String toString() =>
      'FruitDetection(label: $label, confidence: ${(confidence * 100).toStringAsFixed(1)}%)';
}

/// Results from fruit detection inference
class FruitDetectionResult {
  const FruitDetectionResult({
    required this.detections,
    required this.inferenceTime,
    required this.modelVersion,
    this.modelId,
    this.modelAsset,
    this.imageSize = const (640, 640),
  });

  /// List of detected fruits
  final List<FruitDetection> detections;

  /// Time taken for inference in milliseconds
  final int inferenceTime;

  /// Model version/name
  final String modelVersion;

  final String? modelId;

  final String? modelAsset;

  /// Original image size (width, height)
  final (int, int) imageSize;

  /// Summary statistics
  String get summary {
    final counts = <String, int>{};
    for (final detection in detections) {
      counts[detection.label] = (counts[detection.label] ?? 0) + 1;
    }
    return counts.isEmpty
        ? 'No fruits detected'
        : counts.entries
              .map((e) => '${e.value} ${e.key}${e.value > 1 ? 's' : ''}')
              .join(', ');
  }

  factory FruitDetectionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> detectionsJson =
        json['detections'] as List<dynamic>? ?? [];
    return FruitDetectionResult(
      detections: detectionsJson
          .map((d) => FruitDetection.fromJson(d as Map<String, dynamic>))
          .toList(),
      inferenceTime: json['inference_time'] as int? ?? 0,
      modelVersion: json['model_version'] as String? ?? 'unknown',
      modelId: json['model_id'] as String?,
      modelAsset: json['model_asset'] as String?,
      imageSize: (
        (json['image_width'] as int?) ?? 640,
        (json['image_height'] as int?) ?? 640,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'detections': detections.map((d) => d.toJson()).toList(),
    'inference_time': inferenceTime,
    'model_version': modelVersion,
    if (modelId != null) 'model_id': modelId,
    if (modelAsset != null) 'model_asset': modelAsset,
    'image_width': imageSize.$1,
    'image_height': imageSize.$2,
  };

  @override
  String toString() =>
      'FruitDetectionResult(${detections.length} fruits, ${inferenceTime}ms)';
}

/// Fruit detection service using YOLOv8 model
class FruitDetectionService {
  /// Original training weights kept for desktop/server tooling.
  static const String modelPath = 'models/best.pt';

  /// Mobile/offline model exported from the same YOLOv8 weights.
  static const String onnxModelPath = 'models/best.onnx';

  static const String defaultModelId = 'best';

  static const List<FruitDetectionModel> builtInModels = <FruitDetectionModel>[
    FruitDetectionModel(
      id: 'best',
      title: 'Best ONNX',
      assetPath: onnxModelPath,
      description: 'Recommended trained model for normal scanning.',
      precision: 'Best',
      recommended: true,
    ),
    FruitDetectionModel(
      id: 'int8',
      title: 'ONNX INT8',
      assetPath: 'models/best_int8.onnx',
      description: 'Smallest and fastest option for low-end phones.',
      precision: 'INT8',
    ),
    FruitDetectionModel(
      id: 'float16',
      title: 'ONNX Float16',
      assetPath: 'models/best_float16.onnx',
      description: 'Balanced speed and accuracy for mid-range phones.',
      precision: 'FP16',
    ),
    FruitDetectionModel(
      id: 'float32',
      title: 'ONNX Float32',
      assetPath: 'models/best_float32.onnx',
      description: 'Full precision reference model, may run slower.',
      precision: 'FP32',
    ),
  ];

  /// Path to model configuration
  static const String configPath = 'models/args.yaml';

  static const int inputSize = 640;

  static const List<String> labels = <String>[
    'apple',
    'banana',
    'grape',
    'mango',
    'orange',
  ];

  /// Minimum confidence threshold for detections
  final double confidenceThreshold;

  /// Maximum number of detections to return
  final int maxDetections;

  final double nmsThreshold;

  final FruitDetectionModel model;

  static final OnnxRuntime _runtime = OnnxRuntime();
  static final Map<String, Future<OrtSession>> _sessionFutures =
      <String, Future<OrtSession>>{};

  FruitDetectionService({
    String modelId = defaultModelId,
    this.confidenceThreshold = 0.5,
    this.maxDetections = 100,
    this.nmsThreshold = 0.45,
  }) : model = modelForId(modelId);

  static FruitDetectionModel modelForId(String? id) {
    return builtInModels.firstWhere(
      (FruitDetectionModel model) => model.id == id,
      orElse: () => builtInModels.first,
    );
  }

  /// Check if model files exist locally
  Future<bool> isModelAvailable() async {
    try {
      await rootBundle.load(model.assetPath);
      return true;
    } catch (_) {
      return File(model.assetPath).exists();
    }
  }

  /// Get model file size in bytes
  Future<int> getModelSize() async {
    try {
      final ByteData bytes = await rootBundle.load(model.assetPath);
      return bytes.lengthInBytes;
    } catch (_) {
      // Fall back to local files for desktop/dev workflows.
    }

    final modelFile = File(model.assetPath);
    if (await modelFile.exists()) {
      return await modelFile.length();
    }
    return 0;
  }

  /// Load model metadata from args.yaml
  Future<Map<String, dynamic>> loadModelMetadata() async {
    try {
      String content;
      try {
        content = await rootBundle.loadString(
          'models/best_ncnn_model/metadata.yaml',
        );
      } catch (_) {
        final configFile = File(configPath);
        if (!await configFile.exists()) {
          return {};
        }
        content = await configFile.readAsString();
      }
      // Simple YAML parsing for key values
      final metadata = <String, dynamic>{};
      for (final line in content.split('\n')) {
        if (line.contains(':')) {
          final parts = line.split(':');
          final key = parts[0].trim();
          final value = parts.sublist(1).join(':').trim();
          metadata[key] = value;
        }
      }
      return metadata;
    } catch (e) {
      throw FruitDetectionException('Failed to load model metadata: $e');
    }
  }

  /// Detect fruits from an image file
  Future<FruitDetectionResult> detectFromFile(String imagePath) async {
    if (!File(imagePath).existsSync()) {
      throw FruitDetectionException('Image file not found: $imagePath');
    }

    return detectFromBytes(await File(imagePath).readAsBytes());
  }

  /// Detect fruits from image bytes
  Future<FruitDetectionResult> detectFromBytes(Uint8List imageBytes) async {
    if (!await isModelAvailable()) {
      throw FruitDetectionException(
        'Offline model not available. Add ${model.assetPath} to app assets.',
      );
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    final _PreparedImage prepared = _prepareImage(imageBytes);
    OrtValue? inputTensor;
    Map<String, OrtValue>? outputs;

    try {
      final OrtSession session = await _session(model);
      if (session.inputNames.isEmpty || session.outputNames.isEmpty) {
        throw FruitDetectionException('Offline model has no IO metadata.');
      }

      inputTensor = await OrtValue.fromList(prepared.input, <int>[
        1,
        3,
        inputSize,
        inputSize,
      ]);
      outputs = await session.run(<String, OrtValue>{
        session.inputNames.first: inputTensor,
      });

      final OrtValue? outputTensor = outputs[session.outputNames.first];
      if (outputTensor == null) {
        throw FruitDetectionException('Offline model returned no output.');
      }

      final List<dynamic> rawOutput = await outputTensor.asFlattenedList();
      final List<double> output = rawOutput
          .map((dynamic value) => (value as num).toDouble())
          .toList(growable: false);
      final List<FruitDetection> detections = _decodeYoloOutput(
        output,
        prepared,
      );

      stopwatch.stop();
      return FruitDetectionResult(
        detections: detections,
        inferenceTime: stopwatch.elapsedMilliseconds,
        modelVersion: '${model.title} offline',
        modelId: model.id,
        modelAsset: model.assetPath,
        imageSize: (prepared.originalWidth, prepared.originalHeight),
      );
    } finally {
      await inputTensor?.dispose();
      if (outputs != null) {
        for (final OrtValue value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  static Future<OrtSession> _session(FruitDetectionModel model) {
    return _sessionFutures[model.id] ??= _runtime.createSessionFromAsset(
      model.assetPath,
      options: OrtSessionOptions(intraOpNumThreads: 2),
    );
  }

  _PreparedImage _prepareImage(Uint8List imageBytes) {
    final img.Image? decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw FruitDetectionException('Image format is not supported.');
    }

    final img.Image rgbImage = decoded.numChannels == 3
        ? decoded
        : decoded.convert(numChannels: 3);
    final double scale = math.min(
      inputSize / rgbImage.width,
      inputSize / rgbImage.height,
    );
    final int resizedWidth = (rgbImage.width * scale).round();
    final int resizedHeight = (rgbImage.height * scale).round();
    final int padX = ((inputSize - resizedWidth) / 2).floor();
    final int padY = ((inputSize - resizedHeight) / 2).floor();

    final img.Image resized = img.copyResize(
      rgbImage,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );
    final img.Image canvas = img.Image(
      width: inputSize,
      height: inputSize,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(canvas, resized, dstX: padX, dstY: padY);

    final Float32List input = Float32List(3 * inputSize * inputSize);
    const int channelSize = inputSize * inputSize;
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final img.Pixel pixel = canvas.getPixel(x, y);
        final int offset = y * inputSize + x;
        input[offset] = pixel.r / 255.0;
        input[channelSize + offset] = pixel.g / 255.0;
        input[channelSize * 2 + offset] = pixel.b / 255.0;
      }
    }

    return _PreparedImage(
      input: input,
      originalWidth: rgbImage.width,
      originalHeight: rgbImage.height,
      scale: scale,
      padX: padX.toDouble(),
      padY: padY.toDouble(),
    );
  }

  List<FruitDetection> _decodeYoloOutput(
    List<double> output,
    _PreparedImage image,
  ) {
    final int channelCount = 4 + labels.length;
    if (output.length % channelCount != 0) {
      throw FruitDetectionException(
        'Unexpected YOLO output size: ${output.length}.',
      );
    }
    final int boxCount = output.length ~/ channelCount;
    final List<FruitDetection> candidates = <FruitDetection>[];

    for (int index = 0; index < boxCount; index++) {
      int bestClass = 0;
      double bestScore = output[(4 * boxCount) + index];
      for (int classIndex = 1; classIndex < labels.length; classIndex++) {
        final double score = output[((4 + classIndex) * boxCount) + index];
        if (score > bestScore) {
          bestScore = score;
          bestClass = classIndex;
        }
      }
      if (bestScore < confidenceThreshold) {
        continue;
      }

      final double cx = output[index];
      final double cy = output[boxCount + index];
      final double width = output[(2 * boxCount) + index];
      final double height = output[(3 * boxCount) + index];
      final double x1 = ((cx - width / 2) - image.padX) / image.scale;
      final double y1 = ((cy - height / 2) - image.padY) / image.scale;
      final double x2 = ((cx + width / 2) - image.padX) / image.scale;
      final double y2 = ((cy + height / 2) - image.padY) / image.scale;
      final List<double> box = <double>[
        x1.clamp(0, image.originalWidth.toDouble()).toDouble(),
        y1.clamp(0, image.originalHeight.toDouble()).toDouble(),
        x2.clamp(0, image.originalWidth.toDouble()).toDouble(),
        y2.clamp(0, image.originalHeight.toDouble()).toDouble(),
      ];

      candidates.add(
        FruitDetection(
          label: labels[bestClass],
          confidence: bestScore,
          boundingBox: box,
          x: (box[0] + box[2]) / 2,
          y: (box[1] + box[3]) / 2,
          width: box[2] - box[0],
          height: box[3] - box[1],
        ),
      );
    }

    candidates.sort(
      (FruitDetection a, FruitDetection b) =>
          b.confidence.compareTo(a.confidence),
    );
    final List<FruitDetection> kept = <FruitDetection>[];
    for (final FruitDetection candidate in candidates) {
      final bool overlaps = kept.any(
        (FruitDetection existing) =>
            existing.label == candidate.label &&
            _iou(existing.boundingBox, candidate.boundingBox) > nmsThreshold,
      );
      if (!overlaps) {
        kept.add(candidate);
        if (kept.length >= maxDetections) {
          break;
        }
      }
    }
    return kept;
  }

  double _iou(List<double> a, List<double> b) {
    final double x1 = math.max(a[0], b[0]);
    final double y1 = math.max(a[1], b[1]);
    final double x2 = math.min(a[2], b[2]);
    final double y2 = math.min(a[3], b[3]);
    final double intersection = math.max(0, x2 - x1) * math.max(0, y2 - y1);
    final double areaA = math.max(0, a[2] - a[0]) * math.max(0, a[3] - a[1]);
    final double areaB = math.max(0, b[2] - b[0]) * math.max(0, b[3] - b[1]);
    final double union = areaA + areaB - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  /// Filter detections by confidence threshold
  List<FruitDetection> filterDetections(
    List<FruitDetection> detections, {
    double? threshold,
  }) {
    final minConfidence = threshold ?? confidenceThreshold;
    return detections
        .where((d) => d.confidence >= minConfidence)
        .take(maxDetections)
        .toList();
  }

  /// Group detections by fruit type
  Map<String, List<FruitDetection>> groupDetectionsByLabel(
    List<FruitDetection> detections,
  ) {
    final grouped = <String, List<FruitDetection>>{};
    for (final detection in detections) {
      grouped.putIfAbsent(detection.label, () => []).add(detection);
    }
    return grouped;
  }

  /// Calculate fruit distribution statistics
  Map<String, dynamic> getDetectionStats(List<FruitDetection> detections) {
    if (detections.isEmpty) {
      return {'total_fruits': 0, 'unique_types': 0, 'average_confidence': 0.0};
    }

    final grouped = groupDetectionsByLabel(detections);
    final avgConfidence =
        detections.map((d) => d.confidence).reduce((a, b) => a + b) /
        detections.length;

    return {
      'total_fruits': detections.length,
      'unique_types': grouped.length,
      'average_confidence': avgConfidence,
      'fruit_counts': grouped.map((k, v) => MapEntry(k, v.length)),
      'detected_types': grouped.keys.toList(),
    };
  }
}

/// Exception for fruit detection errors
class FruitDetectionException implements Exception {
  FruitDetectionException(this.message);

  final String message;

  @override
  String toString() => 'FruitDetectionException: $message';
}

class _PreparedImage {
  const _PreparedImage({
    required this.input,
    required this.originalWidth,
    required this.originalHeight,
    required this.scale,
    required this.padX,
    required this.padY,
  });

  final Float32List input;
  final int originalWidth;
  final int originalHeight;
  final double scale;
  final double padX;
  final double padY;
}
