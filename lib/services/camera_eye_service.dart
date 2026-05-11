import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wifi_iot/wifi_iot.dart';

class CameraEyeStatus {
  const CameraEyeStatus({
    required this.connectedToAp,
    required this.streamReachable,
    required this.currentSsid,
    required this.streamUrl,
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
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Camera eye is ready to connect.';

  const CameraEyeStatus.connecting()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Connecting',
      streamUrl = CameraEyeService.streamUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Connecting to the FruityVens camera AP...';

  const CameraEyeStatus.checking()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Checking',
      streamUrl = CameraEyeService.streamUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = 'Checking camera eye connection...';

  const CameraEyeStatus.unsupported()
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Unsupported',
      streamUrl = CameraEyeService.streamUrl,
      probeUrl = null,
      wifiForced = false,
      supported = false,
      message = 'Camera AP connection is available on Android phones.';

  const CameraEyeStatus.error(String errorMessage)
    : connectedToAp = false,
      streamReachable = false,
      currentSsid = 'Error',
      streamUrl = CameraEyeService.streamUrl,
      probeUrl = null,
      wifiForced = false,
      supported = true,
      message = errorMessage;

  final bool connectedToAp;
  final bool streamReachable;
  final String currentSsid;
  final String streamUrl;
  final String? probeUrl;
  final bool wifiForced;
  final bool supported;
  final String message;

  bool get ready =>
      currentSsid == CameraEyeService.ssid && connectedToAp && streamReachable;
}

class CameraEyeService {
  const CameraEyeService();

  static const String ssid = 'FruityVens';
  static const String password = '1234';
  static const String host = '192.168.4.1';
  static const String streamUrl = 'http://192.168.4.1:81/stream';

  static final List<Uri> _probeUris = <Uri>[
    Uri.parse('http://$host:81/status'),
    Uri.parse('http://$host/status'),
    Uri.parse('http://$host/'),
    Uri.parse(streamUrl),
  ];

  Future<CameraEyeStatus> connect() async {
    if (!Platform.isAndroid) {
      return const CameraEyeStatus.unsupported();
    }

    try {
      if (!await WiFiForIoTPlugin.isEnabled()) {
        await WiFiForIoTPlugin.setEnabled(true, shouldOpenSettings: true);
      }

      final bool connected = await _connectToCameraAp();
      if (!connected) {
        return const CameraEyeStatus(
          connectedToAp: false,
          streamReachable: false,
          currentSsid: 'Not connected',
          streamUrl: streamUrl,
          message:
              'Could not join FruityVens. Check that the ESP32-CAM AP is powered on.',
        );
      }

      await WiFiForIoTPlugin.forceWifiUsage(true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return status(
        connectedMessage:
            'Connected to FruityVens. The camera stream is reserved for backend YOLOv8n.',
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(error.message ?? 'Camera AP connection failed.');
    } catch (error) {
      throw CameraEyeException('Camera AP connection failed: $error');
    }
  }

  Future<CameraEyeStatus> status({String? connectedMessage}) async {
    if (!Platform.isAndroid) {
      return const CameraEyeStatus.unsupported();
    }

    try {
      final bool connected = await WiFiForIoTPlugin.isConnected();
      final String currentSsid =
          _cleanSsid(await WiFiForIoTPlugin.getSSID()) ??
          (connected ? 'Unknown Wi-Fi' : 'No Wi-Fi');
      final bool onCameraAp = currentSsid == ssid;
      String? reachableProbe;

      if (onCameraAp) {
        await WiFiForIoTPlugin.forceWifiUsage(true);
        reachableProbe = await _firstReachableProbe();
      } else {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }

      final bool streamReachable = reachableProbe != null;
      final String statusMessage = onCameraAp
          ? connectedMessage ??
                _statusMessage(
                  onCameraAp: onCameraAp,
                  streamReachable: streamReachable,
                  currentSsid: currentSsid,
                )
          : _statusMessage(
              onCameraAp: onCameraAp,
              streamReachable: false,
              currentSsid: currentSsid,
            );
      return CameraEyeStatus(
        connectedToAp: onCameraAp,
        streamReachable: streamReachable,
        currentSsid: currentSsid,
        streamUrl: streamUrl,
        probeUrl: reachableProbe,
        wifiForced: onCameraAp,
        message: statusMessage,
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(
        error.message ?? 'Camera AP status check failed.',
      );
    } catch (error) {
      throw CameraEyeException('Camera AP status check failed: $error');
    }
  }

  Future<CameraEyeStatus> releaseRoute() async {
    if (!Platform.isAndroid) {
      return const CameraEyeStatus.unsupported();
    }

    try {
      await WiFiForIoTPlugin.forceWifiUsage(false);
      return status(
        connectedMessage:
            'Camera AP route released. Internet traffic can use the normal network.',
      );
    } on PlatformException catch (error) {
      throw CameraEyeException(
        error.message ?? 'Could not release the camera AP route.',
      );
    } catch (error) {
      throw CameraEyeException('Could not release the camera AP route: $error');
    }
  }

  Future<bool> _connectToCameraAp() async {
    if (password.length >= 8) {
      final bool wpaConnected = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        security: NetworkSecurity.WPA,
        joinOnce: false,
        withInternet: false,
        timeoutInSeconds: 24,
      );
      if (wpaConnected) {
        return true;
      }
    }

    final bool openConnected = await WiFiForIoTPlugin.connect(
      ssid,
      security: NetworkSecurity.NONE,
      joinOnce: false,
      withInternet: false,
      timeoutInSeconds: 24,
    );
    if (openConnected) {
      return true;
    }

    return WiFiForIoTPlugin.connect(
      ssid,
      password: password,
      security: NetworkSecurity.WPA,
      joinOnce: false,
      withInternet: false,
      timeoutInSeconds: 24,
    );
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
    required bool onCameraAp,
    required bool streamReachable,
    required String currentSsid,
  }) {
    if (!onCameraAp) {
      return 'Not connected to $ssid. Current Wi-Fi: $currentSsid.';
    }
    if (streamReachable) {
      return 'Camera eye is reachable for backend YOLOv8n processing.';
    }
    return 'Connected to FruityVens, but the camera endpoint is not responding yet.';
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
