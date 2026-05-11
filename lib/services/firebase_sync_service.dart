import 'package:firebase_auth/firebase_auth.dart' as auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

class FirebaseAccount {
  const FirebaseAccount({required this.uid, required this.email, this.name});

  final String uid;
  final String email;
  final String? name;
}

class FirebaseSyncService {
  const FirebaseSyncService();

  bool get isAvailable => Firebase.apps.isNotEmpty;

  auth.FirebaseAuth? get _auth {
    if (!isAvailable) {
      return null;
    }
    return auth.FirebaseAuth.instanceFor(app: Firebase.app());
  }

  FirebaseDatabase? get _database {
    if (!isAvailable) {
      return null;
    }
    final FirebaseApp app = Firebase.app();
    return FirebaseDatabase.instanceFor(
      app: app,
      databaseURL: app.options.databaseURL,
    );
  }

  String? get currentUserId => _auth?.currentUser?.uid;

  Future<FirebaseAccount?> createAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    final auth.FirebaseAuth? firebaseAuth = _auth;
    if (firebaseAuth == null) {
      return null;
    }

    try {
      final auth.UserCredential credential = await firebaseAuth
          .createUserWithEmailAndPassword(email: email, password: password);
      final auth.User? user = credential.user;
      if (user == null) {
        throw const FirebaseSyncException('Firebase account was not created.');
      }
      await user.updateDisplayName(name);
      await _saveUserProfileBestEffort(uid: user.uid, name: name, email: email);
      return FirebaseAccount(uid: user.uid, email: email, name: name);
    } on auth.FirebaseAuthException catch (error) {
      throw FirebaseSyncException(_authMessage(error));
    } on FirebaseException catch (error) {
      throw FirebaseSyncException(_firebaseMessage(error));
    }
  }

  Future<FirebaseAccount?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final auth.FirebaseAuth? firebaseAuth = _auth;
    if (firebaseAuth == null) {
      return null;
    }

    try {
      final auth.UserCredential credential = await firebaseAuth
          .signInWithEmailAndPassword(email: email, password: password);
      final auth.User? user = credential.user;
      if (user == null) {
        throw const FirebaseSyncException('Firebase sign-in did not complete.');
      }
      await _saveUserProfileBestEffort(
        uid: user.uid,
        name: user.displayName ?? email.split('@').first,
        email: email,
      );
      return FirebaseAccount(
        uid: user.uid,
        email: email,
        name: user.displayName,
      );
    } on auth.FirebaseAuthException catch (error) {
      throw FirebaseSyncException(_authMessage(error));
    } on FirebaseException catch (error) {
      throw FirebaseSyncException(_firebaseMessage(error));
    }
  }

  Future<FirebaseAccount?> signInWithGoogleIdToken({
    required String idToken,
    required String fallbackEmail,
    String? fallbackName,
  }) async {
    final auth.FirebaseAuth? firebaseAuth = _auth;
    if (firebaseAuth == null) {
      return null;
    }

    try {
      final auth.OAuthCredential credential =
          auth.GoogleAuthProvider.credential(idToken: idToken);
      final auth.UserCredential userCredential = await firebaseAuth
          .signInWithCredential(credential);
      final auth.User? user = userCredential.user;
      if (user == null) {
        throw const FirebaseSyncException('Google sign-in did not complete.');
      }
      final String email = user.email ?? fallbackEmail;
      final String name =
          user.displayName ?? fallbackName ?? email.split('@').first;
      await _saveUserProfileBestEffort(uid: user.uid, name: name, email: email);
      return FirebaseAccount(uid: user.uid, email: email, name: name);
    } on auth.FirebaseAuthException catch (error) {
      throw FirebaseSyncException(_authMessage(error));
    } on FirebaseException catch (error) {
      throw FirebaseSyncException(_firebaseMessage(error));
    }
  }

  Future<void> sendPasswordReset(String email) async {
    final auth.FirebaseAuth? firebaseAuth = _auth;
    if (firebaseAuth == null) {
      return;
    }

    try {
      await firebaseAuth.sendPasswordResetEmail(email: email);
    } on auth.FirebaseAuthException catch (error) {
      throw FirebaseSyncException(_authMessage(error));
    }
  }

  Future<void> signOut() async {
    await _auth?.signOut();
  }

  Future<void> saveUserProfile({
    required String uid,
    required String name,
    required String email,
  }) async {
    final FirebaseDatabase? database = _database;
    if (database == null) {
      return;
    }

    await database.ref('users/$uid/profile').update(<String, Object?>{
      'name': name,
      'email': email,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _saveUserProfileBestEffort({
    required String uid,
    required String name,
    required String email,
  }) async {
    try {
      await saveUserProfile(uid: uid, name: name, email: email);
    } on FirebaseException catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
    }
  }

  Future<void> syncInventory(List<Map<String, Object?>> inventory) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return;
    }

    final Map<String, Object?> updates = <String, Object?>{};
    for (final Map<String, Object?> fruit in inventory) {
      final String? name = fruit['name'] as String?;
      if (name == null || name.isEmpty) {
        continue;
      }
      updates['users/$uid/inventory/${_databaseKey(name)}'] = <String, Object?>{
        ...fruit,
        'updatedAt': ServerValue.timestamp,
      };
    }
    if (updates.isEmpty) {
      return;
    }
    await database.ref().update(updates);
  }

  Future<void> syncTransactions(List<Map<String, Object?>> transactions) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null || transactions.isEmpty) {
      return;
    }

    final Map<String, Object?> updates = <String, Object?>{};
    for (final Map<String, Object?> transaction in transactions) {
      final String? cloudId = transaction['cloudId'] as String?;
      if (cloudId == null || cloudId.isEmpty) {
        continue;
      }
      updates['users/$uid/transactions/${_databaseKey(cloudId)}'] =
          <String, Object?>{...transaction, 'updatedAt': ServerValue.timestamp};
    }
    if (updates.isEmpty) {
      return;
    }
    await database.ref().update(updates);
  }

  Future<List<Map<String, Object?>>> fetchTransactions() async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const <Map<String, Object?>>[];
    }

    final DataSnapshot snapshot = await database
        .ref('users/$uid/transactions')
        .get();
    final Object? value = snapshot.value;
    if (value is! Map) {
      return const <Map<String, Object?>>[];
    }

    final List<Map<String, Object?>> transactions = <Map<String, Object?>>[];
    for (final Object? item in value.values) {
      if (item is! Map) {
        continue;
      }
      transactions.add(Map<String, Object?>.from(item));
    }
    return transactions;
  }

  Future<List<Map<String, Object?>>> fetchInventory() async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const <Map<String, Object?>>[];
    }

    final DataSnapshot snapshot = await database
        .ref('users/$uid/inventory')
        .get();
    final Object? value = snapshot.value;
    if (value is! Map) {
      return const <Map<String, Object?>>[];
    }

    final List<Map<String, Object?>> inventory = <Map<String, Object?>>[];
    for (final Object? item in value.values) {
      if (item is! Map) {
        continue;
      }
      inventory.add(Map<String, Object?>.from(item));
    }
    return inventory;
  }

  Future<void> syncFruit(Map<String, Object?> fruit) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    final String? name = fruit['name'] as String?;
    if (uid == null || database == null || name == null || name.isEmpty) {
      return;
    }

    await database.ref('users/$uid/inventory/${_databaseKey(name)}').set(
      <String, Object?>{...fruit, 'updatedAt': ServerValue.timestamp},
    );
  }

  Future<void> removeFruit(String fruitName) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return;
    }

    await database.ref('users/$uid/inventory/${_databaseKey(fruitName)}').set(
      <String, Object?>{
        'name': fruitName,
        'managed': false,
        'updatedAt': ServerValue.timestamp,
      },
    );
  }

  Future<void> registerDevice({
    required String deviceId,
    required String deviceName,
    required bool phoneLinked,
    String? modelMode,
    String? modelId,
  }) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null || deviceId.isEmpty) {
      return;
    }

    await database
        .ref('users/$uid/devices/${_databaseKey(deviceId)}')
        .update(<String, Object?>{
          'deviceId': deviceId,
          'deviceName': deviceName,
          'phoneLinked': phoneLinked,
          if (modelMode != null) 'fruitModelMode': modelMode,
          if (modelId != null) 'fruitModelId': modelId,
          'active': true,
          'lastActiveAt': ServerValue.timestamp,
        });
  }

  Future<void> markDeviceSignedOut(String deviceId) async {
    final String? uid = currentUserId;
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null || deviceId.isEmpty) {
      return;
    }
    await database.ref('users/$uid/devices/${_databaseKey(deviceId)}').update(
      <String, Object?>{'active': false, 'signedOutAt': ServerValue.timestamp},
    );
  }

  String _databaseKey(String value) {
    return value.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
  }

  String _authMessage(auth.FirebaseAuthException error) {
    switch (error.code) {
      case 'email-already-in-use':
        return 'Account already exists. Sign in instead.';
      case 'invalid-email':
        return 'Use a valid email address.';
      case 'user-not-found':
      case 'invalid-credential':
        return 'Account not found or password is incorrect.';
      case 'wrong-password':
        return 'Incorrect password. Try again or reset it.';
      case 'weak-password':
        return 'Create a stronger password.';
      case 'network-request-failed':
        return 'Firebase needs internet to sync this account.';
      case 'operation-not-allowed':
        return 'Enable Email/Password sign-in in Firebase Authentication.';
      default:
        return error.message ?? 'Firebase authentication failed.';
    }
  }

  String _firebaseMessage(FirebaseException error) {
    if (_isPermissionDenied(error)) {
      return 'Realtime Database rules blocked cloud sync. Allow users/{uid} reads and writes in Firebase Rules.';
    }
    return error.message ?? 'Firebase sync failed.';
  }

  bool _isPermissionDenied(FirebaseException error) {
    final String code = error.code.toLowerCase();
    final String message = (error.message ?? '').toLowerCase();
    return code == 'permission-denied' ||
        message.contains('permission denied') ||
        message.contains('permission_denied');
  }
}

class FirebaseSyncException implements Exception {
  const FirebaseSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}
