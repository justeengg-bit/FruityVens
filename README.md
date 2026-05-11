# FruityVens

Flutter conversion of the original static FruityVens vendor dashboard.

## Run

```sh
flutter pub get
flutter run
```

## Build Android APK

```sh
flutter build apk --debug
```

## AI automation proxy

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

## ESP32-CAM eye

The app can connect to the ESP32-CAM access point as a backend sensor source:

- SSID: `FruityVens`
- Password configured by the device: `1234`
- Default camera host: `192.168.4.1`
- Default stream endpoint: `http://192.168.4.1:81/stream`

The stream is not rendered in the Flutter UI. It is passed as backend metadata
for YOLOv8n-style processing. If the AP uses WPA/WPA2, use an 8+ character
password in the ESP32 firmware because `1234` is too short for normal WPA.
