import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

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
    required String ownerPassword,
    required String workerEmail,
    required String password,
  }) async {
    final auth.FirebaseAuth? firebaseAuth = _auth;
    final FirebaseDatabase? database = _database;
    if (!isAvailable ||
        firebaseAuth == null ||
        database == null ||
        ownerUid.trim().isEmpty) {
      throw const FirebaseSyncException(
        'Firebase is required to create the shared worker login.',
      );
    }

    try {
      final auth.UserCredential credential = await firebaseAuth
          .createUserWithEmailAndPassword(
            email: workerEmail,
            password: password,
          );
      final auth.User? user = credential.user;
      if (user == null) {
        throw const FirebaseSyncException(
          'Firebase worker account was not created.',
        );
      }
      await user.updateDisplayName('Worker');
      final String workerUid = user.uid;

      await saveUserProfile(
        uid: workerUid,
        name: 'Worker',
        email: workerEmail,
        role: AccountRole.worker,
        ownerUid: ownerUid,
      );

      final auth.UserCredential ownerCredential = await firebaseAuth
          .signInWithEmailAndPassword(
            email: ownerEmail,
            password: ownerPassword,
          );
      final auth.User? restoredOwner = ownerCredential.user;
      if (restoredOwner == null || restoredOwner.uid != ownerUid) {
        throw const FirebaseSyncException(
          'Owner Firebase session could not be restored after creating Worker.',
        );
      }

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
    } on auth.FirebaseAuthException catch (error) {
      await _restoreOwnerSessionBestEffort(
        firebaseAuth,
        ownerUid: ownerUid,
        ownerEmail: ownerEmail,
        ownerPassword: ownerPassword,
      );
      throw FirebaseSyncException(_authMessage(error));
    } on FirebaseException catch (error) {
      await _restoreOwnerSessionBestEffort(
        firebaseAuth,
        ownerUid: ownerUid,
        ownerEmail: ownerEmail,
        ownerPassword: ownerPassword,
      );
      throw FirebaseSyncException(_firebaseMessage(error));
    } catch (error) {
      await _restoreOwnerSessionBestEffort(
        firebaseAuth,
        ownerUid: ownerUid,
        ownerEmail: ownerEmail,
        ownerPassword: ownerPassword,
      );
      throw FirebaseSyncException('Worker login could not be created: $error');
    }
  }

  Future<void> _restoreOwnerSessionBestEffort(
    auth.FirebaseAuth firebaseAuth, {
    required String ownerUid,
    required String ownerEmail,
    required String ownerPassword,
  }) async {
    if (firebaseAuth.currentUser?.uid == ownerUid) {
      return;
    }
    try {
      final auth.UserCredential credential = await firebaseAuth
          .signInWithEmailAndPassword(
            email: ownerEmail,
            password: ownerPassword,
          );
      if (credential.user?.uid == ownerUid) {
        return;
      }
    } catch (_) {
      // Fall through to sign out so the app never keeps a half-created
      // Worker as the active Firebase user after an Owner operation fails.
    }
    try {
      await firebaseAuth.signOut();
    } catch (_) {
      // Best-effort cleanup only.
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
