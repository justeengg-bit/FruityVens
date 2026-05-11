import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  const DefaultFirebaseOptions._();

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA5wrE0xCFHUb2VZ45hc7c5zhV88w1xiwY',
    authDomain: 'al-sapp.firebaseapp.com',
    databaseURL:
        'https://al-sapp-default-rtdb.asia-southeast1.firebasedatabase.app',
    projectId: 'al-sapp',
    storageBucket: 'al-sapp.firebasestorage.app',
    messagingSenderId: '916363531369',
    appId: '1:916363531369:web:50c8df85ca69ff728d3ef8',
    measurementId: 'G-118FK1Q1N3',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBmNUxdKcb6xAvben2wPo1wwiMGaAMYAVs',
    databaseURL:
        'https://al-sapp-default-rtdb.asia-southeast1.firebasedatabase.app',
    projectId: 'al-sapp',
    storageBucket: 'al-sapp.firebasestorage.app',
    messagingSenderId: '916363531369',
    appId: '1:916363531369:android:fe369998784cc1c68d3ef8',
  );
}
