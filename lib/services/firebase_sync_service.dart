import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' as auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

import '../data/app_database.dart';

class FirebaseAccount {
  const FirebaseAccount({
    required this.uid,
    required this.email,
    this.name,
    this.role = AccountRole.owner,
    this.ownerUid,
  });

  final String uid;
  final String email;
  final String? name;
  final AccountRole role;
  final String? ownerUid;
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
    final String? databaseURL = app.options.databaseURL;
    if (databaseURL == null || databaseURL.isEmpty) {
      return null;
    }
    return FirebaseDatabase.instanceFor(app: app, databaseURL: databaseURL);
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
      await _saveUserProfileBestEffort(
        uid: user.uid,
        name: name,
        email: email,
        role: AccountRole.owner,
      );
      return FirebaseAccount(
        uid: user.uid,
        email: email,
        name: name,
        role: AccountRole.owner,
      );
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
      final Map<String, Object?> workerLink = await _workerLinkForUid(user.uid);
      final Map<String, Object?> profile = await _profileForUid(user.uid);
      final String? ownerUid =
          workerLink['ownerUid'] as String? ?? profile['ownerUid'] as String?;
      final AccountRole profileRole = AccountRole.parse(profile['role']);
      final AccountRole role = ownerUid == null || ownerUid.isEmpty
          ? profileRole
          : AccountRole.worker;
      final String displayName = role == AccountRole.worker
          ? 'Worker'
          : profile['name'] as String? ??
                user.displayName ??
                email.split('@').first;
      await _saveUserProfileBestEffort(
        uid: user.uid,
        name: displayName,
        email: email,
        role: role,
        ownerUid: ownerUid,
      );
      return FirebaseAccount(
        uid: user.uid,
        email: email,
        name: displayName,
        role: role,
        ownerUid: ownerUid,
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
      await _saveUserProfileBestEffort(
        uid: user.uid,
        name: name,
        email: email,
        role: AccountRole.owner,
      );
      return FirebaseAccount(
        uid: user.uid,
        email: email,
        name: name,
        role: AccountRole.owner,
      );
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
    AccountRole role = AccountRole.owner,
    String? ownerUid,
  }) async {
    final FirebaseDatabase? database = _database;
    if (database == null) {
      return;
    }

    await database.ref('users/$uid/profile').update(<String, Object?>{
      'name': name,
      'email': email,
      'role': role.name,
      if (ownerUid != null && ownerUid.isNotEmpty) 'ownerUid': ownerUid,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _saveUserProfileBestEffort({
    required String uid,
    required String name,
    required String email,
    AccountRole role = AccountRole.owner,
    String? ownerUid,
  }) async {
    try {
      await saveUserProfile(
        uid: uid,
        name: name,
        email: email,
        role: role,
        ownerUid: ownerUid,
      );
    } on FirebaseException catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
    }
  }

  Future<FirebaseAccount> createWorkerAccount({
    required String ownerUid,
    required String ownerEmail,
    required String workerEmail,
    required String password,
  }) async {
    final FirebaseDatabase? database = _database;
    if (!isAvailable || database == null || ownerUid.trim().isEmpty) {
      throw const FirebaseSyncException(
        'Firebase is required to create the shared worker login.',
      );
    }
    final String apiKey = Firebase.app().options.apiKey;
    if (apiKey.isEmpty) {
      throw const FirebaseSyncException(
        'Firebase Auth API key is missing from this app.',
      );
    }

    try {
      final Map<String, Object?> signup = await _createAuthUserWithRest(
        apiKey: apiKey,
        email: workerEmail,
        password: password,
      );
      final String? workerUid = signup['localId'] as String?;
      final String? workerIdToken = signup['idToken'] as String?;
      if (workerUid == null ||
          workerUid.isEmpty ||
          workerIdToken == null ||
          workerIdToken.isEmpty) {
        throw const FirebaseSyncException(
          'Firebase worker account was not created.',
        );
      }

      await _saveWorkerProfileWithRest(
        uid: workerUid,
        email: workerEmail,
        ownerUid: ownerUid,
        ownerEmail: ownerEmail,
        idToken: workerIdToken,
      );

      final Map<String, Object?> ownerWorkerProfile = <String, Object?>{
        'uid': workerUid,
        'email': workerEmail,
        'name': 'Worker',
        'role': AccountRole.worker.name,
        'ownerUid': ownerUid,
        'ownerEmail': ownerEmail,
        'active': true,
        'updatedAt': ServerValue.timestamp,
      };

      await database
          .ref('users/$ownerUid/workerAccount')
          .update(ownerWorkerProfile);
      try {
        await database
            .ref('workerLinks/${_databaseKey(workerUid)}')
            .update(<String, Object?>{
              'workerUid': workerUid,
              'workerEmail': workerEmail,
              'ownerUid': ownerUid,
              'ownerEmail': ownerEmail,
              'active': true,
              'updatedAt': ServerValue.timestamp,
            });
      } on FirebaseException catch (error) {
        if (!_isPermissionDenied(error)) {
          rethrow;
        }
      }

      return FirebaseAccount(
        uid: workerUid,
        email: workerEmail,
        name: 'Worker',
        role: AccountRole.worker,
        ownerUid: ownerUid,
      );
    } on FirebaseException catch (error) {
      throw FirebaseSyncException(_firebaseMessage(error));
    }
  }

  Future<Map<String, Object?>> _createAuthUserWithRest({
    required String apiKey,
    required String email,
    required String password,
  }) async {
    final Uri uri = Uri.https(
      'identitytoolkit.googleapis.com',
      '/v1/accounts:signUp',
      <String, String>{'key': apiKey},
    );
    final http.Response response = await http
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'email': email,
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final Object? decoded = jsonDecode(response.body);
    final Map<String, Object?> body = decoded is Map
        ? Map<String, Object?>.from(decoded)
        : <String, Object?>{};
    if (response.statusCode >= 400) {
      final Object? error = body['error'];
      final String code = error is Map
          ? (error['message'] ?? '').toString()
          : '';
      throw FirebaseSyncException(_identityToolkitMessage(code));
    }
    return body;
  }

  Future<void> _saveWorkerProfileWithRest({
    required String uid,
    required String email,
    required String ownerUid,
    required String ownerEmail,
    required String idToken,
  }) async {
    final String? databaseURL = Firebase.app().options.databaseURL;
    if (databaseURL == null || databaseURL.isEmpty) {
      return;
    }
    final String baseUrl = databaseURL.endsWith('/')
        ? databaseURL.substring(0, databaseURL.length - 1)
        : databaseURL;
    final Uri uri = Uri.parse(
      '$baseUrl/users/$uid/profile.json',
    ).replace(queryParameters: <String, String>{'auth': idToken});
    final http.Response response = await http
        .patch(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'uid': uid,
            'email': email,
            'name': 'Worker',
            'role': AccountRole.worker.name,
            'ownerUid': ownerUid,
            'ownerEmail': ownerEmail,
            'active': true,
            'updatedAt': DateTime.now().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode >= 400) {
      throw const FirebaseSyncException(
        'Realtime Database rules blocked the Worker profile link.',
      );
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

  Future<List<Map<String, Object?>>> fetchTransactions({
    String? ownerUid,
  }) async {
    final String? uid = _dataUserId(ownerUid);
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const <Map<String, Object?>>[];
    }

    final DataSnapshot snapshot = await database
        .ref('users/$uid/transactions')
        .get();
    return _mapsFromSnapshot(snapshot);
  }

  Future<List<Map<String, Object?>>> fetchInventory({String? ownerUid}) async {
    final String? uid = _dataUserId(ownerUid);
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const <Map<String, Object?>>[];
    }

    final DataSnapshot snapshot = await database
        .ref('users/$uid/inventory')
        .get();
    return _mapsFromSnapshot(snapshot);
  }

  Stream<List<Map<String, Object?>>> watchTransactions({String? ownerUid}) {
    final String? uid = _dataUserId(ownerUid);
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const Stream<List<Map<String, Object?>>>.empty();
    }

    return database
        .ref('users/$uid/transactions')
        .onValue
        .map((DatabaseEvent event) => _mapsFromSnapshot(event.snapshot));
  }

  Stream<List<Map<String, Object?>>> watchInventory({String? ownerUid}) {
    final String? uid = _dataUserId(ownerUid);
    final FirebaseDatabase? database = _database;
    if (uid == null || database == null) {
      return const Stream<List<Map<String, Object?>>>.empty();
    }

    return database
        .ref('users/$uid/inventory')
        .onValue
        .map((DatabaseEvent event) => _mapsFromSnapshot(event.snapshot));
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

  Future<void> syncWorkerRequests({
    required String ownerUid,
    required List<Map<String, Object?>> requests,
  }) async {
    final FirebaseDatabase? database = _database;
    if (ownerUid.trim().isEmpty || database == null || requests.isEmpty) {
      return;
    }

    final Map<String, Object?> updates = <String, Object?>{};
    for (final Map<String, Object?> request in requests) {
      final String? requestId = request['requestId'] as String?;
      if (requestId == null || requestId.isEmpty) {
        continue;
      }
      updates['users/$ownerUid/workerRequests/${_databaseKey(requestId)}'] =
          <String, Object?>{...request, 'updatedAt': ServerValue.timestamp};
    }
    if (updates.isEmpty) {
      return;
    }
    await database.ref().update(updates);
  }

  Future<void> syncWorkerRequest({
    required String ownerUid,
    required Map<String, Object?> request,
  }) async {
    await syncWorkerRequests(
      ownerUid: ownerUid,
      requests: <Map<String, Object?>>[request],
    );
  }

  Future<List<Map<String, Object?>>> fetchWorkerRequests({
    required String ownerUid,
  }) async {
    final FirebaseDatabase? database = _database;
    if (ownerUid.trim().isEmpty || database == null) {
      return const <Map<String, Object?>>[];
    }

    final DataSnapshot snapshot = await database
        .ref('users/$ownerUid/workerRequests')
        .get();
    return _mapsFromSnapshot(snapshot);
  }

  Stream<List<Map<String, Object?>>> watchWorkerRequests({
    required String ownerUid,
  }) {
    final FirebaseDatabase? database = _database;
    if (ownerUid.trim().isEmpty || database == null) {
      return const Stream<List<Map<String, Object?>>>.empty();
    }

    return database
        .ref('users/$ownerUid/workerRequests')
        .onValue
        .map((DatabaseEvent event) => _mapsFromSnapshot(event.snapshot));
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

  Future<void> publishScalePriceUpdate({
    required String scaleDeviceId,
    required String fruitName,
    required int priceCentavos,
    String? sourceDeviceId,
  }) async {
    final FirebaseDatabase? database = _database;
    final String cleanScaleDeviceId = scaleDeviceId.trim();
    final String cleanFruitName = fruitName.trim();
    if (database == null ||
        cleanScaleDeviceId.isEmpty ||
        cleanFruitName.isEmpty ||
        priceCentavos <= 0) {
      return;
    }

    final int version = DateTime.now().millisecondsSinceEpoch;
    final Map<String, Object?> payload = <String, Object?>{
      'fruit': cleanFruitName,
      'price': priceCentavos / 100,
      'priceCentavos': priceCentavos,
      'priceUnit': 'centavos',
      'version': version,
      if (sourceDeviceId != null && sourceDeviceId.trim().isNotEmpty)
        'sourceDeviceId': sourceDeviceId.trim(),
      'updatedAt': ServerValue.timestamp,
    };
    final String scaleKey = _databaseKey(cleanScaleDeviceId);
    final String fruitKey = _databaseKey(cleanFruitName);

    await database.ref().update(<String, Object?>{
      'scalePriceUpdates/$scaleKey/latest': payload,
      'scalePriceUpdates/$scaleKey/fruits/$fruitKey': payload,
    });
  }

  Future<void> registerDevice({
    required String deviceId,
    required String deviceName,
    required bool phoneLinked,
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

  Future<Map<String, Object?>> _workerLinkForUid(String uid) async {
    final FirebaseDatabase? database = _database;
    if (database == null || uid.isEmpty) {
      return <String, Object?>{};
    }

    try {
      final DataSnapshot snapshot = await database
          .ref('workerLinks/${_databaseKey(uid)}')
          .get();
      final Object? value = snapshot.value;
      if (value is Map) {
        return Map<String, Object?>.from(value);
      }
    } on FirebaseException catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
    }
    return <String, Object?>{};
  }

  Future<Map<String, Object?>> _profileForUid(String uid) async {
    final FirebaseDatabase? database = _database;
    if (database == null || uid.isEmpty) {
      return <String, Object?>{};
    }

    try {
      final DataSnapshot snapshot = await database
          .ref('users/$uid/profile')
          .get();
      final Object? value = snapshot.value;
      if (value is Map) {
        return Map<String, Object?>.from(value);
      }
    } on FirebaseException catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
    }
    return <String, Object?>{};
  }

  String? _dataUserId(String? ownerUid) {
    final String? cleanOwnerUid = ownerUid?.trim();
    if (cleanOwnerUid != null && cleanOwnerUid.isNotEmpty) {
      return cleanOwnerUid;
    }
    return currentUserId;
  }

  String _databaseKey(String value) {
    return value.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
  }

  List<Map<String, Object?>> _mapsFromSnapshot(DataSnapshot snapshot) {
    final Object? value = snapshot.value;
    if (value is! Map) {
      return const <Map<String, Object?>>[];
    }

    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    for (final Object? item in value.values) {
      if (item is! Map) {
        continue;
      }
      items.add(Map<String, Object?>.from(item));
    }
    return items;
  }

  String _identityToolkitMessage(String code) {
    if (code.contains('EMAIL_EXISTS')) {
      return 'Worker account already exists. Use a different worker email.';
    }
    if (code.contains('INVALID_EMAIL')) {
      return 'Use a valid worker email.';
    }
    if (code.contains('WEAK_PASSWORD')) {
      return 'Create a stronger worker password.';
    }
    if (code.contains('OPERATION_NOT_ALLOWED')) {
      return 'Enable Email/Password sign-in in Firebase Authentication.';
    }
    if (code.contains('NETWORK') || code.contains('TIMEOUT')) {
      return 'Firebase needs internet to create the Worker login.';
    }
    return code.isEmpty
        ? 'Firebase Auth could not create this Worker login.'
        : 'Firebase Auth could not create this Worker login: $code';
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
      case 'internal-error':
        return 'Firebase Auth could not create this Worker login. Check internet, Email/Password sign-in, and Android Firebase setup, then try again.';
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
