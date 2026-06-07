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
- ESP32-CAM integration for camera-based sensor input
- PDF/report export support

## Tech Stack

- Flutter and Dart
- Firebase Auth, Realtime Database, App Check, and Firebase AI
- SQLite through `sqflite`
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

## Roadmap

See [ROADMAP.md](ROADMAP.md) for needed fixes, planned functions, and future
improvements.

## Firebase

The Flutter client config files are included so the app can connect to the
configured Firebase project:

- `lib/firebase_options.dart`
- `android/app/google-services.json`

Keep Firebase service account keys, App Check debug tokens, database export
secrets, and private admin SDK files out of GitHub. Also make sure Firebase
rules only allow each signed-in user to access the data they own.

## Gradient Boosting Forecast Server

FruityVens can use a Python sales-forecasting server before falling back to
Firebase AI. The server trains a `GradientBoostingRegressor` from transaction
history and returns predicted restock demand for the next 7 days.

Install the forecast-only Python dependencies from the project root. This avoids
downloading the larger YOLO/Torch camera stack:

```sh
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-forecast.txt
```

Start the forecast server:

```sh
uvicorn tool.forecast_server:app --host 0.0.0.0 --port 8787
```

When running on a USB-connected Android phone, forward the phone's localhost to
the workstation server:

```sh
adb reverse tcp:8787 tcp:8787
```

For a production-like Firebase setup, download a Firebase Admin SDK service
account JSON, keep it local, and start the server with:

```sh
FIREBASE_SERVICE_ACCOUNT=firebase-service-account.json \
uvicorn tool.forecast_server:app --host 0.0.0.0 --port 8787
```

The Flutter app sends the current Firebase ID token when available. The server
can verify that token and read:

```text
users/<uid>/transactions
```

If the service account is not configured, the app still sends its local
transaction snapshot so local development forecasting works.

## AI Automation Proxy

Keep the OpenAI API key in `API-KEY.txt`. Do not add that file to Flutter
assets or app source.

The older OpenAI proxy is still available from the project root:

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
