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

### Render Hosting

Render can host the FastAPI/scikit-learn forecast server so the app can
forecast without a local terminal server. Free Render web services spin down
after inactivity, so the first forecast after a quiet period can take about a
minute to wake up.

Create a new Render Web Service from this repository and use these settings:

```text
Runtime: Python 3
Build command: pip install -r requirements-render.txt
Start command: uvicorn tool.forecast_server:app --host 0.0.0.0 --port $PORT
```

Use the free instance type for testing. Keep these environment variables unset
unless you intentionally configure Firebase Admin on the server:

```text
FRUITYVENS_REQUIRE_FIREBASE_AUTH
FRUITYVENS_VERIFY_FIREBASE_AUTH
FIREBASE_SERVICE_ACCOUNT
```

With those unset, the server forecasts from the transaction payload sent by the
Flutter app. After Render deploys, check:

```text
https://YOUR-RENDER-SERVICE.onrender.com/health
```

Build the Flutter app with the Render URL:

```sh
flutter build apk --debug \
  --dart-define=FRUITYVENS_AI_BASE_URL=https://YOUR-RENDER-SERVICE.onrender.com
```

### PythonAnywhere Hosting

PythonAnywhere can host a lightweight forecast server so the app can forecast
without a local terminal server. The free account has limited disk and
restricted outbound internet, so this setup uses a small Flask server and the
transaction payload sent by the Flutter app instead of the heavier
scikit-learn/Firebase Admin stack.

In a PythonAnywhere Bash console:

```sh
mkdir -p FruityVens
tar -xzf fruityvens-pythonanywhere.tar.gz -C FruityVens
cd FruityVens
mkvirtualenv fruityvens-forecast --python=python3.10
pip install -r requirements-pythonanywhere.txt
```

Create a manual web app from the PythonAnywhere Web tab:

```text
Add a new web app -> Manual configuration -> Python 3.10
```

Set the virtualenv to:

```text
/home/YOURUSERNAME/.virtualenvs/fruityvens-forecast
```

Edit the WSGI file and replace its contents with:

```py
import sys

project_home = "/home/YOURUSERNAME/FruityVens"
if project_home not in sys.path:
    sys.path.insert(0, project_home)

from tool.forecast_server_pythonanywhere import app as application
```

Reload the web app from the Web tab.

Check the server:

```text
https://YOURUSERNAME.pythonanywhere.com/health
```

Build the Flutter app with the PythonAnywhere URL:

```sh
flutter build apk --debug \
  --dart-define=FRUITYVENS_AI_BASE_URL=https://YOURUSERNAME.pythonanywhere.com
```

When the server code changes, reload it from PythonAnywhere:

```text
Web tab -> Reload
```

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
