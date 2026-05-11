# FruityVens YOLOv8 Model Integration Guide

## Overview
Your fruit detection YOLOv8 model has been successfully integrated into the FruityVens app. The model (`best.pt`) is now available in the `models/` directory.

## Model Files

```
fruityvens_app/
├── models/
│   ├── best.pt          (6.2 MB) - Trained YOLOv8 model weights
│   ├── args.yaml        (1.8 KB) - Training configuration
│   └── results.csv      (4.5 KB) - Training metrics
```

## Setup Instructions

### 1. Prerequisites
Install required Python packages for the AI proxy:
```bash
pip install ultralytics torch torchvision opencv-python pillow
```

### 2. Run the Enhanced AI Proxy with Model Support
```bash
cd fruityvens_app/tool
dart ai_proxy_enhanced.dart
```

Or with environment variables:
```bash
export USE_MODEL=true
export MODEL_PATH=$(pwd)/../models/best.pt
dart ai_proxy_enhanced.dart
```

### 3. Configuration
The proxy listens on `http://127.0.0.1:8787` by default. You can change the port:
```bash
PORT=8787 dart ai_proxy_enhanced.dart
```

## Usage

### From Flutter App

#### Detect Fruits from Image File
```dart
import 'package:fruityvens_app/services/ai_automation_client.dart';

final aiClient = AiAutomationClient();

// Detect fruits in an image
final results = await aiClient.detectFruits(
  imagePath: '/path/to/image.jpg',
  confidenceThreshold: 0.5,
);

print('Detections: ${results['detections']}');
```

#### Process Camera Feed
```dart
import 'package:fruityvens_app/services/fruit_detection_service.dart';

final detector = FruitDetectionService(
  confidenceThreshold: 0.5,
  maxDetections: 100,
);

// Check if model is available
if (await detector.isModelAvailable()) {
  print('Model size: ${await detector.getModelSize()} bytes');
  final metadata = await detector.loadModelMetadata();
  print('Model config: $metadata');
}

// Process detections
final fruitData = ...; // From camera feed
// When integrated with native plugin, will use:
// final result = await detector.detectFromBytes(fruitData);
```

### API Endpoints

#### Health Check
```bash
curl http://127.0.0.1:8787/health
```
Response:
```json
{
  "status": "healthy",
  "model_engine": true
}
```

#### Fruit Detection
```bash
curl -X POST http://127.0.0.1:8787/detect \
  -H "Content-Type: application/json" \
  -d '{
    "image_path": "/path/to/image.jpg",
    "confidence": 0.5
  }'
```

Response:
```json
{
  "detections": [
    {
      "name": "apple",
      "confidence": 0.92,
      "box": [100, 150, 250, 300],
      "x": 175,
      "y": 225,
      "width": 150,
      "height": 150
    }
  ],
  "image_width": 640,
  "image_height": 640,
  "success": true
}
```

#### Forecast (Legacy OpenAI)
```bash
curl -X POST http://127.0.0.1:8787/forecast \
  -H "Content-Type: application/json" \
  -d '{
    "inventory": [...],
    "salesSnapshot": {...},
    "cameraEye": {...}
  }'
```

## Integration Points

### 1. AI Automation Client
- **File**: `lib/services/ai_automation_client.dart`
- **New Method**: `detectFruits()` - Call the `/detect` endpoint
- **Purpose**: Bridge between Flutter app and AI proxy

### 2. Fruit Detection Service
- **File**: `lib/services/fruit_detection_service.dart`
- **Key Classes**:
  - `FruitDetection` - Individual detection object
  - `FruitDetectionResult` - Complete detection result
  - `FruitDetectionService` - Service layer
- **Purpose**: Local model management and metadata handling

### 3. Camera Eye Service
- **File**: `lib/services/camera_eye_service.dart`
- **Integration**: Can pass camera stream to detection service once native plugin is added

### 4. Enhanced AI Proxy
- **File**: `tool/ai_proxy_enhanced.dart`
- **Endpoints**: 
  - `/detect` - YOLOv8 inference
  - `/forecast` - OpenAI integration (legacy)
  - `/health` - Status check
- **Purpose**: Local inference engine with Python subprocess

## Model Details

### Classes Detected
Your model is trained to detect fruit types. Run model detection to see what fruits it recognizes.

### Performance Metrics
Check `models/results.csv` for training metrics:
- Precision, Recall, mAP scores
- Training loss curves
- Validation metrics

### Configuration
See `models/args.yaml` for:
- Image size used for training
- Batch size
- Number of epochs
- Learning rate
- Augmentation settings

## Troubleshooting

### "Model not available" Error
- Ensure `models/best.pt` exists in project root
- The file should be 6.2 MB in size

### Python Process Failed
- Make sure Python 3.8+ is installed: `python --version`
- Install dependencies: `pip install -r requirements.txt` (if exists) or manually:
  ```bash
  pip install ultralytics torch torchvision opencv-python
  ```

### Connection Refused
- Verify AI proxy is running on the expected port
- Check port conflicts: `netstat -an | grep 8787` (Windows) or `lsof -i :8787` (macOS/Linux)
- Try starting on a different port: `PORT=9000 dart ai_proxy_enhanced.dart`

### Slow Inference
- First inference takes longer due to model loading (~1-2 seconds)
- Subsequent inferences are faster (100-500ms on CPU)
- Consider using GPU if available: Install CUDA and `torch` with GPU support

## Next Steps

### 1. Native Plugin Integration
To run inference directly in Flutter (without proxy):
- Create a native Android/iOS plugin using TensorFlow Lite or PyTorch Mobile
- Convert model: `yolo export model=models/best.pt format=tflite`
- Embed in Flutter with `tflite_flutter` or `pytorch_flutter`

### 2. Real-time Camera Detection
- Integrate with `camera` package for live stream
- Pass frames to detection service
- Display detections with bounding boxes

### 3. Optimization
- Quantize model for faster inference
- Use INT8 quantization for 3-4x speedup
- Profile on actual device for performance tuning

### 4. Database Integration
- Store detection results in SQLite (`sqflite`)
- Link with inventory management
- Track fruit counts over time

## File Structure Reference
```
fruityvens_app/
├── lib/
│   ├── services/
│   │   ├── ai_automation_client.dart      (Updated with detectFruits)
│   │   ├── fruit_detection_service.dart   (New - model management)
│   │   ├── camera_eye_service.dart        (Camera stream)
│   │   └── ...
│   └── ...
├── tool/
│   ├── ai_proxy.dart                      (Original OpenAI proxy)
│   ├── ai_proxy_enhanced.dart             (New - with YOLOv8 support)
│   └── ...
├── models/
│   ├── best.pt                            (Model weights)
│   ├── args.yaml                          (Configuration)
│   └── results.csv                        (Metrics)
└── pubspec.yaml
```

## Support & Resources

- **YOLOv8 Docs**: https://docs.ultralytics.com/
- **Roboflow Docs**: https://roboflow.com/
- **Flutter ML Integration**: https://flutter.dev/docs/packages-and-plugins/using-packages
- **Dart HTTP**: https://pub.dev/packages/http

---

**Model Ready** ✓ Your YOLOv8 fruit detection model is configured and ready to deploy!
