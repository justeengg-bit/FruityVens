import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  const DefaultFirebaseOptions._();

  static const String _databaseURL = String.fromEnvironment(
    'FRUITYVENS_DATABASE_URL',
    defaultValue:
        'https://fruityv-default-rtdb.asia-southeast1.firebasedatabase.app',
  );

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions have not been configured for web.',
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'DefaultFirebaseOptions are only configured for Android.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBnQ7Gp-QQuuZgX6zMiDCGlCDAe_pEwUEs',
    databaseURL: _databaseURL,
    projectId: 'fruityv',
    storageBucket: 'fruityv.firebasestorage.app',
    messagingSenderId: '877154452010',
    appId: '1:877154452010:android:715d1884b3b8d0c9573953',
  );
}
