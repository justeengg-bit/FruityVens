# FruityVens

FruityVens is a Flutter IoT app for automated fruit weighing, inventory
tracking, Firebase-backed account sync, AI-assisted fruit detection, and sales
forecasting. It is designed for a smart fruit vending workflow where local
device data, camera input, and cloud sync work together for day-to-day vendor
operations.

## Features

- Fruit inventory, pricing, and transaction management
- Sales analytics, top-fruit insights, and revenue summaries
- Firebase authentication, Google sign-in, and cloud database sync
- Offline local storage with SQLite
- AI-assisted forecasting and automation support
- ONNX fruit detection model assets for offline scanning
- ESP32-CAM integration for camera-based sensor input
- PDF/report export support

## Tech Stack

- Flutter and Dart
- Firebase Auth, Realtime Database, App Check, and Firebase AI
- SQLite through `sqflite`
- ONNX Runtime for local model inference
- ESP32-CAM firmware support
- Optional local OpenAI proxy tooling for AI automation

## Run

```sh
flutter pub get
flutter run
```

## Build Android APK

```sh
flutter build apk --debug
```

For a signed release build, create your own local Android signing files first.
Do not commit release keystores or signing passwords.

## Contributing

Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md) for the branch,
testing, pull request, and secret-handling checklist.

## Firebase

The Flutter client config files are included so the app can connect to the
configured Firebase project:

- `lib/firebase_options.dart`
- `android/app/google-services.json`

Keep Firebase service account keys, App Check debug tokens, database export
secrets, and private admin SDK files out of GitHub. Also make sure Firebase
rules only allow each signed-in user to access the data they own.

## AI Automation Proxy

Keep the OpenAI API key in `API-KEY.txt`. Do not add that file to Flutter
assets or app source.

Start the local AI proxy from the project root:

```sh
dart run tool/ai_proxy.dart
```

The app currently points to `http://192.168.1.9:8787`. If the workstation IP
changes, rebuild with:

```sh
flutter build apk --debug --dart-define=FRUITYVENS_AI_BASE_URL=http://YOUR_PC_IP:8787
```

## ESP32-CAM Eye

The app can connect to the ESP32-CAM access point as a backend sensor source:

- SSID: `FruityVens`
- Password configured by the device: `1234`
- Default camera host: `192.168.4.1`
- Default stream endpoint: `http://192.168.4.1:81/stream`

The stream is not rendered in the Flutter UI. It is passed as backend metadata
for YOLOv8-style processing. If the access point uses WPA/WPA2, use an
8-character or longer password in the ESP32 firmware because `1234` is too
short for normal WPA.

## Local Files Not Committed

These files stay local and should not be pushed to GitHub:

- `API-KEY.txt`
- `API-KEY-DATA.txt`
- `android/local.properties`
- `android/key.properties`
- `android/app/*.jks`
- `android/app/*.keystore`
- `run_logs/`
- `build/`
- `.dart_tool/`
