import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:wifi_iot/wifi_iot.dart';

class CameraEyeStatus {
  const CameraEyeStatus({
    required this.connectedToAp,
    required this.streamReachable,
    required this.currentSsid,
    required this.streamUrl,
    required this.snapshotUrl,
    required this.message,
    this.probeUrl,
    this.wifiForced = false,
    this.supported = true,
  });

  const CameraEyeStatus.idle()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Not connected',
      streamUrl = CameraEyeService.streamUrl,
      snapshotUrl = CameraEyeService.snapshotUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Camera eye is ready to connect.';

  const CameraEyeStatus.connecting()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Connecting',
      streamUrl = CameraEyeService.streamUrl,
      snapshotUrl = CameraEyeService.snapshotUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Connecting to the FruityVens camera preview...';

  const CameraEyeStatus.checking()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Checking',
      streamUrl = CameraEyeService.streamUrl,
      snapshotUrl = CameraEyeService.snapshotUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Checking camera eye connection...';

  const CameraEyeStatus.unsupported()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Unsupported',
      streamUrl = CameraEyeService.streamUrl,
      snapshotUrl = CameraEyeService.snapshotUrl,
      probeUrl = null,
      wifiForced = false,
      supported = false,
      message = 'Camera preview connection is available on Android phones.';

  const CameraEyeStatus.error(String errorMessage)
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Error',
      streamUrl = CameraEyeService.streamUrl,
      snapshotUrl = CameraEyeService.snapshotUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = errorMessage;

  final bool connectedToAp;
  final bool streamReachable;
  final String currentSsid;
  final String streamUrl;
  final String snapshotUrl;
  final String? probeUrl;
  final bool wifiForced;
  final bool supported;
  final String message;

  bool get ready => connectedToAp && streamReachable;
}

class CameraEyeService {
  const CameraEyeService();

  static const String ssid = 'Parafiber_F0C0 2.4G';
  static const String host = '192.168.1.34';
  static const String baseUrl = 'http://$host';
  static const String snapshotUrl = '$baseUrl/snapshot.jpg';
  static const String streamUrl = snapshotUrl;
  static const String previewStartUrl = '$baseUrl/preview/start';
  static const String previewStopUrl = '$baseUrl/preview/stop';

  static final List<Uri> _probeUris = <Uri>[
    Uri.parse('$baseUrl/status'),
    Uri.parse(snapshotUrl),
    Uri.parse(baseUrl),
  ];

  Future<CameraEyeStatus> connect() async {
    try {
      if (Platform.isAndroid && !await WiFiForIoTPlugin.isEnabled()) {
        await WiFiForIoTPlugin.setEnabled(true, shouldOpenSettings: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return status(
        connectedMessage: 'Connected to ESP32-CAM preview at $baseUrl.',
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(
        error.message ?? 'Camera preview connection failed.',
      );
    } catch (error) {
      throw CameraEyeException('Camera preview connection failed: $error');
    }
  }

  Future<CameraEyeStatus> status({String? connectedMessage}) async {
    try {
      final String currentSsid = await _currentWifiName();
      final String? reachableProbe = await _firstReachableProbe();

      final bool streamReachable = reachableProbe != null;
      final String statusMessage = streamReachable
          ? connectedMessage ??
                _statusMessage(
                  streamReachable: streamReachable,
                  currentSsid: currentSsid,
                )
          : _statusMessage(streamReachable: false, currentSsid: currentSsid);
      return CameraEyeStatus(
        connectedToAp: streamReachable,
        streamReachable: streamReachable,
        currentSsid: currentSsid,
        streamUrl: streamUrl,
        snapshotUrl: snapshotUrl,
        probeUrl: reachableProbe,
        wifiForced: false,
        message: statusMessage,
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(
        error.message ?? 'Camera preview status check failed.',
      );
    } catch (error) {
      throw CameraEyeException('Camera preview status check failed: $error');
    }
  }

  Future<CameraEyeStatus> releaseRoute() async {
    try {
      if (Platform.isAndroid) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }
      return status(
        connectedMessage:
            'Camera route released. Internet traffic can use the normal network.',
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(
        error.message ?? 'Could not release the camera AP route.',
      );
    } catch (error) {
      throw CameraEyeException('Could not release the camera AP route: $error');
    }
  }

  Future<void> startPreview() async {
    await _sendPreviewCommand(Uri.parse(previewStartUrl), 'start preview');
  }

  Future<void> stopPreview() async {
    await _sendPreviewCommand(Uri.parse(previewStopUrl), 'stop preview');
  }

  Future<Uint8List> fetchSnapshot() async {
    final Uri uri = Uri.parse(
      '$snapshotUrl?ts=${DateTime.now().millisecondsSinceEpoch}',
    );
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      request.headers.set(HttpHeaders.acceptHeader, 'image/jpeg');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CameraEyeException(
          'Camera snapshot HTTP ${response.statusCode}.',
        );
      }

      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on CameraEyeException {
      rethrow;
    } on TimeoutException {
      throw const CameraEyeException('Camera snapshot timed out.');
    } on SocketException {
      throw const CameraEyeException('Camera snapshot is not reachable.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendPreviewCommand(Uri uri, String action) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      await response.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CameraEyeException(
          'Could not $action: HTTP ${response.statusCode}.',
        );
      }
    } on CameraEyeException {
      rethrow;
    } on TimeoutException {
      throw CameraEyeException('Could not $action: request timed out.');
    } on SocketException {
      throw CameraEyeException('Could not $action: camera is not reachable.');
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _firstReachableProbe() async {
    for (final Uri uri in _probeUris) {
      if (await _canReach(uri)) {
        return uri.toString();
      }
    }
    return null;
  }

  Future<bool> _canReach(Uri uri) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      return response.statusCode >= 200 && response.statusCode < 500;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  String _statusMessage({
    required bool streamReachable,
    required String currentSsid,
  }) {
    if (streamReachable) {
      return 'Camera eye is reachable at $baseUrl. Tap Preview to see the ESP32-CAM view.';
    }
    return 'ESP32-CAM is not reachable at $baseUrl. Current Wi-Fi: $currentSsid.';
  }

  Future<String> _currentWifiName() async {
    if (!Platform.isAndroid) {
      return 'Network';
    }

    try {
      final bool connected = await WiFiForIoTPlugin.isConnected();
      return _cleanSsid(await WiFiForIoTPlugin.getSSID()) ??
          (connected ? 'Unknown Wi-Fi' : 'No Wi-Fi');
    } on PlatformException {
      return 'Unknown Wi-Fi';
    }
  }

  String? _cleanSsid(String? value) {
    final String? cleaned = value?.replaceAll('"', '').trim();
    if (cleaned == null || cleaned.isEmpty || cleaned == '<unknown ssid>') {
      return null;
    }
    return cleaned;
  }
}

class CameraEyeException implements Exception {
  const CameraEyeException(this.message);

  final String message;

  @override
  String toString() => message;
}
