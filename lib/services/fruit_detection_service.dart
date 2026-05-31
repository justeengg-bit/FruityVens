/// Represents a detected fruit in an image.
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

  /// The detected fruit class/label.
  final String label;

  /// Confidence score (0.0 to 1.0).
  final double confidence;

  /// Bounding box coordinates [x1, y1, x2, y2].
  final List<double> boundingBox;

  /// Center X coordinate in original image pixels.
  final double x;

  /// Center Y coordinate in original image pixels.
  final double y;

  /// Width in original image pixels.
  final double width;

  /// Height in original image pixels.
  final double height;

  factory FruitDetection.fromJson(Map<String, dynamic> json) {
    final List<dynamic> bbox = json['box'] as List<dynamic>? ?? <dynamic>[];
    return FruitDetection(
      label: json['name'] as String? ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      boundingBox: bbox.map((dynamic e) => (e as num).toDouble()).toList(),
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toDouble() ?? 0.0,
      height: (json['height'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
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

/// Results from fruit detection inference.
class FruitDetectionResult {
  const FruitDetectionResult({
    required this.detections,
    required this.inferenceTime,
    required this.modelVersion,
    this.imageSize = const (640, 640),
  });

  /// List of detected fruits.
  final List<FruitDetection> detections;

  /// Time taken for inference in milliseconds.
  final int inferenceTime;

  /// Detection service/model version name.
  final String modelVersion;

  /// Original image size (width, height).
  final (int, int) imageSize;

  /// Summary statistics.
  String get summary {
    final Map<String, int> counts = <String, int>{};
    for (final FruitDetection detection in detections) {
      counts[detection.label] = (counts[detection.label] ?? 0) + 1;
    }
    return counts.isEmpty
        ? 'No fruits detected'
        : counts.entries
              .map(
                (MapEntry<String, int> e) =>
                    '${e.value} ${e.key}${e.value > 1 ? 's' : ''}',
              )
              .join(', ');
  }

  factory FruitDetectionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> detectionsJson =
        json['detections'] as List<dynamic>? ?? <dynamic>[];
    return FruitDetectionResult(
      detections: detectionsJson
          .map(
            (dynamic d) => FruitDetection.fromJson(d as Map<String, dynamic>),
          )
          .toList(),
      inferenceTime: json['inference_time'] as int? ?? 0,
      modelVersion: json['model_version'] as String? ?? 'remote detector',
      imageSize: (
        (json['image_width'] as int?) ?? 640,
        (json['image_height'] as int?) ?? 640,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'detections': detections.map((FruitDetection d) => d.toJson()).toList(),
    'inference_time': inferenceTime,
    'model_version': modelVersion,
    'image_width': imageSize.$1,
    'image_height': imageSize.$2,
  };

  @override
  String toString() =>
      'FruitDetectionResult(${detections.length} fruits, ${inferenceTime}ms)';
}
