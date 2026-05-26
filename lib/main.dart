import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:io' show InternetAddress, Platform, SocketException;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';

import 'data/app_database.dart';
import 'firebase_options.dart';
import 'services/ai_automation_client.dart';
import 'services/camera_eye_service.dart';
import 'services/firebase_sync_service.dart';
import 'services/fruit_detection_service.dart';
import 'services/report_export_service.dart';
import 'services/scale_log_service.dart';
import 'widgets/fruit_mark.dart';

final GlobalKey<ScaffoldMessengerState> fruityVensMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
const String _appCheckDebugToken = String.fromEnvironment(
  'FRUITYVENS_APP_CHECK_DEBUG_TOKEN',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    developer.log(
      details.toString(),
      name: 'FruityVensFlutterError',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    developer.log(
      'Uncaught platform error',
      name: 'FruityVensPlatformError',
      error: error,
      stackTrace: stack,
    );
    return false;
  };
  await _initializeFirebase();
  await _initializeAppCheck();
  runApp(const FruityVensApp());
}

Future<void> _initializeFirebase() async {
  try {
    if (Firebase.apps.isNotEmpty) {
      return;
    }
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (error, stackTrace) {
    if (error is FirebaseException &&
        error.plugin == 'core' &&
        error.code == 'duplicate-app') {
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Firebase initialization',
      ),
    );
  }
}

Future<void> _initializeAppCheck() async {
  if (Firebase.apps.isEmpty) {
    return;
  }
  try {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kReleaseMode
          ? const AndroidPlayIntegrityProvider()
          : AndroidDebugProvider(
              debugToken: _appCheckDebugToken.isEmpty
                  ? null
                  : _appCheckDebugToken,
            ),
      providerApple: const AppleDeviceCheckProvider(),
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Firebase App Check initialization',
      ),
    );
  }
}

class MyApp extends FruityVensApp {
  const MyApp({super.key});
}

class FruityVensApp extends StatelessWidget {
  const FruityVensApp({super.key, this.database});

  final AppDatabase? database;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppColors.lightThemeEnabled,
      builder: (BuildContext context, bool lightThemeEnabled, Widget? child) {
        return MaterialApp(
          title: 'FruityVens',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: fruityVensMessengerKey,
          theme: AppColors.materialTheme(lightThemeEnabled),
          home: child,
        );
      },
      child: FruityVensHome(database: database),
    );
  }
}

enum AppScreen {
  walkthrough,
  login,
  createAccount,
  forgotPassword,
  dashboard,
  inventory,
  inventoryManage,
  forecast,
  analytics,
  transactions,
}

enum AnalyticsPeriod { sevenDays, thirtyDays, month, year, allTime }

enum _TransactionHistoryAction { keep, cancel, restore, remove }

class _PhoneLinkSetup {
  const _PhoneLinkSetup({required this.pin, required this.useBiometrics});

  final String pin;
  final bool useBiometrics;
}

class FruityVensHome extends StatefulWidget {
  const FruityVensHome({super.key, this.database});

  final AppDatabase? database;

  @override
  State<FruityVensHome> createState() => _FruityVensHomeState();
}

class _FruityVensHomeState extends State<FruityVensHome> {
  static const String _walkthroughSeenKey = 'walkthrough_seen';
  static const String _rememberedEmailKey = 'remembered_account_email';
  static const String _deviceIdKey = 'linked_device_id';
  static const String _biometricAutoLoginKey = 'biometric_auto_login_enabled';
  static const String _phoneLinkEmailKey = 'phone_link_account_email';
  static const String _phoneLinkEnabledKey = 'phone_link_enabled';
  static const String _phoneLinkPinKey = 'phone_link_pin_secret';
  static const String _fruitDetectionModelKey = 'fruit_detection_model_id';
  static const String _themeModeKey = 'theme_mode';
  static const String _scaleDeviceIdKey = 'scale_device_id';
  static const String _fruitDetectionAutoMode = 'auto';
  static const String _inventoryPriceConfiguredPrefix =
      'inventory_price_configured_';
  static const String _defaultScaleDeviceId = String.fromEnvironment(
    'FRUITYVENS_SCALE_DEVICE_ID',
    defaultValue: 'fruityvens-scale-01',
  );
  static const Duration _scaleLogAutoPollInterval = Duration(seconds: 15);
  static const String _googleServerClientId = String.fromEnvironment(
    'FRUITYVENS_GOOGLE_SERVER_CLIENT_ID',
  );
  static const List<String> _internetProbeHosts = <String>[
    'firebase.googleapis.com',
    'generativelanguage.googleapis.com',
    'accounts.google.com',
    'google.com',
  ];
  static const MethodChannel _deviceProfileChannel = MethodChannel(
    'fruityvens_app/device_profile',
  );
  late final AppDatabase _database;
  late final bool _ownsDatabase;
  final AiAutomationClient _aiAutomationClient = const AiAutomationClient();
  final CameraEyeService _cameraEyeService = const CameraEyeService();
  final FirebaseSyncService _firebaseSyncService = const FirebaseSyncService();
  final ReportExportService _reportExportService = const ReportExportService();
  final ScaleLogService _scaleLogService = const ScaleLogService();
  final LocalAuthentication _localAuth = LocalAuthentication();
  Future<void>? _googleSignInInitialization;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _signupNameController = TextEditingController();
  final TextEditingController _signupEmailController = TextEditingController();
  final TextEditingController _signupPasswordController =
      TextEditingController();
  final TextEditingController _signupConfirmController =
      TextEditingController();
  final TextEditingController _resetEmailController = TextEditingController();
  final TextEditingController _newPriceController = TextEditingController();
  final TextEditingController _scaleBaseUrlController = TextEditingController();
  final Map<String, TextEditingController> _priceInputControllers =
      <String, TextEditingController>{};
  final Map<String, FocusNode> _priceInputFocusNodes = <String, FocusNode>{};

  AppScreen _screen = AppScreen.login;
  AnalyticsPeriod _period = AnalyticsPeriod.sevenDays;
  bool _showAnalyticsDetails = false;
  bool _operationsOpen = false;
  bool _rememberMe = true;
  bool _passwordVisible = false;
  bool _signupPasswordVisible = false;
  bool _signingIn = false;
  bool _googleSigningIn = false;
  bool _biometricSigningIn = false;
  bool _creatingAccount = false;
  bool _signingOut = false;
  bool _sendingReset = false;
  bool _resetSent = false;
  bool _forecastGenerating = false;
  bool _exportingReport = false;
  bool _cameraEyeBusy = false;
  bool _phoneLinkEnabled = false;
  bool _biometricAutoLoginEnabled = false;
  bool _biometricPromptOpen = false;
  bool _biometricUnlockPromptDismissed = false;
  bool _emailPasswordProviderBlocked = false;
  bool _isGuestSession = false;
  bool _cloudSyncEnabled = false;
  String? _rememberedAccountEmail;
  String? _phoneLinkAccountEmail;
  String? _cloudSyncStatus;
  String? _sessionEmail;
  String? _sessionPassword;
  String? _deviceId;
  String _fruitDetectionModelMode = _fruitDetectionAutoMode;
  String _fruitDetectionModelId = FruitDetectionService.defaultModelId;
  Map<String, Object?>? _deviceProfile;
  DateTime? _lastBackGestureAt;
  Timer? _cloudSyncTimer;
  StreamSubscription<List<Map<String, Object?>>>? _inventoryLiveSubscription;
  StreamSubscription<List<Map<String, Object?>>>? _transactionsLiveSubscription;
  String? _liveSyncUserId;
  int _liveSyncGeneration = 0;
  Timer? _scaleLogTimer;
  Timer? _splashFadeTimer;
  Timer? _splashRemoveTimer;
  CameraEyeStatus _cameraEyeStatus = const CameraEyeStatus.idle();
  AiAutomationResult? _latestAiForecast;
  String? _latestAiError;
  bool _inventoryLoading = true;
  bool _cloudSyncRunning = false;
  bool _splashMounted = true;
  bool _splashVisible = true;
  int _walkthroughPage = 0;
  int _selectedYear = DateTime.now().year;
  int _selectedMonth = DateTime.now().month - 1;
  DateTime _selectedHistoryDate = _historyDateOnly(DateTime.now());
  String? _fruitToAdd;
  String? _expandedInventoryFruit;
  String? _priceConflictNotice;
  String _scaleBaseUrl = '';
  String _scaleLogStatus = 'Scale device not configured';
  bool _scaleLogSyncRunning = false;
  DateTime? _lastScaleLogSyncAt;
  List<TransactionData> _realTransactionHistory = <TransactionData>[];
  List<LocalPriceChange> _priceChangeHistory = <LocalPriceChange>[];
  final Set<String> _configuredPriceFruits = <String>{};
  final Set<String> _priceConflictFruits = <String>{};

  final List<String> _managedFruits = <String>[
    'Apple',
    'Orange',
    'Banana',
    'Mango',
    'Grapes',
  ];
  final Map<String, int> _prices = <String, int>{};
  final Map<String, int> _draftPrices = <String, int>{};
  final Map<String, int> _stocks = <String, int>{};

  static const List<TransactionData> _demoTransactionHistory =
      <TransactionData>[
        TransactionData(
          'Mango',
          '1.2 kg',
          'PHP 72.00',
          'Apr 29, 2026',
          '10:42 AM',
          'Sold',
        ),
        TransactionData(
          'Banana',
          '0.8 kg',
          'PHP 28.00',
          'Apr 29, 2026',
          '10:39 AM',
          'Sold',
        ),
        TransactionData(
          'Orange',
          '2.1 kg',
          'PHP 178.50',
          'Apr 29, 2026',
          '10:31 AM',
          'Cancelled',
        ),
        TransactionData(
          'Apple',
          '1.5 kg',
          'PHP 135.00',
          'Apr 29, 2026',
          '10:18 AM',
          'Sold',
        ),
        TransactionData(
          'Grapes',
          '0.6 kg',
          'PHP 78.00',
          'Apr 29, 2026',
          '10:05 AM',
          'Cancelled',
        ),
        TransactionData(
          'Mango',
          '1.4 kg',
          'PHP 84.00',
          'Apr 29, 2026',
          '9:54 AM',
          'Sold',
        ),
        TransactionData(
          'Orange',
          '1.0 kg',
          'PHP 85.00',
          'Apr 29, 2026',
          '9:41 AM',
          'Sold',
        ),
        TransactionData(
          'Banana',
          '1.1 kg',
          'PHP 38.50',
          'Apr 29, 2026',
          '9:29 AM',
          'Sold',
        ),
        TransactionData(
          'Grapes',
          '0.5 kg',
          'PHP 65.00',
          'Apr 29, 2026',
          '9:12 AM',
          'Sold',
        ),
        TransactionData(
          'Apple',
          '1.4 kg',
          'PHP 126.00',
          'Apr 29, 2026',
          '8:58 AM',
          'Sold',
        ),
        TransactionData(
          'Orange',
          '1.8 kg',
          'PHP 153.00',
          'Apr 29, 2026',
          '8:36 AM',
          'Sold',
        ),
        TransactionData(
          'Mango',
          '0.9 kg',
          'PHP 54.00',
          'Apr 29, 2026',
          '8:20 AM',
          'Cancelled',
        ),
      ];

  bool get _authBusy =>
      _signingIn ||
      _googleSigningIn ||
      _biometricSigningIn ||
      _creatingAccount ||
      _signingOut ||
      _sendingReset;

  bool get _phoneUnlockGateVisible =>
      _screen == AppScreen.login &&
      !_isGuestSession &&
      _phoneLinkEnabled &&
      _activePhoneLinkEmail != null &&
      !_biometricUnlockPromptDismissed;

  bool get _emailPasswordSyncBlocked =>
      _emailPasswordProviderBlocked ||
      _cloudSyncStatus == 'Email sign-in disabled';

  bool get _screenSupportsPullRefresh {
    switch (_screen) {
      case AppScreen.dashboard:
      case AppScreen.inventory:
      case AppScreen.inventoryManage:
      case AppScreen.forecast:
      case AppScreen.analytics:
      case AppScreen.transactions:
        return true;
      case AppScreen.walkthrough:
      case AppScreen.login:
      case AppScreen.createAccount:
      case AppScreen.forgotPassword:
        return false;
    }
  }

  String? get _activePhoneLinkEmail {
    if (!_phoneLinkEnabled) {
      return null;
    }
    return _phoneLinkAccountEmail ?? _rememberedAccountEmail;
  }

  bool _phoneLinkBelongsTo(String email) {
    final String? linkedEmail = _activePhoneLinkEmail;
    return linkedEmail != null &&
        linkedEmail.toLowerCase() == email.toLowerCase();
  }

  List<TransactionData> get _activeTransactionHistory =>
      _isGuestSession ? _demoTransactionHistory : _realTransactionHistory;

  List<TransactionData> get _visibleTransactionHistory =>
      _activeTransactionHistory
          .where(
            (TransactionData transaction) => transaction.status != 'Removed',
          )
          .toList(growable: false);

  List<TransactionData> get _selectedHistoryDateTransactions =>
      _visibleTransactionHistory
          .where((TransactionData transaction) {
            final DateTime? soldDate = _transactionHistoryDay(transaction);
            return soldDate != null &&
                _isSameDay(soldDate, _selectedHistoryDate);
          })
          .toList(growable: false);

  static const Map<String, FruitInfo> _catalog = <String, FruitInfo>{
    'Apple': FruitInfo('Apple', Icons.apple_rounded, 90, 20),
    'Orange': FruitInfo('Orange', Icons.circle_rounded, 85, 25),
    'Banana': FruitInfo('Banana', Icons.rice_bowl_rounded, 35, 28),
    'Mango': FruitInfo('Mango', Icons.spa_rounded, 60, 42),
    'Grapes': FruitInfo('Grapes', Icons.bubble_chart_rounded, 130, 10),
    'Lemon': FruitInfo('Lemon', Icons.brightness_1_rounded, 70, 17),
    'Papaya': FruitInfo('Papaya', Icons.eco_rounded, 50, 15),
    'Watermelon': FruitInfo('Watermelon', Icons.circle_rounded, 50, 60),
    'Pineapple': FruitInfo('Pineapple', Icons.park_rounded, 45, 0),
    'Calamansi': FruitInfo('Calamansi', Icons.brightness_1_rounded, 65, 13),
    'Pomelo': FruitInfo('Pomelo', Icons.circle_rounded, 95, 10),
    'Guava': FruitInfo('Guava', Icons.local_florist_rounded, 50, 21),
    'Avocado': FruitInfo('Avocado', Icons.grass_rounded, 110, 18),
    'Coconut': FruitInfo('Coconut', Icons.beach_access_rounded, 35, 20),
    'Dalandan': FruitInfo('Dalandan', Icons.circle_rounded, 75, 18),
    'Dragon Fruit': FruitInfo(
      'Dragon Fruit',
      Icons.auto_awesome_rounded,
      140,
      8,
    ),
    'Durian': FruitInfo('Durian', Icons.energy_savings_leaf_rounded, 180, 6),
    'Mangosteen': FruitInfo('Mangosteen', Icons.blur_circular_rounded, 160, 9),
    'Rambutan': FruitInfo('Rambutan', Icons.scatter_plot_rounded, 120, 11),
    'Lanzones': FruitInfo('Lanzones', Icons.scatter_plot_rounded, 120, 7),
    'Chico': FruitInfo('Chico', Icons.spa_rounded, 80, 12),
    'Atis': FruitInfo('Atis', Icons.eco_rounded, 95, 10),
    'Santol': FruitInfo('Santol', Icons.trip_origin_rounded, 70, 14),
    'Star Apple': FruitInfo('Star Apple', Icons.stars_rounded, 90, 9),
    'Jackfruit': FruitInfo('Jackfruit', Icons.park_rounded, 65, 8),
    'Tamarind': FruitInfo('Tamarind', Icons.grass_rounded, 75, 12),
    'Melon': FruitInfo('Melon', Icons.blur_circular_rounded, 55, 16),
    'Guyabano': FruitInfo('Guyabano', Icons.eco_rounded, 100, 8),
    'Mango Carabao': FruitInfo('Mango Carabao', Icons.spa_rounded, 80, 14),
    'Indian Mango': FruitInfo('Indian Mango', Icons.spa_rounded, 75, 12),
    'Langkatan': FruitInfo('Langkatan', Icons.rice_bowl_rounded, 45, 9),
    'Pear': FruitInfo('Pear', Icons.local_florist_rounded, 95, 11),
    'Strawberries': FruitInfo('Strawberries', Icons.favorite_rounded, 120, 8),
  };

  static final Set<String> _scanReadyFruits = _catalog.keys.toSet();

  static const List<String> _scanReadyFruitOrder = <String>[
    'Apple',
    'Orange',
    'Banana',
    'Mango',
    'Grapes',
    'Lemon',
    'Papaya',
    'Watermelon',
    'Pineapple',
    'Calamansi',
    'Pomelo',
    'Guava',
    'Avocado',
    'Coconut',
    'Dalandan',
    'Dragon Fruit',
    'Durian',
    'Mangosteen',
    'Rambutan',
    'Lanzones',
    'Chico',
    'Atis',
    'Santol',
    'Star Apple',
    'Jackfruit',
    'Tamarind',
    'Melon',
    'Guyabano',
    'Mango Carabao',
    'Indian Mango',
    'Langkatan',
    'Pear',
    'Strawberries',
  ];

  static const List<_WalkthroughStep> _walkthroughSteps = <_WalkthroughStep>[
    _WalkthroughStep(
      icon: Icons.storefront_rounded,
      title: 'Set up your fruit stall',
      body:
          'Create or sign in to a real account, set fruit prices, and keep sales available on this phone.',
      points: <String>['Real account', 'Price per kg', 'Offline ready'],
    ),
    _WalkthroughStep(
      icon: Icons.center_focus_strong_rounded,
      title: 'Scan, weigh, and sell',
      body:
          'FruityVens is designed to pair fruit detection with weighing data so sales can be calculated faster.',
      points: <String>['Fruit AI', 'Scale weight', 'Auto totals'],
    ),
    _WalkthroughStep(
      icon: Icons.fingerprint_rounded,
      title: 'Unlock on this phone',
      body:
          'After sign-in, link the account to this device with a 6-digit PIN and optional biometrics.',
      points: <String>['PIN backup', 'Biometrics', 'Saved account'],
    ),
    _WalkthroughStep(
      icon: Icons.insights_rounded,
      title: 'Track and restock',
      body:
          'Sales update rankings, analytics, reports, and forecasting advice without mixing demo data into real accounts.',
      points: <String>['Rankings', 'Forecasting', 'PDF reports'],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _database = widget.database ?? AppDatabase();
    _ownsDatabase = widget.database == null;
    _cloudSyncEnabled = _firebaseSyncService.isAvailable;
    _cloudSyncStatus = _cloudSyncEnabled
        ? 'Firebase sync ready'
        : 'Offline mode';
    _syncFruitState();
    unawaited(_loadThemePreference());
    _loadRememberedAccount();
    _loadDeviceId();
    _loadFruitDetectionModelPreference();
    unawaited(_loadScaleLogSettings());
    _loadInventoryFromDatabase();
    _loadTransactionsFromDatabase();
    _loadPriceHistoryFromDatabase();
    _startCloudSyncMonitor();
    if (widget.database == null) {
      _startSplash();
    } else {
      _splashMounted = false;
      _splashVisible = false;
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _signupNameController.dispose();
    _signupEmailController.dispose();
    _signupPasswordController.dispose();
    _signupConfirmController.dispose();
    _resetEmailController.dispose();
    _newPriceController.dispose();
    _scaleBaseUrlController.dispose();
    for (final TextEditingController controller
        in _priceInputControllers.values) {
      controller.dispose();
    }
    for (final FocusNode focusNode in _priceInputFocusNodes.values) {
      focusNode.dispose();
    }
    _cloudSyncTimer?.cancel();
    _stopFirebaseLiveSync();
    _scaleLogTimer?.cancel();
    _splashFadeTimer?.cancel();
    _splashRemoveTimer?.cancel();
    if (_ownsDatabase) {
      _database.close();
    }
    super.dispose();
  }

  void _startSplash() {
    _splashFadeTimer?.cancel();
    _splashRemoveTimer?.cancel();
    _splashFadeTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _splashVisible = false;
      });
    });
    _splashRemoveTimer = Timer(const Duration(milliseconds: 2300), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _splashMounted = false;
      });
      unawaited(_autoUnlockPhoneLinkIfNeeded());
    });
  }

  void _startCloudSyncMonitor() {
    _cloudSyncTimer?.cancel();
    _cloudSyncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_syncWhenInternetReturns());
    });
  }

  void _startFirebaseLiveSync() {
    final String? uid = _firebaseSyncService.currentUserId;
    if (!_cloudSyncEnabled || _isGuestSession || uid == null) {
      _stopFirebaseLiveSync();
      return;
    }
    if (_liveSyncUserId == uid &&
        _inventoryLiveSubscription != null &&
        _transactionsLiveSubscription != null) {
      return;
    }

    _stopFirebaseLiveSync();
    _liveSyncGeneration += 1;
    final int generation = _liveSyncGeneration;
    _liveSyncUserId = uid;
    _inventoryLiveSubscription = _firebaseSyncService.watchInventory().listen(
      (List<Map<String, Object?>> inventory) {
        unawaited(
          _applyCloudInventoryFromFirebase(
            inventory,
            fromLiveSync: true,
            liveSyncUserId: uid,
            liveSyncGeneration: generation,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_isLiveSyncCurrent(uid, generation)) {
          return;
        }
        _handleFirebaseLiveSyncError(
          'Inventory live sync failed',
          error,
          stackTrace,
        );
      },
    );
    _transactionsLiveSubscription = _firebaseSyncService
        .watchTransactions()
        .listen(
          (List<Map<String, Object?>> transactions) {
            unawaited(
              _applyCloudTransactionsFromFirebase(
                transactions,
                fromLiveSync: true,
                liveSyncUserId: uid,
                liveSyncGeneration: generation,
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_isLiveSyncCurrent(uid, generation)) {
              return;
            }
            _handleFirebaseLiveSyncError(
              'Transaction live sync failed',
              error,
              stackTrace,
            );
          },
        );
  }

  void _stopFirebaseLiveSync() {
    _liveSyncGeneration += 1;
    _liveSyncUserId = null;
    final StreamSubscription<List<Map<String, Object?>>>? inventory =
        _inventoryLiveSubscription;
    final StreamSubscription<List<Map<String, Object?>>>? transactions =
        _transactionsLiveSubscription;
    _inventoryLiveSubscription = null;
    _transactionsLiveSubscription = null;
    if (inventory != null) {
      unawaited(inventory.cancel());
    }
    if (transactions != null) {
      unawaited(transactions.cancel());
    }
  }

  bool _isLiveSyncCurrent(String userId, int generation) {
    return mounted &&
        !_isGuestSession &&
        _cloudSyncEnabled &&
        _liveSyncUserId == userId &&
        _liveSyncGeneration == generation &&
        _firebaseSyncService.currentUserId == userId;
  }

  bool _canApplyCloudLiveSync(String? userId, int? generation) {
    if (userId == null || generation == null) {
      return true;
    }
    return _isLiveSyncCurrent(userId, generation);
  }

  void _handleFirebaseLiveSyncError(
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    _logCloudSyncIssue(message, error, stackTrace);
    if (!mounted) {
      return;
    }
    final String syncMessage = _firebaseSyncErrorMessage(error);
    setState(() {
      _emailPasswordProviderBlocked = _isEmailPasswordProviderDisabledMessage(
        syncMessage,
      );
      _cloudSyncStatus = _cloudStatusForSyncError(syncMessage);
    });
  }

  String _firebaseSyncErrorMessage(Object error) {
    if (error is FirebaseException) {
      final String code = error.code.toLowerCase();
      final String message = (error.message ?? '').toLowerCase();
      if (code == 'permission-denied' ||
          message.contains('permission denied') ||
          message.contains('permission_denied')) {
        return 'Realtime Database rules blocked cloud sync. Allow users/{uid} reads and writes in Firebase Rules.';
      }
      return error.message ?? error.code;
    }
    return error.toString();
  }

  Future<void> _loadScaleLogSettings() async {
    final String? savedDeviceId = await _database.getSetting(_scaleDeviceIdKey);
    final String scaleDeviceId = (savedDeviceId ?? _defaultScaleDeviceId)
        .trim();
    if (!mounted) {
      return;
    }
    setState(() {
      _scaleBaseUrl = scaleDeviceId;
      _scaleLogStatus = scaleDeviceId.isEmpty
          ? 'Scale device not configured'
          : 'Firebase scale sync ready';
    });
    _scaleBaseUrlController.text = scaleDeviceId;
    _startScaleLogMonitor();
  }

  void _startScaleLogMonitor() {
    _scaleLogTimer?.cancel();
    if (_scaleBaseUrl.trim().isEmpty) {
      return;
    }
    _scaleLogTimer = Timer.periodic(_scaleLogAutoPollInterval, (_) {
      unawaited(_fetchConfirmedScaleLogs(showProgress: false));
    });
    unawaited(_fetchConfirmedScaleLogs(showProgress: false));
  }

  bool get _scaleLogCanImport {
    return _scaleBaseUrl.trim().isNotEmpty &&
        !_isGuestSession &&
        _screen != AppScreen.walkthrough &&
        _screen != AppScreen.login &&
        _screen != AppScreen.createAccount &&
        _screen != AppScreen.forgotPassword;
  }

  Future<void> _saveScaleBaseUrl({StateSetter? dialogSetState}) async {
    final String nextDeviceId = _scaleBaseUrlController.text.trim();
    await _database.saveSetting(_scaleDeviceIdKey, nextDeviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _scaleBaseUrl = nextDeviceId;
      _scaleLogStatus = nextDeviceId.isEmpty
          ? 'Scale device not configured'
          : 'Firebase scale sync ready';
    });
    dialogSetState?.call(() {});
    _startScaleLogMonitor();
    _toast(
      nextDeviceId.isEmpty
          ? 'Scale Firebase sync disabled.'
          : 'Scale device sync saved.',
    );
  }

  Future<void> _fetchConfirmedScaleLogs({
    bool showToast = false,
    bool showProgress = true,
  }) async {
    if (_scaleLogSyncRunning || _scaleBaseUrl.trim().isEmpty) {
      return;
    }
    if (!mounted) {
      return;
    }
    if (!_scaleLogCanImport) {
      if (showToast) {
        _toast('Sign in to save confirmed scale logs.');
      }
      return;
    }

    setState(() {
      _scaleLogSyncRunning = true;
      if (showProgress) {
        _scaleLogStatus = 'Checking Firebase scale...';
      }
    });

    try {
      final List<ScaleSaleLog> logs = await _scaleLogService.fetchSales(
        _scaleBaseUrl,
      );
      int imported = 0;
      final List<ScaleSaleLog> acknowledgedLogs = <ScaleSaleLog>[];
      for (final ScaleSaleLog log in logs) {
        final bool saved = await _saveScaleSaleLog(log);
        if (saved) {
          imported++;
        }
        acknowledgedLogs.add(log);
      }
      if (acknowledgedLogs.isNotEmpty) {
        await _scaleLogService.acknowledgeSales(
          deviceId: _scaleBaseUrl,
          sales: acknowledgedLogs,
        );
      }
      if (imported > 0) {
        await _loadTransactionsFromDatabase();
        unawaited(_syncTransactionsToFirebase());
      }
      if (!mounted) {
        return;
      }
      final DateTime syncedAt = DateTime.now();
      setState(() {
        _lastScaleLogSyncAt = syncedAt;
        if (imported > 0) {
          _scaleLogStatus =
              'Imported $imported Firebase scale sale${imported == 1 ? '' : 's'}';
        } else if (showProgress) {
          _scaleLogStatus = 'No new Firebase scale sales.';
        } else if (_scaleLogStatus == 'Checking Firebase scale...' ||
            _scaleLogStatus == 'Firebase scale sync ready') {
          _scaleLogStatus = 'Firebase scale sync ready';
        }
      });
      if (showToast) {
        _toast(
          imported == 0
              ? 'No new Firebase scale sales.'
              : 'Imported $imported Firebase scale sale${imported == 1 ? '' : 's'}.',
        );
      }
    } on ScaleLogException catch (error, stackTrace) {
      developer.log(
        'Firebase scale sync failed',
        name: 'FruityVensScale',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _scaleLogStatus = error.message;
      });
      if (showToast) {
        _toast(error.message);
      }
    } catch (error, stackTrace) {
      developer.log(
        'Unexpected scale log sync failure',
        name: 'FruityVensScale',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _scaleLogStatus = 'Firebase scale sync failed.';
      });
      if (showToast) {
        _toast('Firebase scale sync failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _scaleLogSyncRunning = false;
        });
      } else {
        _scaleLogSyncRunning = false;
      }
    }
  }

  Future<bool> _saveScaleSaleLog(ScaleSaleLog log) async {
    final String cloudId = log.cloudId(_scaleBaseUrl);
    if (await _database.saleExistsByCloudId(cloudId)) {
      return false;
    }
    final int unitPrice = log.pricePerKgCentavos > 0
        ? log.pricePerKgCentavos
        : (_inventorySavedPrice(log.fruitName) ??
              _catalogPriceCentavos(log.fruitName));
    final int totalPrice = log.priceCentavos > 0
        ? log.priceCentavos
        : ((unitPrice * log.weightGrams) / 1000).round();
    await _database.addSale(
      cloudId: cloudId,
      fruitName: log.fruitName,
      weightGrams: math.max(0, log.weightGrams),
      unitPrice: math.max(0, unitPrice),
      totalPrice: math.max(0, totalPrice),
      soldAt: log.soldAt,
      status: 'sold',
    );
    return true;
  }

  Future<void> _syncWhenInternetReturns() async {
    if (!_cloudSyncEnabled ||
        _cloudSyncRunning ||
        _isGuestSession ||
        _screen == AppScreen.login ||
        (_emailPasswordSyncBlocked &&
            _firebaseSyncService.currentUserId == null)) {
      return;
    }
    if (_firebaseSyncService.currentUserId != null) {
      _startFirebaseLiveSync();
    }

    final bool online = await _hasInternetConnection();
    if (!mounted || !online) {
      return;
    }

    _cloudSyncRunning = true;
    try {
      if (_firebaseSyncService.currentUserId == null) {
        final String? email = _sessionEmail ?? _rememberedAccountEmail;
        final String? password = _sessionPassword;
        if (email == null || password == null) {
          if (mounted) {
            setState(() {
              _cloudSyncStatus = 'Offline account';
            });
          }
          return;
        }
        final FirebaseAccount? cloudAccount = await _firebaseSyncService
            .signInWithEmail(email: email, password: password);
        if (cloudAccount == null) {
          if (mounted) {
            setState(() {
              _cloudSyncStatus = 'Offline account';
            });
          }
          return;
        }
        await _database.saveAccount(
          name: cloudAccount.name ?? email.split('@').first,
          email: email,
          password: password,
        );
      }
      await _registerCurrentDeviceWithFirebase();
      await _pullInventoryFromFirebase();
      await _syncInventoryToFirebase();
      await _syncTransactionsToFirebase();
      await _pullTransactionsFromFirebase();
      _startFirebaseLiveSync();
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = _priceConflictFruits.isEmpty
            ? 'Synced with Firebase'
            : 'Price conflict needs review';
      });
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Cloud sync failed while reconnecting',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = _isEmailPasswordProviderDisabledMessage(
          error.message,
        );
        _cloudSyncStatus = _cloudStatusForSyncError(error.message);
      });
    } catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Unexpected cloud sync failure while reconnecting',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cloudSyncStatus = 'Offline account';
      });
    } finally {
      _cloudSyncRunning = false;
    }
  }

  Future<void> _refreshCurrentScreen() async {
    await _loadInventoryFromDatabase();
    await _loadTransactionsFromDatabase();
    if (!mounted || !_screenSupportsPullRefresh) {
      return;
    }
    if (_isGuestSession) {
      _toast('Demo data refreshed.');
      return;
    }

    final bool online = await _hasInternetConnection();
    if (!mounted) {
      return;
    }
    if (!online) {
      setState(() {
        _cloudSyncStatus = 'Offline account';
      });
      _toast('Offline data refreshed.');
      return;
    }

    await _syncWhenInternetReturns();
    if (!mounted) {
      return;
    }
    _toast(
      _cloudSyncStatus == 'Synced with Firebase'
          ? 'Synced with Firebase.'
          : 'Local data refreshed.',
    );
  }

  String _cloudStatusForSyncError(String message) {
    final String cleanMessage = message.toLowerCase();
    if (_isEmailPasswordProviderDisabledMessage(message)) {
      return 'Email sign-in disabled';
    }
    if (cleanMessage.contains('app check') ||
        cleanMessage.contains('appcheck') ||
        cleanMessage.contains('attestation')) {
      return 'Cloud sync blocked by App Check';
    }
    if (cleanMessage.contains('rules') ||
        cleanMessage.contains('permission denied') ||
        cleanMessage.contains('permission_denied') ||
        cleanMessage.contains('blocked')) {
      return 'Cloud sync blocked by rules';
    }
    if (cleanMessage.contains('internet') ||
        cleanMessage.contains('network') ||
        cleanMessage.contains('timeout') ||
        cleanMessage.contains('unavailable')) {
      return 'Offline account';
    }
    return 'Firebase sync paused';
  }

  bool _isEmailPasswordProviderDisabledMessage(String message) {
    final String cleanMessage = message.toLowerCase();
    return cleanMessage.contains('enable email/password') ||
        cleanMessage.contains('operation-not-allowed') ||
        cleanMessage.contains('operation is not allowed');
  }

  void _logCloudSyncIssue(String message, Object error, StackTrace stackTrace) {
    developer.log(
      message,
      name: 'FruityVensFirebase',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _syncFruitState() {
    for (final String fruit in _managedFruits) {
      _prices.putIfAbsent(fruit, () => 0);
      _stocks.putIfAbsent(fruit, () => 0);
    }
  }

  Future<void> _loadInventoryFromDatabase() async {
    await _database.seedFruitCatalog(_catalogCompanions());
    final List<LocalFruit> fruits = await _database.getManagedFruits();
    final List<LocalFruit> scanReadyFruits = fruits
        .where((LocalFruit fruit) => _scanReadyFruits.contains(fruit.name))
        .toList();
    final Set<String> configuredPriceFruits = await _loadConfiguredPriceFruits(
      scanReadyFruits,
    );
    final Set<String> loadedFruitNames = scanReadyFruits
        .map((LocalFruit fruit) => fruit.name)
        .toSet();
    if (!mounted) {
      return;
    }
    final Set<String> activeInputFruitNames = _isGuestSession
        ? _scanReadyFruitOrder.toSet()
        : loadedFruitNames;
    setState(() {
      _managedFruits
        ..clear()
        ..addAll(scanReadyFruits.map((LocalFruit fruit) => fruit.name));
      if (_expandedInventoryFruit != null &&
          !_managedFruits.contains(_expandedInventoryFruit)) {
        _expandedInventoryFruit = null;
      }
      _prices
        ..clear()
        ..addEntries(
          scanReadyFruits.map(
            (LocalFruit fruit) => MapEntry<String, int>(
              fruit.name,
              configuredPriceFruits.contains(fruit.name) ? fruit.price : 0,
            ),
          ),
        );
      _stocks
        ..clear()
        ..addEntries(
          scanReadyFruits.map(
            (LocalFruit fruit) => MapEntry<String, int>(fruit.name, 0),
          ),
        );
      _configuredPriceFruits
        ..clear()
        ..addAll(configuredPriceFruits);
      _draftPrices.removeWhere(
        (String fruit, int _) => !loadedFruitNames.contains(fruit),
      );
      if (_isGuestSession) {
        _managedFruits
          ..clear()
          ..addAll(_scanReadyFruitOrder);
        _prices
          ..clear()
          ..addEntries(
            _scanReadyFruitOrder.map((String fruit) {
              return MapEntry<String, int>(fruit, _catalogPriceCentavos(fruit));
            }),
          );
        _stocks
          ..clear()
          ..addEntries(
            _scanReadyFruitOrder.map((String fruit) {
              return MapEntry<String, int>(fruit, 0);
            }),
          );
        _configuredPriceFruits
          ..clear()
          ..addAll(_scanReadyFruitOrder);
        _draftPrices.clear();
      }
      _inventoryLoading = false;
    });
    _disposePriceInputsExcept(activeInputFruitNames);
  }

  void _disposePriceInputsExcept(Set<String> activeFruits) {
    final List<String> staleInputs = _priceInputControllers.keys
        .where((String fruit) => !activeFruits.contains(fruit))
        .toList();
    for (final String fruit in staleInputs) {
      _priceInputControllers.remove(fruit)?.dispose();
      _priceInputFocusNodes.remove(fruit)?.dispose();
    }
  }

  Future<Set<String>> _loadConfiguredPriceFruits(
    List<LocalFruit> fruits,
  ) async {
    final Set<String> configured = <String>{};
    for (final LocalFruit fruit in fruits) {
      final String? savedFlag = await _database.getSetting(
        _inventoryPriceConfiguredKey(fruit.name),
      );
      final int defaultPrice = _catalogPriceCentavos(fruit.name);
      if (savedFlag == '0') {
        continue;
      }
      if (savedFlag == '1' ||
          (fruit.price > 0 && fruit.price != defaultPrice)) {
        configured.add(fruit.name);
      }
    }
    return configured;
  }

  Future<void> _loadTransactionsFromDatabase() async {
    final List<LocalSale> sales = await _database.getSalesTransactions();
    if (!mounted) {
      return;
    }
    setState(() {
      _realTransactionHistory = sales.map(_transactionFromSale).toList();
    });
  }

  TransactionData _transactionFromSale(LocalSale sale) {
    return TransactionData(
      sale.fruitName,
      _formatWeight(sale.weightGrams),
      money(sale.totalPrice),
      _formatDate(sale.soldAt),
      _formatTime(sale.soldAt),
      _displayStatus(sale.status),
      soldAt: sale.soldAt,
      saleId: sale.id,
      cloudId: sale.cloudId,
    );
  }

  Future<void> _loadPriceHistoryFromDatabase() async {
    final List<LocalPriceChange> changes = await _database
        .getPriceChangeHistory(limit: 5);
    if (!mounted) {
      return;
    }
    setState(() {
      _priceChangeHistory = changes;
    });
  }

  DashboardStats _dashboardStats() {
    final DateTime now = DateTime.now();
    final List<TransactionData> soldTransactions = _activeTransactionHistory
        .where((TransactionData transaction) {
          if (!_isSoldTransaction(transaction)) {
            return false;
          }
          return _isGuestSession ||
              (transaction.soldAt != null &&
                  _isSameDay(transaction.soldAt!, now));
        })
        .toList();
    final int totalSales = soldTransactions.fold<int>(0, (
      int sum,
      TransactionData transaction,
    ) {
      return sum + _parsePesoAmount(transaction.price);
    });
    final double totalWeightKg = soldTransactions.fold<double>(0, (
      double sum,
      TransactionData transaction,
    ) {
      return sum + _parseKgAmount(transaction.weight);
    });
    final Map<String, int> fruitCounts = <String, int>{};
    final Map<String, double> fruitWeights = <String, double>{};
    final Map<String, int> fruitRevenue = <String, int>{};
    for (final TransactionData transaction in soldTransactions) {
      fruitCounts.update(
        transaction.fruit,
        (int value) => value + 1,
        ifAbsent: () => 1,
      );
      fruitWeights.update(
        transaction.fruit,
        (double value) => value + _parseKgAmount(transaction.weight),
        ifAbsent: () => _parseKgAmount(transaction.weight),
      );
      fruitRevenue.update(
        transaction.fruit,
        (int value) => value + _parsePesoAmount(transaction.price),
        ifAbsent: () => _parsePesoAmount(transaction.price),
      );
    }
    final List<FruitRank> topFruitRanks =
        fruitCounts.entries.map((MapEntry<String, int> entry) {
          return FruitRank(
            name: entry.key,
            transactions: entry.value,
            weightKg: fruitWeights[entry.key] ?? 0,
            revenuePhp: fruitRevenue[entry.key] ?? 0,
          );
        }).toList()..sort((FruitRank a, FruitRank b) {
          final int revenueCompare = b.revenuePhp.compareTo(a.revenuePhp);
          if (revenueCompare != 0) {
            return revenueCompare;
          }
          final int weightCompare = b.weightKg.compareTo(a.weightKg);
          if (weightCompare != 0) {
            return weightCompare;
          }
          return b.transactions.compareTo(a.transactions);
        });
    final String topFruit = topFruitRanks.isEmpty
        ? 'No sales yet'
        : topFruitRanks.first.name;

    final double averageWeightKg = soldTransactions.isEmpty
        ? 0
        : totalWeightKg / soldTransactions.length;

    return DashboardStats(
      salesTotal: totalSales,
      transactionCount: soldTransactions.length,
      averageWeightKg: averageWeightKg,
      topFruit: topFruit,
      topFruitRanks: topFruitRanks.take(3).toList(),
      salesSubtext: soldTransactions.isEmpty
          ? 'No sales today'
          : '${soldTransactions.length} sales today - Avg ${_formatKgValue(averageWeightKg)}/sale',
    );
  }

  List<SeedFruit> _catalogCompanions() {
    return _catalog.values.map((FruitInfo info) {
      return SeedFruit(
        name: info.name,
        iconKey: info.icon.codePoint.toString(),
        price: 0,
        stock: 0,
        managed: _managedFruits.contains(info.name),
      );
    }).toList();
  }

  String _inventoryPriceConfiguredKey(String fruit) {
    return '$_inventoryPriceConfiguredPrefix${fruit.toLowerCase()}';
  }

  int _catalogPriceCentavos(String fruit) {
    return ((_catalog[fruit]?.price ?? 0) * 100).round();
  }

  bool _inventoryPriceIsConfigured(String fruit) {
    return _configuredPriceFruits.contains(fruit) && (_prices[fruit] ?? 0) > 0;
  }

  int? _inventorySavedPrice(String fruit) {
    return _inventoryPriceIsConfigured(fruit) ? _prices[fruit] : null;
  }

  int _editablePriceFor(String fruit) {
    return _draftPrices[fruit] ?? _prices[fruit] ?? 0;
  }

  TextEditingController _priceInputControllerFor(String fruit) {
    final TextEditingController controller = _priceInputControllers.putIfAbsent(
      fruit,
      TextEditingController.new,
    );
    final FocusNode? focusNode = _priceInputFocusNodes[fruit];
    if (!(focusNode?.hasFocus ?? false)) {
      final String expected = _priceInputFromCentavos(_editablePriceFor(fruit));
      if (controller.text != expected) {
        controller.value = TextEditingValue(
          text: expected,
          selection: TextSelection.collapsed(offset: expected.length),
        );
      }
    }
    return controller;
  }

  FocusNode _priceInputFocusNodeFor(String fruit) {
    return _priceInputFocusNodes.putIfAbsent(fruit, FocusNode.new);
  }

  void _syncPriceInputController(String fruit) {
    final TextEditingController? controller = _priceInputControllers[fruit];
    if (controller == null) {
      return;
    }
    final String text = _priceInputFromCentavos(_editablePriceFor(fruit));
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  FruitDetectionModel get _fruitDetectionModel =>
      FruitDetectionService.modelForId(_fruitDetectionModelId);

  String get _fruitDetectionModeLabel => _fruitDetectionModelMode == 'auto'
      ? 'Auto selected: ${_fruitDetectionModel.title}'
      : 'Manual: ${_fruitDetectionModel.title}';

  String get _deviceTierName {
    final String? tier = _deviceProfile?['tier']?.toString();
    return switch (tier) {
      'high' => 'High',
      'mid' => 'Mid',
      'low' => 'Low',
      _ => 'Checking',
    };
  }

  IconData _fruitDetectionModelIcon(String modelId) {
    return switch (modelId) {
      'int8' => Icons.speed_rounded,
      'float16' => Icons.balance_rounded,
      'float32' => Icons.diamond_rounded,
      _ => Icons.auto_awesome_rounded,
    };
  }

  String _deviceProfileSummary() {
    final String? manufacturer = _deviceProfile?['manufacturer']?.toString();
    final String? model = _deviceProfile?['model']?.toString();
    final num? ram = _deviceProfile?['ramMb'] as num?;
    final num? cores = _deviceProfile?['cpuCores'] as num?;
    final num? sdk = _deviceProfile?['sdk'] as num?;
    final String deviceName = <String>[
      if (manufacturer != null && manufacturer.trim().isNotEmpty)
        manufacturer.trim(),
      if (model != null && model.trim().isNotEmpty) model.trim(),
    ].join(' ');
    final String specs = <String>[
      if (ram != null) '${(ram / 1024).toStringAsFixed(1)}GB RAM',
      if (cores != null) '${cores.round()} cores',
      if (sdk != null) 'Android ${sdk.round()}',
    ].join(' | ');

    if (deviceName.isEmpty && specs.isEmpty) {
      return 'Auto checks phone specs before scanning';
    }
    if (deviceName.isEmpty) {
      return '$_deviceTierName phone | $specs';
    }
    if (specs.isEmpty) {
      return '$deviceName | $_deviceTierName phone';
    }
    return '$deviceName | $_deviceTierName | $specs';
  }

  Future<Map<String, Object?>?> _readDeviceProfile() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final Map<String, dynamic>? profile = await _deviceProfileChannel
          .invokeMapMethod<String, dynamic>('getDeviceProfile');
      return profile?.cast<String, Object?>();
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      developer.log(
        'Device profile check failed',
        name: 'FruityVensDeviceProfile',
        error: error,
      );
      return null;
    }
  }

  FruitDetectionModel _autoFruitDetectionModelFor(
    Map<String, Object?>? profile,
  ) {
    final String? tier = profile?['tier']?.toString();
    return switch (tier) {
      'low' => FruitDetectionService.modelForId('int8'),
      'mid' => FruitDetectionService.modelForId('float16'),
      'high' => FruitDetectionService.modelForId(
        FruitDetectionService.defaultModelId,
      ),
      _ => FruitDetectionService.modelForId(
        FruitDetectionService.defaultModelId,
      ),
    };
  }

  Future<void> _loadRememberedAccount() async {
    final String? email = await _database.getSetting(_rememberedEmailKey);
    final String? rememberedEmail = email == null || email.isEmpty
        ? null
        : email;
    final String? linkedEmailSetting = await _database.getSetting(
      _phoneLinkEmailKey,
    );
    final String? phoneLinkEmail =
        linkedEmailSetting == null || linkedEmailSetting.isEmpty
        ? null
        : linkedEmailSetting;
    final String? biometricSetting = await _database.getSetting(
      _biometricAutoLoginKey,
    );
    final String? phoneLinkSetting = await _database.getSetting(
      _phoneLinkEnabledKey,
    );
    final String? walkthroughSetting = await _database.getSetting(
      _walkthroughSeenKey,
    );
    final bool hasUsablePhoneLink =
        phoneLinkSetting == 'true' && phoneLinkEmail != null;
    final bool shouldShowWalkthrough =
        _ownsDatabase &&
        walkthroughSetting != 'true' &&
        rememberedEmail == null &&
        !hasUsablePhoneLink;
    if (!mounted) {
      return;
    }
    setState(() {
      _rememberedAccountEmail = rememberedEmail;
      _phoneLinkAccountEmail = phoneLinkEmail;
      _biometricAutoLoginEnabled =
          biometricSetting == 'true' && hasUsablePhoneLink;
      _phoneLinkEnabled = hasUsablePhoneLink;
      if (shouldShowWalkthrough && _screen == AppScreen.login) {
        _screen = AppScreen.walkthrough;
      }
    });
    if (!_splashMounted) {
      unawaited(_autoUnlockPhoneLinkIfNeeded());
    }
  }

  Future<String> _loadDeviceId() async {
    final String? saved = await _database.getSetting(_deviceIdKey);
    if (saved != null && saved.isNotEmpty) {
      if (mounted) {
        setState(() {
          _deviceId = saved;
        });
      } else {
        _deviceId = saved;
      }
      return saved;
    }

    final math.Random random = math.Random.secure();
    final String generated =
        'fv_${DateTime.now().millisecondsSinceEpoch}_${List<int>.generate(8, (_) => random.nextInt(256)).map((int value) => value.toRadixString(16).padLeft(2, '0')).join()}';
    await _database.saveSetting(_deviceIdKey, generated);
    if (mounted) {
      setState(() {
        _deviceId = generated;
      });
    } else {
      _deviceId = generated;
    }
    return generated;
  }

  Future<void> _loadFruitDetectionModelPreference() async {
    final String? saved = await _database.getSetting(_fruitDetectionModelKey);
    final bool savedIsManual = FruitDetectionService.builtInModels.any(
      (FruitDetectionModel model) => model.id == saved,
    );
    final String mode = saved == _fruitDetectionAutoMode || saved == null
        ? _fruitDetectionAutoMode
        : savedIsManual
        ? saved
        : _fruitDetectionAutoMode;
    final Map<String, Object?>? profile = await _readDeviceProfile();
    final FruitDetectionModel selected = mode == _fruitDetectionAutoMode
        ? _autoFruitDetectionModelFor(profile)
        : FruitDetectionService.modelForId(mode);
    if (!mounted) {
      return;
    }
    setState(() {
      _deviceProfile = profile;
      _fruitDetectionModelMode = mode;
      _fruitDetectionModelId = selected.id;
    });
  }

  Future<void> _loadThemePreference() async {
    final String? savedTheme = await _database.getSetting(_themeModeKey);
    final bool useLightTheme = savedTheme == 'light';
    if (AppColors.isLightTheme != useLightTheme) {
      AppColors.setLightTheme(useLightTheme);
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _setLightThemeEnabled(
    bool enabled, {
    StateSetter? dialogSetState,
  }) async {
    AppColors.setLightTheme(enabled);
    dialogSetState?.call(() {});
    if (mounted) {
      setState(() {});
    }
    await _database.saveSetting(_themeModeKey, enabled ? 'light' : 'dark');
  }

  Future<bool> _setFruitDetectionModel(String mode) async {
    final Map<String, Object?>? profile = mode == _fruitDetectionAutoMode
        ? await _readDeviceProfile()
        : _deviceProfile;
    final FruitDetectionModel model = mode == _fruitDetectionAutoMode
        ? _autoFruitDetectionModelFor(profile)
        : FruitDetectionService.modelForId(mode);
    final bool available = await FruitDetectionService(
      modelId: model.id,
    ).isModelAvailable();
    if (!available) {
      _toast('${model.title} is missing from this build.');
      return false;
    }

    await _database.saveSetting(_fruitDetectionModelKey, mode);
    if (!mounted) {
      return false;
    }
    setState(() {
      _deviceProfile = profile;
      _fruitDetectionModelMode = mode;
      _fruitDetectionModelId = model.id;
    });
    _toast(
      mode == _fruitDetectionAutoMode
          ? 'Auto selected ${model.title} for $_deviceTierName phone.'
          : 'Fruit AI model set to ${model.title}.',
    );
    return true;
  }

  Future<void> _rememberAccountIfNeeded(String email) async {
    if (!_rememberMe) {
      return;
    }
    final String cleanEmail = email.trim().toLowerCase();
    await _database.saveSetting(_rememberedEmailKey, cleanEmail);
    if (!mounted) {
      return;
    }
    setState(() {
      _rememberedAccountEmail = cleanEmail;
    });
  }

  Map<String, Object?> _fruitSyncPayload(String fruit) {
    final FruitInfo info = _catalog[fruit]!;
    final int priceCentavos = _inventorySavedPrice(fruit) ?? 0;
    return <String, Object?>{
      'name': fruit,
      'iconKey': info.icon.codePoint.toString(),
      'price': priceCentavos / 100,
      'priceCentavos': priceCentavos,
      'priceUnit': 'centavos',
      'managed': _managedFruits.contains(fruit),
      'restockMode': 'sales_velocity',
      'sourceDeviceId': _deviceId ?? '',
    };
  }

  String _scaleFruitNameForHardware(String fruit) {
    switch (fruit) {
      case 'Mango Carabao':
      case 'Indian Mango':
        return 'Mango';
      case 'Strawberry':
        return 'Strawberries';
      case 'Grape':
        return 'Grapes';
      default:
        return fruit;
    }
  }

  List<Map<String, Object?>> _inventorySyncPayload({Iterable<String>? fruits}) {
    return (fruits ?? _managedFruits).map(_fruitSyncPayload).toList();
  }

  Future<void> _syncInventoryToFirebase() async {
    if (!_cloudSyncEnabled || _isGuestSession) {
      return;
    }
    final List<String> syncableFruits = _managedFruits
        .where((String fruit) => !_priceConflictFruits.contains(fruit))
        .toList();
    if (syncableFruits.isEmpty) {
      if (mounted) {
        setState(() {
          _cloudSyncStatus = 'Price conflict needs review';
        });
      }
      return;
    }
    try {
      await _firebaseSyncService.syncInventory(
        _inventorySyncPayload(fruits: syncableFruits),
      );
      for (final String fruit in syncableFruits) {
        await _database.markFruitSynced(fruit);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = _priceConflictFruits.isEmpty
            ? 'Synced with Firebase'
            : 'Price conflict needs review';
      });
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue('Inventory cloud sync failed', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = _isEmailPasswordProviderDisabledMessage(
          error.message,
        );
        _cloudSyncStatus = _cloudStatusForSyncError(error.message);
      });
      _toast(error.message);
    } catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Unexpected inventory cloud sync failure',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cloudSyncStatus = 'Firebase sync paused';
      });
    }
  }

  Future<void> _syncTransactionsToFirebase() async {
    if (!_cloudSyncEnabled || _isGuestSession) {
      return;
    }
    final String deviceId = _deviceId ?? await _loadDeviceId();
    final List<Map<String, Object?>> transactions = await _database
        .getSalesSyncPayloads(deviceId: deviceId);
    if (transactions.isEmpty) {
      return;
    }
    await _firebaseSyncService.syncTransactions(transactions);
  }

  Future<void> _pullInventoryFromFirebase() async {
    if (_isGuestSession ||
        !_cloudSyncEnabled ||
        _firebaseSyncService.currentUserId == null) {
      return;
    }

    final List<Map<String, Object?>> cloudInventory = await _firebaseSyncService
        .fetchInventory();
    await _applyCloudInventoryFromFirebase(cloudInventory);
  }

  Future<void> _applyCloudInventoryFromFirebase(
    List<Map<String, Object?>> cloudInventory, {
    bool fromLiveSync = false,
    String? liveSyncUserId,
    int? liveSyncGeneration,
  }) async {
    if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration) ||
        _isGuestSession ||
        cloudInventory.isEmpty) {
      return;
    }

    for (final Map<String, Object?> fruit in cloudInventory) {
      final String? name = fruit['name'] as String?;
      if (name == null ||
          name.isEmpty ||
          !_catalog.containsKey(name) ||
          !_scanReadyFruits.contains(name)) {
        continue;
      }
      final FruitInfo info = _catalog[name]!;
      final int cloudPrice = _priceCentavosFromCloud(fruit);
      final LocalFruit? localFruit = await _database.getManagedFruit(name);
      if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
        return;
      }
      if (localFruit != null &&
          localFruit.dirty &&
          localFruit.price != cloudPrice) {
        _priceConflictFruits.add(name);
        await _recordPriceChange(
          fruit: name,
          oldPrice: cloudPrice,
          newPrice: localFruit.price,
          source: 'conflict',
          note: 'Kept unsynced local price over cloud pull.',
        );
        if (mounted) {
          setState(() {
            _priceConflictNotice =
                '$name price changed elsewhere. Local price was kept.';
          });
        }
        continue;
      }
      _priceConflictFruits.remove(name);
      if (localFruit != null &&
          !localFruit.dirty &&
          localFruit.price != cloudPrice) {
        await _recordPriceChange(
          fruit: name,
          oldPrice: localFruit.price,
          newPrice: cloudPrice,
          source: 'cloud',
          note: fromLiveSync
              ? 'Updated automatically from Firebase.'
              : 'Synced from Firebase.',
        );
      }
      if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
        return;
      }
      await _database.saveManagedFruitFromCloud(
        name: name,
        iconKey: fruit['iconKey'] as String? ?? info.icon.codePoint.toString(),
        price: cloudPrice,
        stock: 0,
        managed: fruit['managed'] as bool? ?? true,
      );
      if (cloudPrice > 0) {
        await _database.saveSetting(_inventoryPriceConfiguredKey(name), '1');
      }
    }
    if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
      return;
    }
    await _loadInventoryFromDatabase();
    await _loadPriceHistoryFromDatabase();
    if (mounted &&
        fromLiveSync &&
        _canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = _priceConflictFruits.isEmpty
            ? 'Synced with Firebase'
            : 'Price conflict needs review';
      });
    }
  }

  Future<void> _pullTransactionsFromFirebase() async {
    if (_isGuestSession ||
        !_cloudSyncEnabled ||
        _firebaseSyncService.currentUserId == null) {
      return;
    }

    final List<Map<String, Object?>> cloudTransactions =
        await _firebaseSyncService.fetchTransactions();
    await _applyCloudTransactionsFromFirebase(cloudTransactions);
  }

  Future<void> _applyCloudTransactionsFromFirebase(
    List<Map<String, Object?>> cloudTransactions, {
    bool fromLiveSync = false,
    String? liveSyncUserId,
    int? liveSyncGeneration,
  }) async {
    if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration) ||
        _isGuestSession ||
        cloudTransactions.isEmpty) {
      return;
    }
    for (final Map<String, Object?> transaction in cloudTransactions) {
      if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
        return;
      }
      await _database.saveSaleFromCloud(transaction);
    }
    if (!_canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
      return;
    }
    await _loadTransactionsFromDatabase();
    if (mounted &&
        fromLiveSync &&
        _canApplyCloudLiveSync(liveSyncUserId, liveSyncGeneration)) {
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = _priceConflictFruits.isEmpty
            ? 'Synced with Firebase'
            : 'Price conflict needs review';
      });
    }
  }

  Future<void> _registerCurrentDeviceWithFirebase() async {
    if (_isGuestSession ||
        !_cloudSyncEnabled ||
        _firebaseSyncService.currentUserId == null) {
      return;
    }
    final String deviceId = _deviceId ?? await _loadDeviceId();
    await _firebaseSyncService.registerDevice(
      deviceId: deviceId,
      deviceName: _deviceProfileSummary(),
      phoneLinked: _phoneLinkEnabled,
      modelMode: _fruitDetectionModelMode,
      modelId: _fruitDetectionModel.id,
    );
  }

  int? _intFromCloud(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  int _priceCentavosFromCloud(Map<String, Object?> fruit) {
    final int? explicitCentavos = _intFromCloud(fruit['priceCentavos']);
    if (explicitCentavos != null) {
      return explicitCentavos;
    }
    final Object? price = fruit['price'];
    if (fruit['priceUnit'] == 'centavos') {
      return _intFromCloud(price) ?? 0;
    }
    if (price is num) {
      return (price * 100).round();
    }
    if (price is String) {
      return _parsePriceInputCentavos(price) ?? 0;
    }
    return 0;
  }

  Future<void> _recordPriceChange({
    required String fruit,
    required int oldPrice,
    required int newPrice,
    required String source,
    String note = '',
  }) async {
    if (oldPrice == newPrice) {
      return;
    }
    final String deviceId = _deviceId ?? await _loadDeviceId();
    await _database.recordPriceChange(
      fruitName: fruit,
      oldPrice: oldPrice,
      newPrice: newPrice,
      source: source,
      actor:
          _sessionEmail ??
          _rememberedAccountEmail ??
          _phoneLinkAccountEmail ??
          'Local user',
      deviceId: deviceId,
      note: note,
    );
  }

  bool _isSuspiciousPriceChange({
    required int oldPrice,
    required int newPrice,
  }) {
    if (newPrice <= 0) {
      return true;
    }
    if (newPrice < 500 || newPrice > 50000) {
      return true;
    }
    if (oldPrice <= 0) {
      return false;
    }
    final int difference = (newPrice - oldPrice).abs();
    final double changeRatio = difference / oldPrice;
    return difference >= 10000 || changeRatio >= 0.5;
  }

  Future<bool> _confirmSuspiciousPriceChange({
    required String fruit,
    required int oldPrice,
    required int newPrice,
  }) async {
    if (!_isSuspiciousPriceChange(oldPrice: oldPrice, newPrice: newPrice)) {
      return true;
    }
    if (!mounted) {
      return false;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.bgCard,
          title: Text('Check this price'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$fruit is being set to ${money(newPrice)}/kg.',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 8),
              Text(
                oldPrice > 0
                    ? 'Previous price was ${money(oldPrice)}/kg. This is a large or unusual change, so FruityVens will save it in price history.'
                    : 'This looks outside the usual fruit price range. FruityVens will save it in price history.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Save price'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _saveBiometricAutoLogin(bool enabled) async {
    await _database.saveSetting(
      _biometricAutoLoginKey,
      enabled ? 'true' : 'false',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _biometricAutoLoginEnabled = enabled;
    });
  }

  Future<void> _savePhoneLink({
    required String email,
    required String pin,
    required bool biometricsEnabled,
  }) async {
    await _database.saveSetting(_rememberedEmailKey, email);
    await _database.saveSetting(_phoneLinkEmailKey, email);
    await _database.saveSetting(_phoneLinkEnabledKey, 'true');
    await _database.saveSetting(_phoneLinkPinKey, _encodePinSecret(pin));
    await _database.saveSetting(
      _biometricAutoLoginKey,
      biometricsEnabled ? 'true' : 'false',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _rememberedAccountEmail = email;
      _phoneLinkAccountEmail = email;
      _phoneLinkEnabled = true;
      _biometricAutoLoginEnabled = biometricsEnabled;
      _biometricUnlockPromptDismissed = true;
    });
    unawaited(_registerCurrentDeviceWithFirebase());
  }

  String _encodePinSecret(String pin) {
    final math.Random random = math.Random.secure();
    final String salt = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '$salt:${_hashPin(pin, salt)}';
  }

  String _hashPin(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }

  bool _isValidPin(String value) {
    return RegExp(r'^\d{6}$').hasMatch(value);
  }

  bool _verifyPinSecret(String pin, String secret) {
    final List<String> parts = secret.split(':');
    if (parts.length != 2 || !_isValidPin(pin)) {
      return false;
    }
    return _hashPin(pin, parts.first) == parts.last;
  }

  Future<LocalAccount?> _linkedAccount() async {
    final String? email =
        _activePhoneLinkEmail ?? await _database.getSetting(_phoneLinkEmailKey);
    if (email == null || email.isEmpty) {
      return null;
    }
    return _database.getAccountByEmail(email);
  }

  Future<void> _syncFruitToFirebase(String fruit) async {
    if (!_cloudSyncEnabled || _isGuestSession) {
      return;
    }
    if (_priceConflictFruits.contains(fruit)) {
      if (mounted) {
        setState(() {
          _cloudSyncStatus = 'Price conflict needs review';
        });
      }
      return;
    }
    try {
      await _publishScalePriceUpdate(fruit);
      await _firebaseSyncService.syncFruit(_fruitSyncPayload(fruit));
      await _database.markFruitSynced(fruit);
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = 'Synced with Firebase';
      });
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue('Fruit cloud sync failed', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = _isEmailPasswordProviderDisabledMessage(
          error.message,
        );
        _cloudSyncStatus = _cloudStatusForSyncError(error.message);
      });
    } catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Unexpected local account cloud refresh failure',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cloudSyncStatus = 'Firebase sync paused';
      });
    }
  }

  Future<void> _publishScalePriceUpdate(String fruit) async {
    final int? priceCentavos = _inventorySavedPrice(fruit);
    final String configuredScaleDeviceId = _scaleBaseUrl.trim();
    final String scaleDeviceId = configuredScaleDeviceId.isEmpty
        ? _defaultScaleDeviceId
        : configuredScaleDeviceId;
    if (priceCentavos == null ||
        priceCentavos <= 0 ||
        scaleDeviceId.isEmpty ||
        _firebaseSyncService.currentUserId == null) {
      return;
    }
    final String deviceId = _deviceId ?? await _loadDeviceId();
    await _firebaseSyncService.publishScalePriceUpdate(
      scaleDeviceId: scaleDeviceId,
      fruitName: _scaleFruitNameForHardware(fruit),
      priceCentavos: priceCentavos,
      sourceDeviceId: deviceId,
    );
  }

  void _show(AppScreen screen) {
    fruityVensMessengerKey.currentState?.hideCurrentSnackBar();
    setState(() {
      _screen = screen;
      _operationsOpen = false;
      _lastBackGestureAt = null;
    });
  }

  Future<void> _completeWalkthrough({bool startGuest = false}) async {
    await _database.saveSetting(_walkthroughSeenKey, 'true');
    if (!mounted) {
      return;
    }
    if (startGuest) {
      _continueAsGuest();
      return;
    }
    setState(() {
      _screen = AppScreen.login;
      _walkthroughPage = 0;
      _lastBackGestureAt = null;
    });
  }

  void _nextWalkthroughStep() {
    if (_walkthroughPage >= _walkthroughSteps.length - 1) {
      unawaited(_completeWalkthrough());
      return;
    }
    setState(() {
      _walkthroughPage += 1;
    });
  }

  void _previousWalkthroughStep() {
    if (_walkthroughPage <= 0) {
      return;
    }
    setState(() {
      _walkthroughPage -= 1;
    });
  }

  void _handleSystemBack() {
    fruityVensMessengerKey.currentState?.hideCurrentSnackBar();

    if (_operationsOpen) {
      setState(() {
        _operationsOpen = false;
      });
      return;
    }

    switch (_screen) {
      case AppScreen.walkthrough:
        if (_walkthroughPage > 0) {
          _previousWalkthroughStep();
        } else {
          _confirmExitWithSecondBack();
        }
        return;
      case AppScreen.createAccount:
      case AppScreen.forgotPassword:
        setState(() {
          _screen = AppScreen.login;
          _lastBackGestureAt = null;
        });
        return;
      case AppScreen.inventoryManage:
        setState(() {
          _screen = AppScreen.inventory;
          _lastBackGestureAt = null;
        });
        return;
      case AppScreen.inventory:
      case AppScreen.forecast:
      case AppScreen.analytics:
      case AppScreen.transactions:
        setState(() {
          _screen = AppScreen.dashboard;
          _lastBackGestureAt = null;
        });
        return;
      case AppScreen.dashboard:
      case AppScreen.login:
        _confirmExitWithSecondBack();
        return;
    }
  }

  void _confirmExitWithSecondBack() {
    final DateTime now = DateTime.now();
    final DateTime? previous = _lastBackGestureAt;
    if (previous == null ||
        now.difference(previous) > const Duration(seconds: 2)) {
      setState(() {
        _lastBackGestureAt = now;
      });
      _toast('Press back again to exit FruityVens.');
      return;
    }
    SystemNavigator.pop();
  }

  Future<void> _signOut() async {
    if (_signingOut) {
      return;
    }
    fruityVensMessengerKey.currentState?.hideCurrentSnackBar();
    _stopFirebaseLiveSync();
    final String? deviceId = _deviceId;
    if (!mounted) {
      return;
    }
    setState(() {
      _signingOut = true;
      _isGuestSession = false;
      _cloudSyncStatus = _cloudSyncEnabled
          ? 'Firebase sync ready'
          : 'Offline mode';
      _sessionEmail = null;
      _sessionPassword = null;
      _operationsOpen = false;
      _biometricUnlockPromptDismissed = true;
      _screen = AppScreen.login;
    });
    await _signOutCloudBestEffort(deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _signingOut = false;
    });
  }

  Future<void> _signOutCloudBestEffort(String? knownDeviceId) async {
    try {
      final String deviceId = knownDeviceId ?? await _loadDeviceId();
      await _firebaseSyncService
          .markDeviceSignedOut(deviceId)
          .timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logCloudSyncIssue('Device sign-out status skipped', error, stackTrace);
    }
    try {
      await _firebaseSyncService.signOut().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      _logCloudSyncIssue('Firebase sign-out skipped', error, stackTrace);
    }
    try {
      await GoogleSignIn.instance.signOut().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      // Google sign-out is best-effort because local/offline auth can work
      // without the Google plugin being configured.
      developer.log(
        'Google sign-out skipped',
        name: 'FruityVensFirebase',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _showFullAccessRequired(String feature) {
    _toast(
      '$feature is locked in Guest Mode. Create an account for full access.',
      actionLabel: 'Create account',
      onAction: () => _show(AppScreen.createAccount),
    );
  }

  Future<void> _signIn() async {
    if (_authBusy) {
      return;
    }

    final String username = _usernameController.text.trim().toLowerCase();
    final String password = _passwordController.text;
    if (username.isEmpty) {
      _toast('Enter your email address.');
      return;
    }
    if (username.contains(' ') || !username.contains('@')) {
      _toast('Use a valid email address to sign in.');
      return;
    }
    if (password.trim().isEmpty) {
      _toast('Enter your password.');
      return;
    }
    if (password.length < 6) {
      _toast('Password must be at least 6 characters.');
      return;
    }

    setState(() {
      _signingIn = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) {
      return;
    }

    LocalAccount? localAccount = await _database.getAccountByEmail(username);
    if (!mounted) {
      return;
    }

    if (localAccount != null) {
      if (localAccount.password != password) {
        setState(() {
          _signingIn = false;
        });
        _toast('Incorrect password. Try again or reset it.');
        return;
      }

      await _rememberAccountIfNeeded(username);
      if (!mounted) {
        return;
      }
      setState(() {
        _signingIn = false;
        _isGuestSession = false;
        _cloudSyncStatus = 'Offline account';
        _sessionEmail = username;
        _sessionPassword = password;
        _screen = AppScreen.dashboard;
      });
      unawaited(_refreshCloudSessionForLocalAccount(username, password));
      if (_rememberMe) {
        _toast('Signed in from this phone. Sync will resume when online.');
      }
      await _promptLinkPhoneIfNeeded();
      return;
    }

    FirebaseAccount? cloudAccount;
    String? cloudError;
    try {
      cloudAccount = await _firebaseSyncService.signInWithEmail(
        email: username,
        password: password,
      );
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Email sign-in with Firebase failed',
        error,
        stackTrace,
      );
      cloudError = error.message;
    }

    if (cloudAccount == null) {
      setState(() {
        _signingIn = false;
        _cloudSyncStatus = cloudError == null
            ? _cloudSyncStatus
            : _cloudStatusForSyncError(cloudError);
      });
      _toast(
        cloudError == null
            ? 'No saved account on this phone. Connect to internet or create an account first.'
            : 'No saved account on this phone. Connect to internet and try again.',
      );
      return;
    } else {
      await _database.saveAccount(
        name: cloudAccount.name ?? username.split('@').first,
        email: username,
        password: password,
      );
    }

    await _rememberAccountIfNeeded(username);
    if (!mounted) {
      return;
    }
    setState(() {
      _signingIn = false;
      _isGuestSession = false;
      _emailPasswordProviderBlocked =
          cloudError != null &&
          _isEmailPasswordProviderDisabledMessage(cloudError);
      _cloudSyncStatus = cloudAccount == null
          ? (cloudError == null
                ? 'Offline account'
                : _cloudStatusForSyncError(cloudError))
          : 'Signed in with Firebase';
      _sessionEmail = username;
      _sessionPassword = password;
      _screen = AppScreen.dashboard;
    });
    await _syncWhenInternetReturns();
    if (_rememberMe) {
      _toast('Signed in. This device will remember the session.');
    }
    await _promptLinkPhoneIfNeeded();
  }

  Future<void> _refreshCloudSessionForLocalAccount(
    String email,
    String password,
  ) async {
    if (!_cloudSyncEnabled) {
      return;
    }
    if (_emailPasswordSyncBlocked &&
        _firebaseSyncService.currentUserId == null) {
      return;
    }
    if (_firebaseSyncService.currentUserId != null) {
      _startFirebaseLiveSync();
    }

    try {
      final FirebaseAccount? cloudAccount = await _firebaseSyncService
          .signInWithEmail(email: email, password: password);
      if (!mounted || cloudAccount == null) {
        return;
      }
      await _database.saveAccount(
        name: cloudAccount.name ?? email.split('@').first,
        email: email,
        password: password,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = false;
        _cloudSyncStatus = 'Synced with Firebase';
      });
      await _registerCurrentDeviceWithFirebase();
      await _pullInventoryFromFirebase();
      await _syncInventoryToFirebase();
      await _syncTransactionsToFirebase();
      await _pullTransactionsFromFirebase();
      _startFirebaseLiveSync();
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Local account cloud refresh failed',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _emailPasswordProviderBlocked = _isEmailPasswordProviderDisabledMessage(
          error.message,
        );
        _cloudSyncStatus = _cloudStatusForSyncError(error.message);
      });
    } catch (error, stackTrace) {
      _logCloudSyncIssue(
        'Unexpected local account cloud refresh failure',
        error,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cloudSyncStatus = 'Offline account';
      });
    }
  }

  Future<void> _completeLinkedAccountUnlock({
    required LocalAccount account,
    required String method,
  }) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _biometricSigningIn = false;
      _isGuestSession = false;
      _usernameController.text = account.email;
      _sessionEmail = account.email;
      _sessionPassword = account.password;
      _rememberedAccountEmail = account.email;
      _phoneLinkAccountEmail = account.email;
      _biometricUnlockPromptDismissed = true;
      _cloudSyncStatus = _cloudSyncEnabled ? method : 'Offline account';
      _screen = AppScreen.dashboard;
    });
    unawaited(
      _refreshCloudSessionForLocalAccount(account.email, account.password),
    );
    _toast('$method as ${account.email}.');
  }

  Future<bool> _signInWithBiometrics({
    bool automatic = false,
    bool enableAutoLogin = false,
  }) async {
    if (_authBusy) {
      return false;
    }

    final String? email =
        _activePhoneLinkEmail ?? await _database.getSetting(_phoneLinkEmailKey);
    if (!mounted) {
      return false;
    }
    if (email == null || email.isEmpty) {
      _toast(
        'Sign in once with Remember this device enabled to use biometric unlock.',
      );
      return false;
    }

    final bool authenticated = await _runBiometricChallenge(
      localizedReason: enableAutoLogin
          ? 'Confirm to enable biometric unlock for FruityVens.'
          : 'Use your phone sensor to unlock FruityVens.',
      automatic: automatic,
    );
    if (!mounted || !authenticated) {
      return false;
    }

    final LocalAccount? account = await _database.getAccountByEmail(email);
    if (!mounted) {
      return false;
    }
    if (account == null) {
      _toast('Remembered account not found. Sign in again.');
      return false;
    }

    if (enableAutoLogin) {
      await _saveBiometricAutoLogin(true);
      if (!mounted) {
        return false;
      }
      setState(() {
        _biometricUnlockPromptDismissed = true;
      });
      _toast('Biometric unlock enabled for this phone.');
      return true;
    }

    await _completeLinkedAccountUnlock(
      account: account,
      method: 'Unlocked with biometrics',
    );
    return true;
  }

  Future<bool> _runBiometricChallenge({
    required String localizedReason,
    bool automatic = false,
  }) async {
    if (_biometricSigningIn) {
      return false;
    }

    setState(() {
      _biometricSigningIn = true;
    });

    try {
      final bool supported = await _localAuth.isDeviceSupported();
      final bool canCheckBiometrics = await _localAuth.canCheckBiometrics;
      if (!mounted) {
        return false;
      }
      if (!supported || !canCheckBiometrics) {
        setState(() {
          _biometricSigningIn = false;
        });
        if (!automatic) {
          _toast('Biometric unlock is not available on this phone.');
        }
        return false;
      }

      final bool authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (!mounted) {
        return false;
      }
      setState(() {
        _biometricSigningIn = false;
      });
      if (!authenticated && !automatic) {
        _toast('Biometric unlock cancelled.');
      }
      return authenticated;
    } on PlatformException {
      if (!mounted) {
        return false;
      }
      setState(() {
        _biometricSigningIn = false;
      });
      if (!automatic) {
        _toast('Biometric unlock is unavailable right now.');
      }
      return false;
    } catch (_) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _biometricSigningIn = false;
      });
      if (!automatic) {
        _toast('Biometric unlock could not start.');
      }
      return false;
    }
  }

  Future<void> _promptLinkPhoneIfNeeded({bool force = false}) async {
    if (!mounted ||
        _isGuestSession ||
        _biometricPromptOpen ||
        _screen == AppScreen.login) {
      return;
    }

    final String? email =
        _sessionEmail ??
        (_screen == AppScreen.login ? null : _rememberedAccountEmail);
    if (!mounted || email == null || email.isEmpty) {
      return;
    }
    final String cleanEmail = email.trim().toLowerCase();
    final String? pinSecret = await _database.getSetting(_phoneLinkPinKey);
    if (!mounted) {
      return;
    }
    if (!force &&
        _phoneLinkEnabled &&
        _phoneLinkBelongsTo(cleanEmail) &&
        pinSecret != null &&
        pinSecret.isNotEmpty) {
      return;
    }
    final LocalAccount? account = await _database.getAccountByEmail(email);
    if (!mounted || account == null) {
      return;
    }

    _biometricPromptOpen = true;
    try {
      final _PhoneLinkSetup? setup = await _showPhoneLinkSetupDialog(
        cleanEmail,
      );
      if (!mounted || setup == null) {
        return;
      }

      bool biometricsEnabled = false;
      if (setup.useBiometrics) {
        biometricsEnabled = await _confirmBiometricsForPhoneLink();
        if (!mounted) {
          return;
        }
      }

      await _savePhoneLink(
        email: cleanEmail,
        pin: setup.pin,
        biometricsEnabled: biometricsEnabled,
      );
      _toast(
        biometricsEnabled
            ? 'Phone linked. FruityVens will unlock with biometrics, with PIN as backup.'
            : 'Phone linked. Use your 6-digit PIN to unlock on this phone.',
      );
    } finally {
      _biometricPromptOpen = false;
    }
  }

  Future<_PhoneLinkSetup?> _showPhoneLinkSetupDialog(String email) async {
    return Navigator.of(context).push<_PhoneLinkSetup>(
      MaterialPageRoute<_PhoneLinkSetup>(
        fullscreenDialog: true,
        builder: (BuildContext context) {
          return _PhoneLinkSetupScreen(email: email);
        },
      ),
    );
  }

  // ignore: unused_element
  Future<_PhoneLinkSetup?> _unusedLegacyPhoneLinkSetupDialog(
    String email,
  ) async {
    final TextEditingController pinController = TextEditingController();
    final TextEditingController confirmController = TextEditingController();
    bool useBiometrics = true;
    String? errorText;

    final _PhoneLinkSetup? setup = await showDialog<_PhoneLinkSetup>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            void submit() {
              final String pin = pinController.text.trim();
              final String confirm = confirmController.text.trim();
              if (!_isValidPin(pin)) {
                setDialogState(() {
                  errorText = 'Enter a 6-digit PIN.';
                });
                return;
              }
              if (pin != confirm) {
                setDialogState(() {
                  errorText = 'PINs do not match.';
                });
                return;
              }
              Navigator.of(
                dialogContext,
              ).pop(_PhoneLinkSetup(pin: pin, useBiometrics: useBiometrics));
            }

            return AlertDialog(
              backgroundColor: AppColors.bgCard,
              title: Text('Link this phone'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Secure $email on this phone. Next time, FruityVens can unlock automatically with biometrics. If biometrics fails, use this PIN.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 14),
                  TextField(
                    controller: pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      letterSpacing: 4,
                    ),
                    decoration: appInputDecoration(
                      label: '6-digit PIN',
                      hint: '••••••',
                      prefixIcon: Icons.pin_rounded,
                    ).copyWith(counterText: ''),
                  ),
                  SizedBox(height: 10),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      letterSpacing: 4,
                    ),
                    onSubmitted: (_) => submit(),
                    decoration: appInputDecoration(
                      label: 'Confirm PIN',
                      hint: '••••••',
                      prefixIcon: Icons.verified_user_outlined,
                    ).copyWith(counterText: ''),
                  ),
                  SwitchListTile(
                    value: useBiometrics,
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppColors.palm,
                    title: Text(
                      'Use biometrics automatically',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      'PIN stays as backup.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    onChanged: (bool value) {
                      setDialogState(() {
                        useBiometrics = value;
                      });
                    },
                  ),
                  if (errorText != null) ...<Widget>[
                    SizedBox(height: 6),
                    Text(
                      errorText!,
                      style: TextStyle(color: AppColors.pinkText, fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('Not now'),
                ),
                TextButton(onPressed: submit, child: Text('Link phone')),
              ],
            );
          },
        );
      },
    );

    return setup;
  }

  Future<bool> _confirmBiometricsForPhoneLink() async {
    try {
      final bool supported = await _localAuth.isDeviceSupported();
      final bool canCheckBiometrics = await _localAuth.canCheckBiometrics;
      if (!supported || !canCheckBiometrics) {
        _toast('Biometrics are not available. PIN unlock is still linked.');
        return false;
      }
      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Confirm biometrics to link this phone.',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (!authenticated) {
        _toast('Biometrics skipped. PIN unlock is still linked.');
      }
      return authenticated;
    } on PlatformException {
      _toast('Biometrics are unavailable. PIN unlock is still linked.');
      return false;
    } catch (_) {
      _toast('Biometrics could not start. PIN unlock is still linked.');
      return false;
    }
  }

  Future<void> _autoUnlockPhoneLinkIfNeeded() async {
    if (!mounted ||
        _screen != AppScreen.login ||
        _isGuestSession ||
        _authBusy ||
        !_phoneLinkEnabled ||
        _biometricPromptOpen ||
        _biometricUnlockPromptDismissed ||
        _splashMounted) {
      return;
    }

    final LocalAccount? account = await _linkedAccount();
    if (!mounted) {
      return;
    }
    if (account == null) {
      await _forgetRememberedUnlock();
      return;
    }

    _biometricPromptOpen = true;
    try {
      bool unlocked = false;
      if (_biometricAutoLoginEnabled) {
        unlocked = await _signInWithBiometrics(automatic: true);
      }
      if (!mounted || unlocked || _screen != AppScreen.login) {
        return;
      }
      await _showPhoneLinkPinUnlockDialog(account);
    } finally {
      _biometricPromptOpen = false;
    }
  }

  Future<void> _showPhoneLinkPinUnlockDialog(LocalAccount account) async {
    final String? pinSecret = await _database.getSetting(_phoneLinkPinKey);
    if (!mounted || pinSecret == null || pinSecret.isEmpty) {
      return;
    }

    final String? action = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (BuildContext context) {
          return _PhoneLinkUnlockScreen(
            email: account.email,
            biometricsEnabled: _biometricAutoLoginEnabled,
            verifyPin: (String pin) => _verifyPinSecret(pin, pinSecret),
            onBiometricUnlock: () {
              return _runBiometricChallenge(
                localizedReason: 'Use your phone sensor to unlock FruityVens.',
              );
            },
          );
        },
      ),
    );

    if (!mounted) {
      return;
    }
    switch (action) {
      case 'unlock':
        await _completeLinkedAccountUnlock(
          account: account,
          method: 'Unlocked with PIN',
        );
        return;
      case 'biometric':
        await _completeLinkedAccountUnlock(
          account: account,
          method: 'Unlocked with biometrics',
        );
        return;
      case 'password':
        setState(() {
          _biometricUnlockPromptDismissed = true;
          _usernameController.text = account.email;
        });
        _toast('Enter your password to continue.');
        return;
      case 'switch':
        await _forgetRememberedUnlock();
        _toast('Choose another account to sign in.');
        return;
      default:
        _biometricUnlockPromptDismissed = true;
    }
  }

  // ignore: unused_element
  Future<void> _unusedLegacyPhoneLinkPinUnlockDialog(
    LocalAccount account,
  ) async {
    final String? pinSecret = await _database.getSetting(_phoneLinkPinKey);
    if (!mounted || pinSecret == null || pinSecret.isEmpty) {
      return;
    }

    final TextEditingController pinController = TextEditingController();
    String? errorText;
    final String? action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            void submitPin() {
              final String pin = pinController.text.trim();
              if (!_verifyPinSecret(pin, pinSecret)) {
                setDialogState(() {
                  errorText = 'Incorrect PIN.';
                });
                return;
              }
              Navigator.of(dialogContext).pop('unlock');
            }

            return AlertDialog(
              backgroundColor: AppColors.bgCard,
              title: Text('Unlock ${account.email}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Enter your 6-digit phone PIN to continue.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 14),
                  TextField(
                    controller: pinController,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      letterSpacing: 4,
                    ),
                    onSubmitted: (_) => submitPin(),
                    decoration: appInputDecoration(
                      label: 'Phone PIN',
                      hint: '••••••',
                      prefixIcon: Icons.pin_rounded,
                    ).copyWith(counterText: ''),
                  ),
                  if (errorText != null) ...<Widget>[
                    SizedBox(height: 6),
                    Text(
                      errorText!,
                      style: TextStyle(color: AppColors.pinkText, fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('switch'),
                  child: Text('Switch account'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('password'),
                  child: Text('Use password'),
                ),
                TextButton(onPressed: submitPin, child: Text('Unlock')),
              ],
            );
          },
        );
      },
    );

    if (!mounted) {
      return;
    }
    switch (action) {
      case 'unlock':
        await _completeLinkedAccountUnlock(
          account: account,
          method: 'Unlocked with PIN',
        );
        return;
      case 'password':
        setState(() {
          _biometricUnlockPromptDismissed = true;
          _usernameController.text = account.email;
        });
        _toast('Enter your password to continue.');
        return;
      case 'switch':
        await _forgetRememberedUnlock();
        _toast('Choose another account to sign in.');
        return;
      default:
        _biometricUnlockPromptDismissed = true;
    }
  }

  Future<void> _forgetRememberedUnlock() async {
    await _database.saveSetting(_rememberedEmailKey, '');
    await _database.saveSetting(_phoneLinkEmailKey, '');
    await _database.saveSetting(_biometricAutoLoginKey, 'false');
    await _database.saveSetting(_phoneLinkEnabledKey, 'false');
    await _database.saveSetting(_phoneLinkPinKey, '');
    if (!mounted) {
      return;
    }
    setState(() {
      _rememberedAccountEmail = null;
      _phoneLinkAccountEmail = null;
      _phoneLinkEnabled = false;
      _biometricAutoLoginEnabled = false;
      _biometricUnlockPromptDismissed = true;
      _usernameController.clear();
      _passwordController.clear();
    });
  }

  void _continueAsGuest() {
    _stopFirebaseLiveSync();
    unawaited(_database.saveSetting(_walkthroughSeenKey, 'true'));
    setState(() {
      _isGuestSession = true;
      _biometricUnlockPromptDismissed = true;
      _screen = AppScreen.dashboard;
      _walkthroughPage = 0;
    });
    _toast('Continuing in guest mode. Data stays on this device.');
  }

  void _forgotPassword() {
    final String username = _usernameController.text.trim().toLowerCase();
    setState(() {
      if (username.contains('@')) {
        _resetEmailController.text = username;
      }
      _resetSent = false;
      _screen = AppScreen.forgotPassword;
    });
  }

  Future<void> _signInWithGoogle() async {
    if (_authBusy) {
      return;
    }

    final bool online = await _hasInternetConnection();
    if (!mounted) {
      return;
    }
    if (!online) {
      _toast(
        'Google sign-in needs internet. Connect to the internet, then try again.',
      );
      return;
    }

    setState(() {
      _googleSigningIn = true;
      _rememberMe = true;
    });

    GoogleSignInAccount? googleAccount;
    String? googleIdToken;
    String? googleError;
    try {
      googleAccount = await _authenticateWithGoogle();
      googleIdToken = googleAccount.authentication.idToken;
    } catch (error) {
      googleError = error.toString();
    }

    final String fallbackEmail = _googleFallbackEmail();
    final String email = (googleAccount?.email ?? fallbackEmail)
        .trim()
        .toLowerCase();
    if (email.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _googleSigningIn = false;
      });
      _toast(
        'Google account picker is unavailable. Check Google sign-in setup or type an email for local fallback.',
      );
      return;
    }
    if (!_isValidEmail(email)) {
      if (!mounted) {
        return;
      }
      setState(() {
        _googleSigningIn = false;
      });
      _toast('Use a valid email address.');
      return;
    }
    if (googleAccount == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _googleSigningIn = false;
      });
      _toast(
        'Google account picker is unavailable. Check Google sign-in setup and try again.',
      );
      return;
    }

    FirebaseAccount? cloudAccount;
    String? cloudError;
    if (googleIdToken != null && googleIdToken.isNotEmpty) {
      try {
        cloudAccount = await _firebaseSyncService.signInWithGoogleIdToken(
          idToken: googleIdToken,
          fallbackEmail: email,
          fallbackName: googleAccount.displayName,
        );
      } on FirebaseSyncException catch (error, stackTrace) {
        _logCloudSyncIssue('Google Firebase sign-in failed', error, stackTrace);
        cloudError = error.message;
      }
    } else {
      cloudError = googleError;
    }

    if (!mounted) {
      return;
    }
    LocalAccount? account = await _database.getAccountByEmail(email);
    if (!mounted) {
      return;
    }
    final String accountName =
        cloudAccount?.name ??
        googleAccount.displayName ??
        _nameFromEmail(email);
    final bool createdLocalGoogleAccount = account == null;
    if (account == null) {
      final String? offlinePassword = await _promptGoogleOfflinePassword(
        email: email,
      );
      if (!mounted) {
        return;
      }
      if (offlinePassword == null) {
        await GoogleSignIn.instance.signOut();
        if (!mounted) {
          return;
        }
        setState(() {
          _googleSigningIn = false;
        });
        _toast('Create an offline password to finish Google account setup.');
        return;
      }
      await _database.saveAccount(
        name: accountName,
        email: email,
        password: offlinePassword,
      );
      account = await _database.getAccountByEmail(email);
      if (!mounted) {
        return;
      }
    }
    await _rememberAccountIfNeeded(email);
    if (!mounted) {
      return;
    }
    setState(() {
      _googleSigningIn = false;
      _isGuestSession = false;
      _emailPasswordProviderBlocked = false;
      _cloudSyncStatus = cloudAccount != null
          ? 'Signed in with Google'
          : 'Google account saved offline';
      _rememberedAccountEmail = email;
      _usernameController.text = email;
      _sessionEmail = email;
      _sessionPassword = account?.password;
      _screen = AppScreen.dashboard;
    });
    await _syncWhenInternetReturns();
    if (createdLocalGoogleAccount) {
      _toast(
        'Google account saved. Use your new password for offline sign-in.',
      );
    } else if (cloudError != null) {
      _toast('Signed in with Google. Cloud sync will resume when available.');
    } else {
      _toast('Signed in with Google as ${account?.name ?? email}.');
    }
    await _promptLinkPhoneIfNeeded();
  }

  String _googleFallbackEmail() {
    final String typedEmail = _usernameController.text.trim().toLowerCase();
    if (typedEmail.isNotEmpty) {
      return typedEmail;
    }
    return _rememberedAccountEmail ?? '';
  }

  Future<GoogleSignInAccount> _authenticateWithGoogle() async {
    _googleSignInInitialization ??= GoogleSignIn.instance.initialize(
      serverClientId: _googleServerClientId.isEmpty
          ? null
          : _googleServerClientId,
    );
    await _googleSignInInitialization;
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw UnsupportedError('Google account picker is unavailable here.');
    }
    return GoogleSignIn.instance.authenticate();
  }

  Future<String?> _promptGoogleOfflinePassword({required String email}) async {
    final TextEditingController passwordController = TextEditingController();
    final TextEditingController confirmController = TextEditingController();
    bool passwordVisible = false;
    String? errorText;

    final String? password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.bgCard,
              title: Text('Create offline password'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'This password lets $email sign in on this phone when there is no internet.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  SizedBox(height: 12),
                  AppTextField(
                    controller: passwordController,
                    label: 'Password',
                    hint: 'At least 6 characters',
                    obscureText: !passwordVisible,
                    prefixIcon: Icons.lock_outline_rounded,
                    suffix: IconButton(
                      tooltip: passwordVisible
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: () {
                        setDialogState(() {
                          passwordVisible = !passwordVisible;
                        });
                      },
                      icon: Icon(
                        passwordVisible
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                  SizedBox(height: 10),
                  AppTextField(
                    controller: confirmController,
                    label: 'Confirm password',
                    hint: 'Repeat password',
                    obscureText: !passwordVisible,
                    prefixIcon: Icons.verified_user_outlined,
                  ),
                  if (errorText != null) ...<Widget>[
                    SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: TextStyle(color: AppColors.pinkText, fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final String password = passwordController.text;
                    final String confirm = confirmController.text;
                    if (password.length < 6) {
                      setDialogState(() {
                        errorText = 'Password must be at least 6 characters.';
                      });
                      return;
                    }
                    if (password != confirm) {
                      setDialogState(() {
                        errorText = 'Passwords do not match.';
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(password);
                  },
                  child: Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    unawaited(
      Future<void>.delayed(const Duration(seconds: 1)).then((_) {
        passwordController.dispose();
        confirmController.dispose();
      }),
    );
    return password;
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final List<bool> probes =
          await Future.wait(
            _internetProbeHosts.map(_canResolveInternetHost),
          ).timeout(
            const Duration(seconds: 3),
            onTimeout: () => const <bool>[false],
          );
      return probes.any((bool connected) => connected);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _canResolveInternetHost(String host) async {
    try {
      final List<InternetAddress> result = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 2));
      return result.any(
        (InternetAddress address) => address.rawAddress.isNotEmpty,
      );
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _createAccount() async {
    if (_authBusy) {
      return;
    }

    final String name = _signupNameController.text.trim();
    final String email = _signupEmailController.text.trim().toLowerCase();
    final String password = _signupPasswordController.text;
    final String confirm = _signupConfirmController.text;

    if (name.length < 2) {
      _toast('Enter your full name.');
      return;
    }
    if (!_isValidEmail(email)) {
      _toast('Use a valid email address.');
      return;
    }
    if (password.length < 6) {
      _toast('Create a password with at least 6 characters.');
      return;
    }
    if (password != confirm) {
      _toast('Passwords do not match.');
      return;
    }
    final bool accountExists = await _database.accountExists(email);
    if (!mounted) {
      return;
    }
    if (accountExists) {
      _toast('Account already exists. Sign in instead.');
      return;
    }

    setState(() {
      _creatingAccount = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 750));
    if (!mounted) {
      return;
    }

    FirebaseAccount? cloudAccount;
    String? cloudError;
    try {
      cloudAccount = await _firebaseSyncService.createAccount(
        name: name,
        email: email,
        password: password,
      );
    } on FirebaseSyncException catch (error, stackTrace) {
      _logCloudSyncIssue('Create Firebase account failed', error, stackTrace);
      cloudError = error.message;
    }

    await _database.saveAccount(name: name, email: email, password: password);
    if (!mounted) {
      return;
    }
    await _database.saveSetting(_rememberedEmailKey, email);
    if (!mounted) {
      return;
    }
    setState(() {
      _creatingAccount = false;
      _rememberMe = true;
      _isGuestSession = false;
      _emailPasswordProviderBlocked =
          cloudError != null &&
          _isEmailPasswordProviderDisabledMessage(cloudError);
      _cloudSyncStatus = cloudAccount == null
          ? (cloudError == null
                ? 'Offline account'
                : _cloudStatusForSyncError(cloudError))
          : 'Firebase account synced';
      _rememberedAccountEmail = email;
      _usernameController.text = email;
      _passwordController.text = password;
      _sessionEmail = email;
      _sessionPassword = password;
      _screen = AppScreen.dashboard;
    });
    await _syncWhenInternetReturns();
    _toast(
      cloudError == null
          ? 'Account created for $name.'
          : 'Offline account created. Cloud sync will resume when Firebase is ready.',
    );
    await _promptLinkPhoneIfNeeded();
  }

  Future<void> _sendPasswordReset() async {
    if (_authBusy) {
      return;
    }

    final String email = _resetEmailController.text.trim().toLowerCase();
    if (email.isEmpty) {
      _toast('Enter your account email.');
      return;
    }
    if (email.contains(' ') || !email.contains('@')) {
      _toast('Use a valid email address.');
      return;
    }

    setState(() {
      _sendingReset = true;
      _resetSent = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) {
      return;
    }

    if (_cloudSyncEnabled && !_isGuestSession) {
      try {
        await _firebaseSyncService.sendPasswordReset(email);
      } on FirebaseSyncException catch (error, stackTrace) {
        _logCloudSyncIssue(
          'Password reset Firebase request failed',
          error,
          stackTrace,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _sendingReset = false;
        });
        _toast(error.message);
        return;
      }
    } else {
      final LocalAccount? account = await _database.getAccountByEmail(email);
      if (!mounted) {
        return;
      }
      if (account == null) {
        setState(() {
          _sendingReset = false;
        });
        _toast('No FruityVens account found for that email.');
        return;
      }
    }

    setState(() {
      _sendingReset = false;
      _resetSent = true;
    });
    _toast('Password reset instructions sent to $email.');
  }

  bool _isValidEmail(String email) {
    final String cleanEmail = email.trim().toLowerCase();
    return cleanEmail.isNotEmpty &&
        !cleanEmail.contains(' ') &&
        RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(cleanEmail);
  }

  String _nameFromEmail(String email) {
    final String localPart = email.split('@').first;
    final List<String> words = localPart
        .split(RegExp(r'[._-]+'))
        .where((String word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return 'FruityVens User';
    }
    return words
        .map(
          (String word) =>
              '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  void _toast(String message, {String? actionLabel, VoidCallback? onAction}) {
    final ScaffoldMessengerState? messenger =
        fruityVensMessengerKey.currentState;
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.bgRaised,
          action: actionLabel == null || onAction == null
              ? null
              : SnackBarAction(
                  label: actionLabel,
                  textColor: Colors.white,
                  onPressed: onAction,
                ),
        ),
      );
  }

  void _adjustPrice(String fruit, int delta) {
    if (_isGuestSession) {
      _showFullAccessRequired('Pricing');
      return;
    }
    final int currentPrice = _editablePriceFor(fruit);
    _draftPrices[fruit] = currentPrice <= 0 && delta < 0
        ? 0
        : math.max(0, currentPrice + delta);
    _syncPriceInputController(fruit);
  }

  void _setTypedPrice(String fruit, String value) {
    if (_isGuestSession) {
      return;
    }
    if (value.trim().isEmpty) {
      _draftPrices[fruit] = 0;
      return;
    }
    final int? parsed = _parsePriceInputCentavos(value);
    if (parsed == null) {
      return;
    }
    _draftPrices[fruit] = parsed;
  }

  Future<void> _saveInventoryFruit(String fruit) async {
    if (_isGuestSession) {
      _showFullAccessRequired('Pricing');
      return;
    }
    final int price = _editablePriceFor(fruit);
    if (price <= 0) {
      _toast('Set $fruit price per kg first.');
      return;
    }
    final LocalFruit? existingFruit = await _database.getManagedFruit(fruit);
    final int oldPrice = existingFruit?.price ?? 0;
    final bool confirmed = await _confirmSuspiciousPriceChange(
      fruit: fruit,
      oldPrice: oldPrice,
      newPrice: price,
    );
    if (!confirmed) {
      return;
    }
    final bool wasConfigured = _configuredPriceFruits.contains(fruit);
    final bool hasPriceConflict = _priceConflictFruits.contains(fruit);
    if (existingFruit != null &&
        oldPrice == price &&
        !existingFruit.dirty &&
        wasConfigured &&
        !hasPriceConflict) {
      _draftPrices.remove(fruit);
      _syncPriceInputController(fruit);
      _toast('$fruit is already saved at ${money(price)}/kg.');
      return;
    }
    final int preservedStock = _stocks[fruit] ?? 0;
    final _RestockSignal signal = _restockSignalForFruit(fruit);
    await _database.updateFruitInventory(
      name: fruit,
      price: price,
      stock: preservedStock,
    );
    await _database.saveSetting(_inventoryPriceConfiguredKey(fruit), '1');
    if (mounted) {
      setState(() {
        _prices[fruit] = price;
        _draftPrices.remove(fruit);
        _configuredPriceFruits.add(fruit);
        _priceConflictFruits.remove(fruit);
        if (_priceConflictNotice?.startsWith('$fruit ') ?? false) {
          _priceConflictNotice = null;
        }
      });
    }
    await _recordPriceChange(
      fruit: fruit,
      oldPrice: oldPrice,
      newPrice: price,
      source: 'local',
      note: 'Manual price update.',
    );
    await _syncFruitToFirebase(fruit);
    await _loadPriceHistoryFromDatabase();
    _toast('$fruit saved at ${money(price)}/kg. ${signal.label}.');
  }

  Future<void> _addSelectedFruit() async {
    if (_isGuestSession) {
      _showFullAccessRequired('Catalog changes');
      return;
    }
    final String? fruit = _fruitToAdd;
    if (fruit == null || fruit.isEmpty) {
      _toast('Select a fruit first.');
      return;
    }
    if (!_scanReadyFruits.contains(fruit)) {
      _toast('$fruit is not in the fruit catalog.');
      return;
    }

    final int? price = _parsePriceInputCentavos(_newPriceController.text);
    if (price == null || price <= 0) {
      _toast('Enter the real price per kg first.');
      return;
    }
    final bool confirmed = await _confirmSuspiciousPriceChange(
      fruit: fruit,
      oldPrice: 0,
      newPrice: price,
    );
    if (!confirmed) {
      return;
    }
    final FruitInfo info = _catalog[fruit]!;
    final int savedPrice = math.max(1, price);
    final int savedStock = _stocks[fruit] ?? 0;

    setState(() {
      if (!_managedFruits.contains(fruit)) {
        _managedFruits.add(fruit);
      }
      _prices[fruit] = savedPrice;
      _draftPrices.remove(fruit);
      _stocks[fruit] = savedStock;
      _configuredPriceFruits.add(fruit);
      _fruitToAdd = null;
      _expandedInventoryFruit = fruit;
      _newPriceController.clear();
      _priceConflictFruits.remove(fruit);
    });
    await _database.saveManagedFruit(
      name: fruit,
      iconKey: info.icon.codePoint.toString(),
      price: savedPrice,
      stock: savedStock,
    );
    await _database.saveSetting(_inventoryPriceConfiguredKey(fruit), '1');
    await _recordPriceChange(
      fruit: fruit,
      oldPrice: 0,
      newPrice: savedPrice,
      source: 'local',
      note: 'Added catalog fruit.',
    );
    await _loadInventoryFromDatabase();
    await _loadPriceHistoryFromDatabase();
    await _syncFruitToFirebase(fruit);
    _toast('$fruit added to inventory.');
  }

  Future<void> _removeFruit(String fruit) async {
    if (_isGuestSession) {
      _showFullAccessRequired('Catalog changes');
      return;
    }
    setState(() {
      _managedFruits.remove(fruit);
      if (_fruitToAdd == fruit) {
        _fruitToAdd = null;
      }
      if (_expandedInventoryFruit == fruit) {
        _expandedInventoryFruit = null;
      }
      _configuredPriceFruits.remove(fruit);
      _draftPrices.remove(fruit);
    });
    _priceInputControllers.remove(fruit)?.dispose();
    _priceInputFocusNodes.remove(fruit)?.dispose();
    await _database.saveSetting(_inventoryPriceConfiguredKey(fruit), '0');
    await _database.hideManagedFruit(fruit);
    await _loadInventoryFromDatabase();
    if (_cloudSyncEnabled) {
      try {
        await _firebaseSyncService.removeFruit(fruit);
        if (!mounted) {
          return;
        }
        setState(() {
          _emailPasswordProviderBlocked = false;
          _cloudSyncStatus = 'Synced with Firebase';
        });
      } on FirebaseSyncException catch (error, stackTrace) {
        _logCloudSyncIssue('Remove fruit cloud sync failed', error, stackTrace);
        if (!mounted) {
          return;
        }
        setState(() {
          _emailPasswordProviderBlocked =
              _isEmailPasswordProviderDisabledMessage(error.message);
          _cloudSyncStatus = _cloudStatusForSyncError(error.message);
        });
      } catch (error, stackTrace) {
        _logCloudSyncIssue(
          'Unexpected remove fruit cloud sync failure',
          error,
          stackTrace,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _cloudSyncStatus = 'Firebase sync paused';
        });
      }
    }
  }

  Future<void> _connectCameraEye({bool showToast = true}) async {
    if (_cameraEyeBusy) {
      return;
    }

    setState(() {
      _cameraEyeBusy = true;
      _cameraEyeStatus = const CameraEyeStatus.connecting();
    });

    try {
      final CameraEyeStatus status = await _cameraEyeService.connect();
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = status;
      });
      if (showToast) {
        _toast(status.message);
      }
    } on CameraEyeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = CameraEyeStatus.error(error.message);
      });
      if (showToast) {
        _toast(error.message);
      }
    }
  }

  Future<void> _refreshCameraEye({bool showToast = true}) async {
    if (_cameraEyeBusy) {
      return;
    }
    setState(() {
      _cameraEyeBusy = true;
      _cameraEyeStatus = const CameraEyeStatus.checking();
    });

    try {
      final CameraEyeStatus status = await _cameraEyeService.status();
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = status;
      });
      if (showToast) {
        _toast(status.message);
      }
    } on CameraEyeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = CameraEyeStatus.error(error.message);
      });
      if (showToast) {
        _toast(error.message);
      }
    }
  }

  Future<void> _releaseCameraEyeRoute({bool showToast = true}) async {
    if (_cameraEyeBusy) {
      return;
    }
    setState(() {
      _cameraEyeBusy = true;
    });

    try {
      final CameraEyeStatus status = await _cameraEyeService.releaseRoute();
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = status;
      });
      if (showToast) {
        _toast(status.message);
      }
    } on CameraEyeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraEyeBusy = false;
        _cameraEyeStatus = CameraEyeStatus.error(error.message);
      });
      if (showToast) {
        _toast(error.message);
      }
    }
  }

  Future<void> _downloadData() async {
    if (_operationsOpen) {
      setState(() {
        _operationsOpen = false;
      });
    }
    if (_isGuestSession) {
      _showFullAccessRequired('Download Data');
      return;
    }
    if (_exportingReport) {
      return;
    }

    setState(() {
      _exportingReport = true;
    });
    try {
      final ReportExportResult result = await _reportExportService.export(
        _buildReportData(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _exportingReport = false;
      });
      if (!result.saved) {
        _toast('Report export cancelled.');
        return;
      }
      _toast('Saved ${result.fileName} to the selected folder.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _exportingReport = false;
      });
      _toast('Report export failed: $error');
    }
  }

  ReportExportData _buildReportData() {
    final DateTime now = DateTime.now();
    final DashboardStats stats = _dashboardStats();
    final AnalyticsData analytics = _generateAnalytics(
      _selectedYear,
      _selectedMonth,
      _period,
    );
    final String forecastSummary =
        _latestAiForecast?.summary ??
        (stats.topFruitRanks.isEmpty
            ? 'No forecast generated yet.'
            : '${stats.topFruitRanks.first.name} currently leads sales.');

    return ReportExportData(
      generatedAt: now,
      dashboardMetrics: <ReportMetric>[
        ReportMetric(
          'Today sales',
          money(stats.salesTotal),
          '${stats.transactionCount} transactions',
          highlight: true,
        ),
        ReportMetric('Avg weight', stats.averageWeightLabel, 'Per transaction'),
        ReportMetric('Top fruit', stats.topFruit, 'Fastest seller'),
        ReportMetric('Camera', _cameraEyeStateLabel, 'Fruit scanning'),
      ],
      inventory: _managedFruits.map((String fruit) {
        final _RestockSignal signal = _restockSignalForFruit(
          fruit,
          stats: stats,
        );
        return ReportFruit(
          name: fruit,
          pricePerKg: _inventoryPriceIsConfigured(fruit)
              ? '${money(_prices[fruit] ?? 0)}/kg'
              : 'Unset',
          restockBasis: 'Sales-based',
          status: signal.label,
        );
      }).toList(),
      forecastSummary: forecastSummary,
      forecastRows: _reportForecastRows(stats),
      analytics: ReportAnalytics(
        chartTitle: analytics.chartTitle,
        labels: analytics.revenueLabels,
        series: analytics.revenueSeries,
        shareLabels: analytics.shareLabels,
        shareValues: analytics.shareValues.map(money).toList(),
      ),
      analyticsMetrics: <ReportMetric>[
        ReportMetric(
          'Revenue',
          analytics.revenue,
          analytics.periodLabel,
          highlight: true,
        ),
        ReportMetric('Units sold', analytics.unitsSold, 'Across all fruits'),
        ReportMetric(
          'Best seller',
          analytics.bestSeller,
          analytics.bestSellerRevenue,
        ),
        ReportMetric(
          'Average revenue',
          analytics.averageRevenue,
          analytics.averageLabel,
        ),
      ],
      transactions: _visibleTransactionHistory.map((
        TransactionData transaction,
      ) {
        return ReportTransaction(
          fruit: transaction.fruit,
          weight: transaction.weight,
          price: transaction.price,
          date: transaction.date,
          time: transaction.time,
          status: transaction.status,
        );
      }).toList(),
    );
  }

  List<ReportForecastRow> _reportForecastRows(DashboardStats stats) {
    if (stats.topFruitRanks.isEmpty) {
      return const <ReportForecastRow>[
        ReportForecastRow(
          name: 'No sales yet',
          value: 'Waiting for transactions',
          action: 'No action yet',
        ),
      ];
    }
    return stats.topFruitRanks.map((FruitRank rank) {
      final _RestockSignal signal = _restockSignalForFruit(
        rank.name,
        stats: stats,
      );
      return ReportForecastRow(
        name: rank.name,
        value: '${rank.weightLabel} sold today',
        action: signal.label,
      );
    }).toList();
  }

  Future<void> _generateAiForecast({bool quickAction = false}) async {
    if (_isGuestSession) {
      _generateDemoForecast(quickAction: quickAction);
      return;
    }
    if (_forecastGenerating) {
      return;
    }

    setState(() {
      _forecastGenerating = true;
      _latestAiError = null;
    });

    try {
      await _loadInventoryFromDatabase();
      await _loadTransactionsFromDatabase();
      await _syncWhenInternetReturns();
      if (!mounted) {
        return;
      }
      final DashboardStats stats = _dashboardStats();
      final AiAutomationResult result = await _aiAutomationClient
          .generateForecast(
            inventory: _managedFruits.map((String fruit) {
              return <String, Object?>{
                'name': fruit,
                'pricePerKgCentavos': _inventorySavedPrice(fruit) ?? 0,
                'pricePerKgPhp': ((_inventorySavedPrice(fruit) ?? 0) / 100),
                'currency': 'PHP',
                'priceConfigured': _inventoryPriceIsConfigured(fruit),
                'restockMode': 'sales_velocity',
              };
            }).toList(),
            salesSnapshot: <String, Object?>{
              'todaySalesCentavos': stats.salesTotal,
              'todaySalesPhp': stats.salesTotal / 100,
              'currency': 'PHP',
              'transactionsToday': stats.transactionCount,
              'averageWeightKg': stats.averageWeightKg,
              'topFruit': stats.topFruit,
              'period': 'next 7 days',
              'stockTracking': false,
            },
            cameraEye: <String, Object?>{
              'enabled': _cameraEyeStatus.connectedToAp,
              'streamReachable': _cameraEyeStatus.streamReachable,
              'ssid': CameraEyeService.ssid,
              'streamUrl': CameraEyeService.streamUrl,
              'probeUrl': _cameraEyeStatus.probeUrl,
              'processingModel': _fruitDetectionModel.title,
              'processingModelMode': _fruitDetectionModelMode,
              'processingModelId': _fruitDetectionModel.id,
              'processingModelAsset': _fruitDetectionModel.assetPath,
              'deviceTier': _deviceTierName,
              'mode': 'LAN snapshot preview through ESP32-CAM',
            },
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _forecastGenerating = false;
        _latestAiForecast = result;
        _latestAiError = null;
      });
      _toast(
        'AI forecast generated.',
        actionLabel: quickAction ? 'View' : null,
        onAction: quickAction ? () => _show(AppScreen.forecast) : null,
      );
    } on AiAutomationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _forecastGenerating = false;
        _latestAiError = _forecastConnectionMessage(error.message);
      });
      _toast(_latestAiError!);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _forecastGenerating = false;
        _latestAiError = _forecastConnectionMessage(error.toString());
      });
      _toast(_latestAiError!);
    }
  }

  void _generateDemoForecast({bool quickAction = false}) {
    if (_forecastGenerating) {
      return;
    }
    final DashboardStats stats = _dashboardStats();
    final List<FruitRank> ranks = stats.topFruitRanks;
    final String leader = ranks.isEmpty
        ? 'your first seller'
        : ranks.first.name;
    final String second = ranks.length > 1 ? ranks[1].name : 'the next runner';
    final String summary = ranks.isEmpty
        ? 'Demo forecast generated from sample sales. Create an account to forecast with your own sales.'
        : 'Demo forecast generated from sample sales. $leader should receive the heaviest restock, $second can use a medium top-up, and the third-ranked fruit only needs a light refill.';
    setState(() {
      _latestAiForecast = AiAutomationResult(
        summary: summary,
        model: 'Local sample forecast',
        source: 'Demo Mode',
      );
      _latestAiError = null;
    });
    _toast(
      'Demo forecast generated.',
      actionLabel: quickAction ? 'View' : null,
      onAction: quickAction ? () => _show(AppScreen.forecast) : null,
    );
  }

  _RestockSignal _restockSignalForFruit(String fruit, {DashboardStats? stats}) {
    final List<FruitRank> ranks = (stats ?? _dashboardStats()).topFruitRanks;
    final int index = ranks.indexWhere((FruitRank rank) => rank.name == fruit);
    return _restockSignalForRankIndex(index);
  }

  _RestockSignal _restockSignalForRankIndex(int index) {
    if (index == 0) {
      return _RestockSignal(
        label: 'Heavy restock',
        detail: 'Top seller today. Prepare the largest refill.',
        badge: StatusBadge.red('Heavy'),
      );
    }
    if (index == 1) {
      return _RestockSignal(
        label: 'Medium restock',
        detail: 'Strong movement. Add a steady refill.',
        badge: StatusBadge.orange('Medium'),
      );
    }
    if (index == 2) {
      return _RestockSignal(
        label: 'Light top-up',
        detail: 'Selling, but a lighter refill should be enough.',
        badge: StatusBadge.green('Light'),
      );
    }
    return _RestockSignal(
      label: 'No sales signal',
      detail: 'No restock signal yet. Sales will update this automatically.',
      badge: StatusBadge.blue('Watch'),
    );
  }

  List<_ForecastRecommendation> _forecastRecommendations(DashboardStats stats) {
    return stats.topFruitRanks.asMap().entries.map((
      MapEntry<int, FruitRank> entry,
    ) {
      final int rank = entry.key + 1;
      final FruitRank fruit = entry.value;
      return switch (rank) {
        1 => _ForecastRecommendation(
          fruitName: fruit.name,
          title: 'Heavy restock ${fruit.name}',
          detail:
              '${fruit.name} leads today with ${fruit.weightLabel} sold across ${fruit.transactions} sales.',
          value: fruit.weightLabel,
          note: 'Avg ${fruit.averageWeightLabel}/sale',
          badge: StatusBadge.red('Heavy'),
        ),
        2 => _ForecastRecommendation(
          fruitName: fruit.name,
          title: 'Medium restock ${fruit.name}',
          detail:
              '${fruit.name} is the second strongest seller. Prepare a steady refill for demand.',
          value: fruit.weightLabel,
          note: 'Avg ${fruit.averageWeightLabel}/sale',
          badge: StatusBadge.orange('Medium'),
        ),
        _ => _ForecastRecommendation(
          fruitName: fruit.name,
          title: 'Light top-up ${fruit.name}',
          detail:
              '${fruit.name} is moving, but a lighter refill should be enough for the next round.',
          value: fruit.weightLabel,
          note: 'Avg ${fruit.averageWeightLabel}/sale',
          badge: StatusBadge.green('Light'),
        ),
      };
    }).toList();
  }

  String _forecastConnectionMessage(String error) {
    final String cleanError = error.toLowerCase();
    developer.log('Forecast unavailable: $error', name: 'FruityVensAI');
    if (cleanError.contains('firebasevertexai.googleapis.com') ||
        cleanError.contains('service api') ||
        cleanError.contains('api is not enabled') ||
        cleanError.contains('get started')) {
      return 'Firebase AI Logic is not enabled for this project yet. Open Firebase Console > AI Logic, click Get started, wait a few minutes, then try Generate again.';
    }
    if (cleanError.contains('api_key_invalid') ||
        cleanError.contains('invalid api key') ||
        cleanError.contains('api key not valid') ||
        cleanError.contains('api key')) {
      return 'Firebase AI is blocked by the Android app config. Verify the Android app in Firebase and use the latest google-services.json.';
    }
    if (cleanError.contains('app check') ||
        cleanError.contains('appcheck') ||
        cleanError.contains('attestation') ||
        cleanError.contains('permission_denied') ||
        cleanError.contains('permission denied') ||
        cleanError.contains('unauthorized') ||
        cleanError.contains('403')) {
      return 'Firebase AI is blocked by App Check or API permissions. Register this Android app in App Check, or keep AI Logic App Check enforcement off while testing.';
    }
    if (cleanError.contains('quota') ||
        cleanError.contains('resource_exhausted')) {
      return 'Firebase AI quota is currently exhausted. Try again later or check Firebase AI Logic usage limits.';
    }
    if (cleanError.contains('user location is not supported')) {
      return 'Firebase AI is not available from this location. Forecasting needs a supported AI Logic region.';
    }
    if (cleanError.contains('not reachable') ||
        cleanError.contains('socket') ||
        cleanError.contains('timeout') ||
        cleanError.contains('connection') ||
        cleanError.contains('network') ||
        cleanError.contains('internet')) {
      return 'FruityVens could not reach Firebase AI. If your internet is already on, check Firebase AI Logic or App Check setup, then try Generate again.';
    }
    return 'Forecasting is unavailable right now. Check Firebase AI setup or your connection, then try again.';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _handleSystemBack();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: _KeyboardStableViewport(
          child: Stack(
            children: <Widget>[
              SafeArea(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: math.min(920, constraints.maxWidth),
                        height: constraints.maxHeight,
                        child: _screenShell(),
                      ),
                    );
                  },
                ),
              ),
              if (_screen != AppScreen.walkthrough &&
                  _screen != AppScreen.login &&
                  _screen != AppScreen.createAccount &&
                  _screen != AppScreen.forgotPassword)
                _operationsSidePanelOverlay(),
              if (_phoneUnlockGateVisible)
                Positioned.fill(
                  child: _PhoneUnlockGate(
                    email: _activePhoneLinkEmail,
                    biometricsEnabled: _biometricAutoLoginEnabled,
                  ),
                ),
              if (_splashMounted)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_splashVisible,
                    child: AnimatedOpacity(
                      opacity: _splashVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      child: const FloatingGlassSplash(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screenShell() {
    final Widget? fixedNav = _fixedScreenNav();
    final EdgeInsets contentPadding = fixedNav == null
        ? const EdgeInsets.fromLTRB(16, 16, 16, 32)
        : const EdgeInsets.fromLTRB(16, 14, 16, 32);

    final Widget scrollableContent = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: contentPadding,
      child: _buildScreen(),
    );
    final Widget screenContent = _screenSupportsPullRefresh
        ? RefreshIndicator.adaptive(
            color: AppColors.orange,
            backgroundColor: AppColors.bgCard,
            displacement: fixedNav == null ? 40 : 24,
            onRefresh: _refreshCurrentScreen,
            child: scrollableContent,
          )
        : scrollableContent;

    if (fixedNav == null) {
      return screenContent;
    }

    return Column(
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          decoration: BoxDecoration(
            color: AppColors.bgBase,
            border: Border(
              bottom: BorderSide(color: AppColors.borderSoft, width: 0.5),
            ),
          ),
          child: fixedNav,
        ),
        Expanded(child: screenContent),
      ],
    );
  }

  Widget? _fixedScreenNav() {
    switch (_screen) {
      case AppScreen.inventory:
        return _inventoryNav();
      case AppScreen.inventoryManage:
        return _inventoryManageNav();
      case AppScreen.forecast:
        return _forecastNav();
      case AppScreen.analytics:
        return _analyticsNav();
      case AppScreen.transactions:
        return _historyNav();
      case AppScreen.dashboard:
        return _dashboardNav();
      case AppScreen.walkthrough:
      case AppScreen.login:
      case AppScreen.createAccount:
      case AppScreen.forgotPassword:
        return null;
    }
  }

  Widget _inventoryNav() {
    return _centeredScreenNav(
      title: 'Inventory',
      onBack: () => _show(AppScreen.dashboard),
      trailing: <Widget>[
        _topBarIconButton(
          tooltip: 'Manage fruits',
          icon: Icons.tune_rounded,
          onPressed: () => _show(AppScreen.inventoryManage),
        ),
      ],
    );
  }

  Widget _inventoryManageNav() {
    return _centeredScreenNav(
      title: 'Manage fruits',
      onBack: () => _show(AppScreen.inventory),
      trailing: <Widget>[
        _topBarIconButton(
          tooltip: 'Done managing fruits',
          icon: Icons.check_rounded,
          highlighted: true,
          onPressed: () => _show(AppScreen.inventory),
        ),
      ],
    );
  }

  Widget _forecastNav() {
    return _centeredScreenNav(
      title: 'Forecasting',
      onBack: () => _show(AppScreen.dashboard),
    );
  }

  Widget _operationsSidePanelOverlay() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double panelWidth = constraints.maxWidth * 0.75;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_operationsOpen,
                child: AnimatedOpacity(
                  opacity: _operationsOpen ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _operationsOpen = false;
                      });
                    },
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.28),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: _operationsOpen ? 0 : -panelWidth,
              top: 0,
              bottom: 0,
              width: panelWidth,
              child: SafeArea(
                right: false,
                child: Material(
                  color: AppColors.bgCard,
                  elevation: 18,
                  shadowColor: Colors.black.withValues(alpha: 0.5),
                  child: _operationsMenuPanel(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildScreen() {
    switch (_screen) {
      case AppScreen.walkthrough:
        return _walkthroughScreen();
      case AppScreen.login:
        return _loginScreen();
      case AppScreen.createAccount:
        return _createAccountScreen();
      case AppScreen.forgotPassword:
        return _forgotPasswordScreen();
      case AppScreen.dashboard:
        return _dashboardScreen();
      case AppScreen.inventory:
        return _inventoryScreen();
      case AppScreen.inventoryManage:
        return _inventoryManageScreen();
      case AppScreen.forecast:
        return _forecastScreen();
      case AppScreen.analytics:
        return _analyticsScreen();
      case AppScreen.transactions:
        return _transactionHistoryScreen();
    }
  }

  Widget _walkthroughScreen() {
    final int page = math.min(
      math.max(_walkthroughPage, 0),
      _walkthroughSteps.length - 1,
    );
    final _WalkthroughStep step = _walkthroughSteps[page];
    final bool isLast = page == _walkthroughSteps.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => unawaited(_completeWalkthrough()),
                  child: Text('Skip'),
                ),
              ),
              SizedBox(height: 8),
              const BrandMark(size: 62),
              SizedBox(height: 14),
              Text(
                'FruityVens',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'A local-first fruit vending companion.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: AppCard(
                  key: ValueKey<int>(page),
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: <Widget>[
                      Container(
                        width: 82,
                        height: 82,
                        decoration: BoxDecoration(
                          color: AppColors.orangeDim,
                          border: Border.all(
                            color: AppColors.borderStrong,
                            width: 0.8,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          step.icon,
                          color: AppColors.orangeText,
                          size: 38,
                        ),
                      ),
                      SizedBox(height: 20),
                      Text(
                        step.title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        step.body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                          height: 1.55,
                        ),
                      ),
                      SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: step.points.map(_walkthroughPill).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List<Widget>.generate(_walkthroughSteps.length, (
                  int index,
                ) {
                  final bool selected = index == page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: selected ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: selected ? AppColors.orange : AppColors.borderMid,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  );
                }),
              ),
              SizedBox(height: 22),
              Row(
                children: <Widget>[
                  if (page > 0)
                    Expanded(
                      child: GhostButton(
                        label: 'Back',
                        icon: Icons.chevron_left_rounded,
                        onPressed: _previousWalkthroughStep,
                      ),
                    )
                  else
                    const Spacer(),
                  SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: PrimaryButton(
                      label: isLast ? 'Get started' : 'Next',
                      icon: isLast
                          ? Icons.arrow_forward_rounded
                          : Icons.chevron_right_rounded,
                      expanded: true,
                      onPressed: _nextWalkthroughStep,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              GhostButton(
                label: 'Try demo',
                icon: Icons.play_circle_outline_rounded,
                highlighted: true,
                onPressed: () =>
                    unawaited(_completeWalkthrough(startGuest: true)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _walkthroughPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.borderMid, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.orangeText,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _loginScreen() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandMark(size: 58),
              SizedBox(height: 14),
              Text(
                'FruityVens',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Fruit weighing, pricing, forecasting, and analytics.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.5,
                  fontSize: 12,
                ),
              ),
              SizedBox(height: 26),
              AppCard(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  children: <Widget>[
                    Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: AppColors.orange,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                      ),
                    ),
                    SizedBox(height: 18),
                    AppTextField(
                      controller: _usernameController,
                      label: 'Vendor or student email',
                      hint: 'name@phinmaed.com',
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: Icons.alternate_email_rounded,
                      textInputAction: TextInputAction.next,
                    ),
                    SizedBox(height: 14),
                    AppTextField(
                      controller: _passwordController,
                      label: 'Password',
                      hint: 'Password',
                      obscureText: !_passwordVisible,
                      prefixIcon: Icons.lock_outline_rounded,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _signIn(),
                      suffix: IconButton(
                        tooltip: _passwordVisible
                            ? 'Hide password'
                            : 'Show password',
                        onPressed: () {
                          setState(() {
                            _passwordVisible = !_passwordVisible;
                          });
                        },
                        icon: Icon(
                          _passwordVisible
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: AppColors.textSecondary,
                          size: 20,
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Checkbox(
                          value: _rememberMe,
                          onChanged: (bool? value) {
                            setState(() {
                              _rememberMe = value ?? false;
                            });
                          },
                          activeColor: AppColors.palm,
                          checkColor: AppColors.bgBase,
                          side: BorderSide(color: AppColors.borderMid),
                          visualDensity: VisualDensity.compact,
                        ),
                        Expanded(
                          child: Text(
                            'Remember this device',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _forgotPassword,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.orangeText,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: Text('Forgot password?'),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    PrimaryButton(
                      label: _signingIn ? 'Signing in' : 'Sign in',
                      icon: Icons.login_rounded,
                      onPressed: _authBusy ? null : _signIn,
                      expanded: true,
                      busy: _signingIn,
                    ),
                    SizedBox(height: 10),
                    GoogleSignInButton(
                      label: _googleSigningIn
                          ? 'Connecting Google'
                          : 'Continue with Google',
                      onPressed: _authBusy ? null : _signInWithGoogle,
                      busy: _googleSigningIn,
                    ),
                    SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(child: Divider(color: AppColors.borderSoft)),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'OTHER OPTIONS',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Expanded(child: Divider(color: AppColors.borderSoft)),
                      ],
                    ),
                    SizedBox(height: 12),
                    GhostButton(
                      label: 'Guest Mode',
                      icon: Icons.person_outline_rounded,
                      onPressed: _authBusy ? null : _continueAsGuest,
                    ),
                    if (_rememberedAccountEmail != null) ...<Widget>[
                      SizedBox(height: 8),
                      Text(
                        'Remembered account: $_rememberedAccountEmail',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            "Don't have an account?",
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _show(AppScreen.createAccount),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.orangeText,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: Text('Create account'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 14),
              Text(
                'Phinma Education Cagayan De Oro',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _forgotPasswordScreen() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 410),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandMark(size: 54),
              SizedBox(height: 12),
              Text(
                'Reset Password',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'Enter the email connected to your FruityVens account.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
              SizedBox(height: 20),
              AppCard(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: AppColors.orange,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    const SectionLabel('Account recovery'),
                    SizedBox(height: 10),
                    AppTextField(
                      controller: _resetEmailController,
                      label: 'Account email',
                      hint: 'name@phinmaed.com',
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: Icons.alternate_email_rounded,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _sendPasswordReset(),
                    ),
                    SizedBox(height: 12),
                    PrimaryButton(
                      label: _sendingReset
                          ? 'Sending'
                          : 'Send reset instructions',
                      icon: Icons.mark_email_read_rounded,
                      onPressed: _authBusy ? null : _sendPasswordReset,
                      expanded: true,
                      busy: _sendingReset,
                    ),
                    if (_resetSent) ...<Widget>[
                      SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.palm.withValues(alpha: 0.13),
                          border: Border.all(
                            color: AppColors.palm.withValues(alpha: 0.35),
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Reset instructions are ready for ${_resetEmailController.text.trim().toLowerCase()}.',
                          style: TextStyle(
                            color: AppColors.greenText,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => _show(AppScreen.login),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.orangeText,
                ),
                icon: Icon(Icons.arrow_back_rounded, size: 18),
                label: Text('Back to sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _createAccountScreen() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandMark(size: 54),
              SizedBox(height: 12),
              Text(
                'Create FruityVens Account',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'Register with your PHINMAEd Gmail or any valid email address.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
              SizedBox(height: 20),
              AppCard(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: AppColors.orange,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    _createAccountPanel(),
                  ],
                ),
              ),
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    'Already have an account?',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _show(AppScreen.login),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.orangeText,
                    ),
                    child: Text('Sign in'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _createAccountPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('Create account'),
          SizedBox(height: 10),
          GoogleSignInButton(
            label: _googleSigningIn
                ? 'Opening Google'
                : 'Create or continue with Google',
            onPressed: _authBusy ? null : _signInWithGoogle,
            busy: _googleSigningIn,
          ),
          SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: Divider(color: AppColors.borderSoft)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'OR USE EMAIL',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(child: Divider(color: AppColors.borderSoft)),
            ],
          ),
          SizedBox(height: 12),
          AppTextField(
            controller: _signupNameController,
            label: 'Full name',
            hint: 'Juan Dela Cruz',
            prefixIcon: Icons.person_outline_rounded,
            textInputAction: TextInputAction.next,
          ),
          SizedBox(height: 10),
          AppTextField(
            controller: _signupEmailController,
            label: 'Email address',
            hint: 'student@phinmaed.com or name@email.com',
            keyboardType: TextInputType.emailAddress,
            prefixIcon: Icons.alternate_email_rounded,
            textInputAction: TextInputAction.next,
          ),
          SizedBox(height: 10),
          AppTextField(
            controller: _signupPasswordController,
            label: 'Password',
            hint: 'At least 6 characters',
            obscureText: !_signupPasswordVisible,
            prefixIcon: Icons.lock_outline_rounded,
            textInputAction: TextInputAction.next,
            suffix: IconButton(
              tooltip: _signupPasswordVisible
                  ? 'Hide password'
                  : 'Show password',
              onPressed: () {
                setState(() {
                  _signupPasswordVisible = !_signupPasswordVisible;
                });
              },
              icon: Icon(
                _signupPasswordVisible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ),
          ),
          SizedBox(height: 10),
          AppTextField(
            controller: _signupConfirmController,
            label: 'Confirm password',
            hint: 'Repeat password',
            obscureText: !_signupPasswordVisible,
            prefixIcon: Icons.verified_user_outlined,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _createAccount(),
          ),
          SizedBox(height: 12),
          PrimaryButton(
            label: _creatingAccount ? 'Creating account' : 'Create account',
            icon: Icons.person_add_alt_rounded,
            onPressed: _authBusy ? null : _createAccount,
            expanded: true,
            busy: _creatingAccount,
          ),
          SizedBox(height: 8),
          Text(
            'PHINMAEd Gmail and personal email accounts work offline first and sync with Firebase when available.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dashboardScreen() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _dashboardSalesOverview(),
        SizedBox(height: 12),
        if (_isGuestSession) ...<Widget>[
          _guestAccessBanner(),
          SizedBox(height: 12),
        ],
        _recentTransactionsPreview(),
      ],
    );
  }

  Widget _dashboardSalesOverview() {
    final DashboardStats stats = _dashboardStats();
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 640;
          final Widget salesBlock = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  Text(
                    'Dashboard',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  StatusBadge.green(_cloudSyncStatus ?? 'Offline mode'),
                ],
              ),
              SizedBox(height: 12),
              Text(
                money(stats.salesTotal),
                style: TextStyle(
                  color: AppColors.orangeText,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 3),
              Text(
                stats.salesSubtext,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          );

          final Widget topRanking = TopFruitRanking(ranks: stats.topFruitRanks);

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[salesBlock, SizedBox(height: 14), topRanking],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(child: salesBlock),
              SizedBox(width: 12),
              SizedBox(width: 300, child: topRanking),
            ],
          );
        },
      ),
    );
  }

  Widget _guestAccessBanner() {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.lock_outline_rounded,
              color: AppColors.orangeText,
              size: 20,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Guest Mode uses sample sales for previews. Create an account for reports and sync.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
          SizedBox(width: 8),
          GhostButton(
            label: 'Create',
            icon: Icons.person_add_alt_rounded,
            highlighted: true,
            onPressed: () => _show(AppScreen.createAccount),
          ),
        ],
      ),
    );
  }

  Widget _operationsMenuPanel() {
    return Container(
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        border: Border(
          right: BorderSide(color: AppColors.borderStrong, width: 0.5),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: SectionLabel('Menu')),
                IconButton(
                  tooltip: 'Close operations menu',
                  onPressed: () {
                    setState(() {
                      _operationsOpen = false;
                    });
                  },
                  icon: Icon(
                    Icons.close_rounded,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
            _operationMenuAction(
              icon: Icons.inventory_2_rounded,
              title: 'Inventory',
              description: 'Fruits, prices, and restock signals',
              onTap: () => _show(AppScreen.inventory),
            ),
            _operationMenuAction(
              icon: Icons.monitor_heart_rounded,
              title: 'Generate forecast',
              description: _isGuestSession
                  ? 'Sample demand preview'
                  : 'AI demand and restock advice',
              onTap: () => _show(AppScreen.forecast),
            ),
            _operationMenuAction(
              icon: Icons.bar_chart_rounded,
              title: 'View analytics',
              description: _isGuestSession
                  ? 'Sample sales preview'
                  : 'Sales and revenue patterns',
              onTap: () => _show(AppScreen.analytics),
            ),
            _operationMenuAction(
              icon: Icons.receipt_long_rounded,
              title: 'History',
              description: 'All transaction records',
              onTap: () => _show(AppScreen.transactions),
            ),
            _operationMenuAction(
              icon: Icons.settings_rounded,
              title: 'Account Settings',
              description: _isGuestSession
                  ? 'Create an account to unlock'
                  : 'Biometrics, security, and AI model',
              locked: _isGuestSession,
              onTap: _openAccountSettings,
            ),
            _operationMenuAction(
              icon: Icons.download_rounded,
              title: _exportingReport ? 'Preparing report' : 'Download Data',
              description: _isGuestSession
                  ? 'Create an account to unlock'
                  : 'PDF report with all app data',
              locked: _isGuestSession,
              onTap: _downloadData,
            ),
            Divider(color: AppColors.borderSoft, height: 18),
            _operationMenuAction(
              icon: Icons.logout_rounded,
              title: 'Logout',
              description: 'Switch or create another account',
              color: AppColors.pinkText,
              onTap: _signOut,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAccountSettings() async {
    if (_isGuestSession) {
      _showFullAccessRequired('Account Settings');
      return;
    }
    if (_operationsOpen && mounted) {
      setState(() {
        _operationsOpen = false;
      });
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            Widget modelTile(FruitDetectionModel model) {
              final bool selected = _fruitDetectionModelMode == model.id;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.palm.withValues(alpha: 0.12)
                      : AppColors.bgSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? AppColors.palm : AppColors.borderSoft,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    final bool changed = await _setFruitDetectionModel(
                      model.id,
                    );
                    if (changed && mounted) {
                      setDialogState(() {});
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: selected
                              ? AppColors.palm
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Icon(
                          _fruitDetectionModelIcon(model.id),
                          color: selected
                              ? AppColors.greenText
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      model.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  if (model.recommended)
                                    StatusBadge.green('BEST')
                                  else
                                    StatusBadge.blue(model.precision),
                                ],
                              ),
                              SizedBox(height: 3),
                              Text(
                                model.description,
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            Widget autoModelTile() {
              final bool selected =
                  _fruitDetectionModelMode == _fruitDetectionAutoMode;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.palm.withValues(alpha: 0.12)
                      : AppColors.bgSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? AppColors.palm : AppColors.borderSoft,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    final bool changed = await _setFruitDetectionModel(
                      _fruitDetectionAutoMode,
                    );
                    if (changed && mounted) {
                      setDialogState(() {});
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: selected
                              ? AppColors.palm
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Icon(
                          Icons.phone_android_rounded,
                          color: selected
                              ? AppColors.greenText
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      'Auto phone check',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  StatusBadge.green(_fruitDetectionModel.title),
                                ],
                              ),
                              SizedBox(height: 3),
                              Text(
                                '${_deviceProfileSummary()} - Low uses INT8, mid uses Float16, high uses Best.',
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: AppColors.bgCard,
              title: Text('Account Settings'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.palm.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.fingerprint_rounded,
                              color: AppColors.greenText,
                              size: 20,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Linked phone unlock',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  _phoneLinkEnabled
                                      ? (_biometricAutoLoginEnabled
                                            ? 'Biometrics enabled, 6-digit PIN backup'
                                            : '6-digit PIN enabled for this phone')
                                      : 'Set up biometrics and a 6-digit PIN',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _phoneLinkEnabled,
                            onChanged: _authBusy
                                ? null
                                : (bool enabled) async {
                                    if (enabled) {
                                      await _promptLinkPhoneIfNeeded(
                                        force: true,
                                      );
                                    } else {
                                      await _forgetRememberedUnlock();
                                      _toast('Phone link disabled.');
                                    }
                                    if (mounted) {
                                      setDialogState(() {});
                                    }
                                  },
                            activeThumbColor: AppColors.palm,
                          ),
                        ],
                      ),
                      Divider(color: AppColors.borderSoft, height: 28),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.orange.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              AppColors.isLightTheme
                                  ? Icons.light_mode_rounded
                                  : Icons.dark_mode_rounded,
                              color: AppColors.orangeText,
                              size: 20,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Light theme',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  AppColors.isLightTheme
                                      ? 'Soft forest-floor colors for daytime selling.'
                                      : 'Dark mode keeps the current night-market look.',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: AppColors.isLightTheme,
                            onChanged: (bool enabled) => unawaited(
                              _setLightThemeEnabled(
                                enabled,
                                dialogSetState: setDialogState,
                              ),
                            ),
                            activeThumbColor: AppColors.palm,
                          ),
                        ],
                      ),
                      Divider(color: AppColors.borderSoft, height: 28),
                      Row(
                        children: <Widget>[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.orange.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              _fruitDetectionModelIcon(_fruitDetectionModel.id),
                              color: AppColors.orangeText,
                              size: 20,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Fruit AI model',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  '$_fruitDetectionModeLabel - ${_fruitDetectionModel.fileName}',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 6),
                      autoModelTile(),
                      for (final FruitDetectionModel model
                          in FruitDetectionService.builtInModels)
                        modelTile(model),
                      Divider(color: AppColors.borderSoft, height: 28),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.palm.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.scale_rounded,
                              color: AppColors.greenText,
                              size: 20,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Text(
                                        'Firebase scale sync',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    if (_scaleLogSyncRunning)
                                      StatusBadge.blue('CHECKING')
                                    else if (_scaleBaseUrl.isEmpty)
                                      StatusBadge.orange('OFF')
                                    else
                                      StatusBadge.green('ON'),
                                  ],
                                ),
                                SizedBox(height: 3),
                                Text(
                                  _scaleLogStatus,
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                                if (_lastScaleLogSyncAt != null) ...<Widget>[
                                  SizedBox(height: 2),
                                  Text(
                                    'Last checked ${_formatTime(_lastScaleLogSyncAt!)}',
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      AppTextField(
                        controller: _scaleBaseUrlController,
                        label: 'Scale device ID',
                        hint: 'fruityvens-scale-01',
                        keyboardType: TextInputType.text,
                        prefixIcon: Icons.badge_rounded,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => unawaited(
                          _saveScaleBaseUrl(dialogSetState: setDialogState),
                        ),
                      ),
                      SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: GhostButton(
                              label: 'Save',
                              icon: Icons.save_rounded,
                              onPressed: () => unawaited(
                                _saveScaleBaseUrl(
                                  dialogSetState: setDialogState,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: GhostButton(
                              label: 'Fetch Firebase',
                              icon: Icons.sync_rounded,
                              highlighted: true,
                              onPressed: _scaleLogSyncRunning
                                  ? null
                                  : () => unawaited(
                                      _fetchConfirmedScaleLogs(
                                        showToast: true,
                                      ).then((_) {
                                        if (mounted) {
                                          setDialogState(() {});
                                        }
                                      }),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _operationMenuAction({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
    bool locked = false,
    Color? color,
  }) {
    final Color effectiveColor = locked
        ? AppColors.textMuted
        : color ?? AppColors.greenText;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  locked ? Icons.lock_outline_rounded : icon,
                  color: effectiveColor,
                  size: 18,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (locked) StatusBadge.orange('LOCKED'),
                      ],
                    ),
                    SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentTransactionsPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Recent sales',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            GhostButton(
              label: 'View more',
              icon: Icons.receipt_long_rounded,
              highlighted: true,
              onPressed: () => _show(AppScreen.transactions),
            ),
          ],
        ),
        SizedBox(height: 10),
        if (_visibleTransactionHistory.isEmpty)
          _emptyStateCard(
            icon: Icons.receipt_long_rounded,
            title: 'No sales yet',
            detail: 'Sales will appear here.',
          )
        else
          ..._visibleTransactionHistory.take(5).map((
            TransactionData transaction,
          ) {
            return HistoryTransactionCard(transaction: transaction);
          }),
      ],
    );
  }

  Widget _emptyStateCard({
    required IconData icon,
    required String title,
    required String detail,
  }) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.palm.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.greenText, size: 20),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showTransactionActions(TransactionData transaction) async {
    if (_isGuestSession) {
      _showFullAccessRequired('History changes');
      return;
    }
    if (transaction.saleId == null) {
      _toast('This sale cannot be edited on this phone.');
      return;
    }

    final bool cancelled = transaction.status == 'Cancelled';
    final _TransactionHistoryAction?
    action = await showModalBottomSheet<_TransactionHistoryAction>(
      context: context,
      backgroundColor: AppColors.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: SectionTitle('Manage sale')),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${transaction.fruit} - ${transaction.weight} - ${transaction.price}',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                SizedBox(height: 10),
                ListTile(
                  leading: Icon(
                    cancelled ? Icons.restore_rounded : Icons.cancel_outlined,
                    color: cancelled
                        ? AppColors.greenText
                        : AppColors.orangeText,
                  ),
                  title: Text(cancelled ? 'Restore sale' : 'Cancel sale'),
                  subtitle: Text(
                    cancelled
                        ? 'Count this sale in analytics and restock signals again.'
                        : 'Keep it visible as Void, but exclude it from analytics and restock signals.',
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(
                    cancelled
                        ? _TransactionHistoryAction.restore
                        : _TransactionHistoryAction.cancel,
                  ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.pinkText,
                  ),
                  title: Text('Remove from history'),
                  subtitle: Text(
                    'Hide this sale from history, reports, analytics, and forecasts.',
                  ),
                  onTap: () => Navigator.of(
                    sheetContext,
                  ).pop(_TransactionHistoryAction.remove),
                ),
                ListTile(
                  leading: Icon(
                    Icons.check_circle_outline_rounded,
                    color: AppColors.textSecondary,
                  ),
                  title: Text(cancelled ? 'Keep as void' : 'Keep sale'),
                  subtitle: Text('Leave this transaction unchanged.'),
                  onTap: () => Navigator.of(
                    sheetContext,
                  ).pop(_TransactionHistoryAction.keep),
                ),
              ],
            ),
          ),
        );
      },
    );

    switch (action) {
      case _TransactionHistoryAction.cancel:
        await _updateTransactionStatus(
          transaction,
          status: 'cancelled',
          successMessage:
              '${transaction.fruit} sale marked void. Analytics updated.',
        );
        return;
      case _TransactionHistoryAction.restore:
        await _updateTransactionStatus(
          transaction,
          status: 'sold',
          successMessage: '${transaction.fruit} sale restored.',
        );
        return;
      case _TransactionHistoryAction.remove:
        final bool confirmed = await _confirmRemoveTransaction(transaction);
        if (!confirmed) {
          return;
        }
        await _updateTransactionStatus(
          transaction,
          status: 'removed',
          successMessage: '${transaction.fruit} sale removed from history.',
        );
        return;
      case _TransactionHistoryAction.keep:
      case null:
        return;
    }
  }

  Future<bool> _confirmRemoveTransaction(TransactionData transaction) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.bgCard,
          title: Text('Remove sale?'),
          content: Text(
            'This hides ${transaction.fruit} from history, analytics, forecasts, and reports. A removed sync record is kept so cloud sync will not add it back.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('Keep'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.pink,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Remove'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _updateTransactionStatus(
    TransactionData transaction, {
    required String status,
    required String successMessage,
  }) async {
    final int? saleId = transaction.saleId;
    if (saleId == null) {
      _toast('This sale cannot be edited on this phone.');
      return;
    }
    await _database.updateSaleStatus(id: saleId, status: status);
    await _loadTransactionsFromDatabase();
    unawaited(_syncTransactionsToFirebase());
    if (!mounted) {
      return;
    }
    _toast(successMessage);
  }

  DateTime get _historyFirstSelectableDate {
    final DateTime today = _historyDateOnly(DateTime.now());
    DateTime earliest = today;
    for (final TransactionData transaction in _visibleTransactionHistory) {
      final DateTime? day = _transactionHistoryDay(transaction);
      if (day != null && day.isBefore(earliest)) {
        earliest = day;
      }
    }
    return earliest;
  }

  DateTime get _historyLastSelectableDate {
    DateTime latest = _historyDateOnly(DateTime.now());
    for (final TransactionData transaction in _visibleTransactionHistory) {
      final DateTime? day = _transactionHistoryDay(transaction);
      if (day != null && day.isAfter(latest)) {
        latest = day;
      }
    }
    return latest;
  }

  DateTime _clampedHistoryDate(DateTime date) {
    final DateTime day = _historyDateOnly(date);
    final DateTime firstDate = _historyFirstSelectableDate;
    final DateTime lastDate = _historyLastSelectableDate;
    if (day.isBefore(firstDate)) {
      return firstDate;
    }
    if (day.isAfter(lastDate)) {
      return lastDate;
    }
    return day;
  }

  Future<void> _pickHistoryDate() async {
    final DateTime firstDate = _historyFirstSelectableDate;
    final DateTime lastDate = _historyLastSelectableDate;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _clampedHistoryDate(_selectedHistoryDate),
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Select history date',
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _selectedHistoryDate = _historyDateOnly(picked);
    });
  }

  void _showTodayHistory() {
    final DateTime today = _historyDateOnly(DateTime.now());
    if (_isSameDay(_selectedHistoryDate, today)) {
      return;
    }
    setState(() {
      _selectedHistoryDate = today;
    });
  }

  Widget _transactionHistoryScreen() {
    final DateTime selectedDate = _selectedHistoryDate;
    final bool selectedToday = _isSameDay(selectedDate, DateTime.now());
    final String dateLabel = selectedToday
        ? 'Today'
        : _formatDate(selectedDate);
    final List<TransactionData> transactions = _selectedHistoryDateTransactions;
    final int sold = transactions.where(_isSoldTransaction).length;
    final int cancelled = transactions
        .where((TransactionData item) => item.status == 'Cancelled')
        .length;
    final int salesTotal = transactions.fold<int>(0, (
      int sum,
      TransactionData transaction,
    ) {
      if (!_isSoldTransaction(transaction)) {
        return sum;
      }
      return sum + _parsePesoAmount(transaction.price);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.orange.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.receipt_long_rounded,
                      color: AppColors.orangeText,
                      size: 21,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          dateLabel,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          _formatDate(selectedDate),
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      children: <Widget>[
                        StatusBadge.green('$sold sold'),
                        if (cancelled > 0)
                          StatusBadge.orange('$cancelled cancelled'),
                      ],
                    ),
                  ),
                  SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        'Sales',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        money(salesTotal),
                        style: TextStyle(
                          color: AppColors.orangeText,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        Column(
          children: transactions.isEmpty
              ? <Widget>[
                  _emptyStateCard(
                    icon: Icons.receipt_long_rounded,
                    title: 'No transaction records',
                    detail: selectedToday
                        ? 'No sales recorded today.'
                        : 'No sales recorded on ${_formatDate(selectedDate)}.',
                  ),
                ]
              : transactions.map((TransactionData transaction) {
                  return HistoryTransactionCard(
                    transaction: transaction,
                    onManage: _isGuestSession || transaction.saleId == null
                        ? null
                        : () => unawaited(_showTransactionActions(transaction)),
                  );
                }).toList(),
        ),
      ],
    );
  }

  Widget _inventoryScreen() {
    final DashboardStats stats = _dashboardStats();
    final int configuredPriceCount = _managedFruits
        .where(_inventoryPriceIsConfigured)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _inventoryHeader(
          stats: stats,
          configuredPriceCount: configuredPriceCount,
        ),
        SizedBox(height: 10),
        if (_isGuestSession) ...<Widget>[
          _demoInventoryNotice(),
          SizedBox(height: 10),
        ],
        if (_inventoryLoading) ...<Widget>[
          AppCard(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.orangeText,
                  ),
                ),
                SizedBox(width: 12),
                Text(
                  'Loading offline inventory...',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
        ],
        _inventoryRestockPanel(stats),
        SizedBox(height: 12),
        if (_priceConflictNotice != null && !_isGuestSession) ...<Widget>[
          _priceConflictBanner(),
          SizedBox(height: 12),
        ],
        if (_priceChangeHistory.isNotEmpty && !_isGuestSession) ...<Widget>[
          _priceHistoryPanel(),
          SizedBox(height: 12),
        ],
        Row(
          children: <Widget>[
            Expanded(child: SectionLabel('Prices and restock signals')),
            StatusBadge.blue('${_managedFruits.length} active'),
          ],
        ),
        SizedBox(height: 8),
        if (_managedFruits.isEmpty)
          _emptyStateCard(
            icon: Icons.inventory_2_rounded,
            title: 'No active fruits',
            detail: 'Open Manage to add fruits and set prices.',
          )
        else
          Column(
            children: _managedFruits.map((String fruit) {
              final FruitInfo info = _catalog[fruit]!;
              final bool expanded = _expandedInventoryFruit == fruit;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _InventoryFruitCard(
                  fruit: info,
                  price: _prices[fruit] ?? 0,
                  priceConfigured: _inventoryPriceIsConfigured(fruit),
                  restockSignal: _restockSignalForFruit(fruit, stats: stats),
                  expanded: expanded,
                  readOnly: _isGuestSession,
                  priceController: _priceInputControllerFor(fruit),
                  priceFocusNode: _priceInputFocusNodeFor(fruit),
                  onToggle: () {
                    setState(() {
                      _expandedInventoryFruit = expanded ? null : fruit;
                    });
                  },
                  onPriceTyped: (String value) => _setTypedPrice(fruit, value),
                  onPriceDown: () => _adjustPrice(fruit, -100),
                  onPriceUp: () => _adjustPrice(fruit, 100),
                  onSave: () => _saveInventoryFruit(fruit),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _inventoryManageScreen() {
    final List<String> availableFruits = _scanReadyFruitOrder
        .where((String fruit) => !_managedFruits.contains(fruit))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_isGuestSession) ...<Widget>[
          _demoInventoryNotice(),
          SizedBox(height: 12),
        ],
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.orange.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.tune_rounded,
                  color: AppColors.orangeText,
                  size: 20,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Choose the fruits this vendor sells, including Philippine tropical options, then set the price per kg.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        _inventoryCatalogManager(availableFruits),
      ],
    );
  }

  Widget _demoInventoryNotice() {
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.visibility_rounded,
              color: AppColors.orangeText,
              size: 18,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Demo pricing is preview-only. Create an account to edit prices and sync real inventory.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceConflictBanner() {
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.security_rounded,
              color: AppColors.orangeText,
              size: 18,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              _priceConflictNotice!,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() {
                _priceConflictNotice = null;
              });
            },
            icon: Icon(
              Icons.close_rounded,
              color: AppColors.textMuted,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceHistoryPanel() {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: SectionTitle('Price history')),
              StatusBadge.blue('${_priceChangeHistory.length} recent'),
            ],
          ),
          SizedBox(height: 8),
          ..._priceChangeHistory.take(3).map((LocalPriceChange change) {
            final String sourceLabel = switch (change.source) {
              'cloud' => 'Cloud sync',
              'conflict' => 'Protected',
              _ => 'Manual',
            };
            final Color sourceColor = switch (change.source) {
              'cloud' => AppColors.palm,
              'conflict' => AppColors.orange,
              _ => AppColors.sand,
            };
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.borderSoft, width: 0.5),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: sourceColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: FruitMark(name: change.fruitName, size: 22),
                  ),
                  SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          change.fruitName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '${money(change.oldPrice)} -> ${money(change.newPrice)}/kg',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        sourceLabel,
                        style: TextStyle(
                          color: sourceColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        _shortDateTime(change.createdAt),
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _inventoryHeader({
    required DashboardStats stats,
    required int configuredPriceCount,
  }) {
    final FruitRank? leader = stats.topFruitRanks.isEmpty
        ? null
        : stats.topFruitRanks.first;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.palm.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.inventory_2_rounded,
                  color: AppColors.greenText,
                  size: 22,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Catalog pricing',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      leader == null
                          ? 'No restock leader yet'
                          : '${leader.name} leads today',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              leader == null
                  ? StatusBadge.orange('Waiting')
                  : StatusBadge.red('Heavy'),
            ],
          ),
          SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 620;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _inventoryMetricTile(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 8),
                    icon: Icons.shopping_basket_rounded,
                    label: 'Active fruits',
                    value:
                        '${_managedFruits.length}/${_scanReadyFruitOrder.length}',
                  ),
                  _inventoryMetricTile(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 8),
                    icon: Icons.sell_rounded,
                    label: 'Prices set',
                    value: '$configuredPriceCount/${_managedFruits.length}',
                  ),
                  _inventoryMetricTile(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 8),
                    icon: Icons.trending_up_rounded,
                    label: 'Signals',
                    value: stats.topFruitRanks.isEmpty
                        ? 'None'
                        : '${stats.topFruitRanks.length}',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _inventoryMetricTile({
    required double width,
    required IconData icon,
    required String label,
    required String value,
  }) {
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSoft, width: 0.5),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, color: AppColors.orangeText, size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inventoryCatalogManager(List<String> availableFruits) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: SectionTitle('Catalog manager')),
              StatusBadge.blue('${availableFruits.length} available'),
            ],
          ),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 720;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  SizedBox(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 10),
                    child: AppDropdown(
                      value: _fruitToAdd,
                      hint: availableFruits.isEmpty
                          ? 'All fruits are active'
                          : 'Select fruit to add',
                      items: availableFruits,
                      onChanged: _isGuestSession
                          ? null
                          : (String? value) {
                              setState(() => _fruitToAdd = value);
                            },
                    ),
                  ),
                  SizedBox(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 10),
                    child: AppTextField(
                      controller: _newPriceController,
                      label: 'Price per kg',
                      hint: _isGuestSession ? 'Preview only' : '90.00',
                      enabled: !_isGuestSession,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: _tileWidth(constraints.maxWidth, wide ? 3 : 1, 10),
                    child: PrimaryButton(
                      label: 'Add fruit',
                      icon: Icons.add_rounded,
                      onPressed: _isGuestSession || availableFruits.isEmpty
                          ? null
                          : _addSelectedFruit,
                      expanded: true,
                    ),
                  ),
                ],
              );
            },
          ),
          SizedBox(height: 14),
          const SectionLabel('Active catalog'),
          SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _managedFruits.map((String fruit) {
              return FruitChip(
                label: fruit,
                onRemove: _isGuestSession ? null : () => _removeFruit(fruit),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _inventoryRestockPanel(DashboardStats stats) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: SectionTitle('Today\'s restock priority')),
              stats.topFruitRanks.isEmpty
                  ? StatusBadge.orange('No signal')
                  : StatusBadge.green('${stats.topFruitRanks.length} ranked'),
            ],
          ),
          if (stats.topFruitRanks.isEmpty)
            const _InventoryEmptySignal()
          else
            ...stats.topFruitRanks.asMap().entries.map((
              MapEntry<int, FruitRank> entry,
            ) {
              return _inventoryRestockRow(entry.value, entry.key + 1);
            }),
        ],
      ),
    );
  }

  Widget _inventoryRestockRow(FruitRank rank, int position) {
    final _RestockSignal signal = _restockSignalForRankIndex(position - 1);
    final Color rankColor = switch (position) {
      1 => const Color(0xFFFFD54F),
      2 => const Color(0xFFB0BEC5),
      _ => const Color(0xFFD08A4E),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSoft, width: 0.5),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: rankColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$position',
              style: TextStyle(
                color: rankColor,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(width: 9),
          FruitMark(name: rank.name, size: 24),
          SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  rank.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 2),
                Text(
                  '${rank.transactions} sales - ${_formatKgValue(rank.weightKg)} - ${money(rank.revenuePhp)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          signal.badge,
        ],
      ),
    );
  }

  StatusBadge _cameraEyeBadge() {
    if (_cameraEyeBusy) {
      return StatusBadge.orange('Working');
    }
    if (_cameraEyeStatus.ready) {
      return StatusBadge.green('Eye ready');
    }
    if (_cameraEyeStatus.connectedToAp) {
      return StatusBadge.orange('AP linked');
    }
    if (_cameraEyeStatus.supported) {
      return StatusBadge.blue('Standby');
    }
    return StatusBadge.red('Android only');
  }

  bool get _cameraEyeIsIdle =>
      !_cameraEyeBusy &&
      _cameraEyeStatus.supported &&
      !_cameraEyeStatus.connectedToAp &&
      _cameraEyeStatus.currentSsid == 'Not connected' &&
      _cameraEyeStatus.message == 'Camera eye is ready to connect.';

  bool get _cameraEyeHasProblem =>
      !_cameraEyeStatus.supported ||
      _cameraEyeStatus.currentSsid == 'Error' ||
      (!_cameraEyeIsIdle && !_cameraEyeBusy && !_cameraEyeStatus.connectedToAp);

  String get _cameraEyeStateLabel {
    if (_cameraEyeBusy) {
      return 'Checking';
    }
    if (_cameraEyeStatus.ready) {
      return 'Stream alive';
    }
    if (_cameraEyeStatus.connectedToAp) {
      return 'AP connected';
    }
    if (!_cameraEyeStatus.supported) {
      return 'Android only';
    }
    if (_cameraEyeHasProblem) {
      return 'Camera unavailable';
    }
    return 'Standby';
  }

  Color get _cameraEyeSignalColor {
    if (_cameraEyeBusy) {
      return AppColors.orangeText;
    }
    if (_cameraEyeStatus.ready) {
      return AppColors.greenText;
    }
    if (_cameraEyeStatus.connectedToAp) {
      return AppColors.orangeText;
    }
    if (_cameraEyeHasProblem) {
      return AppColors.pinkText;
    }
    return AppColors.textMuted;
  }

  Color get _cameraEyeButtonColor {
    if (_cameraEyeStatus.ready) {
      return AppColors.palm.withValues(alpha: 0.16);
    }
    if (_cameraEyeBusy || _cameraEyeStatus.connectedToAp) {
      return AppColors.orangeDim;
    }
    if (_cameraEyeHasProblem) {
      return AppColors.pink.withValues(alpha: 0.12);
    }
    return AppColors.bgCard;
  }

  IconData get _cameraEyeTopIcon {
    if (_cameraEyeBusy) {
      return Icons.sync_rounded;
    }
    if (_cameraEyeHasProblem) {
      return Icons.videocam_off_rounded;
    }
    return Icons.videocam_rounded;
  }

  String get _cameraEyeTooltip =>
      'Camera eye: $_cameraEyeStateLabel. Tap for details.';

  Widget _cameraEyeTopBarButton() {
    final Color signalColor = _cameraEyeSignalColor;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _cameraEyeButtonColor,
        border: Border.all(
          color: signalColor.withValues(alpha: 0.72),
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IconButton(
              tooltip: _cameraEyeTooltip,
              padding: EdgeInsets.zero,
              onPressed: _openCameraEyeDialog,
              icon: Icon(_cameraEyeTopIcon, color: signalColor, size: 20),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: signalColor,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.bgCard, width: 1.2),
              ),
            ),
          ),
          if (_cameraEyeBusy)
            Positioned(
              left: 7,
              right: 7,
              bottom: 5,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: signalColor,
                backgroundColor: AppColors.bgSurface,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openCameraEyeDialog() async {
    if (_operationsOpen && mounted) {
      setState(() {
        _operationsOpen = false;
      });
    }

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close camera eye',
      barrierColor: Colors.black.withValues(alpha: 0.38),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder:
          (
            BuildContext dialogContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            String? panelNotice;
            bool previewOpen = false;
            return StatefulBuilder(
              builder: (BuildContext context, StateSetter setDialogState) {
                Future<void> runCameraAction(
                  Future<void> Function() action,
                ) async {
                  await action();
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      panelNotice = _cameraEyeStatus.message;
                    });
                  }
                }

                return SafeArea(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 430),
                            child: Material(
                              color: Colors.transparent,
                              child: AppCard(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        Container(
                                          width: 42,
                                          height: 42,
                                          decoration: BoxDecoration(
                                            color: AppColors.palm.withValues(
                                              alpha: 0.14,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.videocam_rounded,
                                            color: AppColors.greenText,
                                          ),
                                        ),
                                        SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Wrap(
                                                spacing: 8,
                                                runSpacing: 4,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: <Widget>[
                                                  Text(
                                                    'Camera Eye',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                                  ),
                                                  _cameraEyeBadge(),
                                                ],
                                              ),
                                              SizedBox(height: 3),
                                              Text(
                                                _cameraEyeStatus.message,
                                                style: TextStyle(
                                                  color:
                                                      AppColors.textSecondary,
                                                  fontSize: 12,
                                                  height: 1.35,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Close',
                                          onPressed: () =>
                                              Navigator.of(dialogContext).pop(),
                                          icon: Icon(
                                            Icons.close_rounded,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 14),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        StatusBadge.blue(
                                          'Host ${CameraEyeService.host}',
                                        ),
                                        StatusBadge.blue(
                                          'Current ${_cameraEyeStatus.currentSsid}',
                                        ),
                                        StatusBadge.blue(
                                          _cameraEyeStatus.streamReachable
                                              ? 'Stream reachable'
                                              : 'Stream waiting',
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppColors.bgSurface,
                                        border: Border.all(
                                          color: AppColors.borderSoft,
                                          width: 0.5,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          const SectionLabel('Camera route'),
                                          SizedBox(height: 8),
                                          _cameraInfoRow(
                                            'Host',
                                            CameraEyeService.baseUrl,
                                          ),
                                          SizedBox(height: 6),
                                          _cameraInfoRow(
                                            'Snapshot',
                                            _cameraEyeStatus.snapshotUrl,
                                          ),
                                          SizedBox(height: 6),
                                          _cameraInfoRow(
                                            'Probe',
                                            _cameraEyeStatus.probeUrl ??
                                                'Not reachable yet',
                                          ),
                                          SizedBox(height: 6),
                                          _cameraInfoRow(
                                            'Model',
                                            _fruitDetectionModelMode ==
                                                    _fruitDetectionAutoMode
                                                ? 'Auto ${_fruitDetectionModel.precision}'
                                                : _fruitDetectionModel
                                                      .precision,
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppColors.orange.withValues(
                                          alpha: 0.09,
                                        ),
                                        border: Border.all(
                                          color: AppColors.orange.withValues(
                                            alpha: 0.26,
                                          ),
                                          width: 0.5,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: previewOpen
                                          ? _CameraEyeSnapshotPreview(
                                              service: _cameraEyeService,
                                              onNotice: (String message) {
                                                if (dialogContext.mounted) {
                                                  setDialogState(() {
                                                    panelNotice = message;
                                                  });
                                                }
                                              },
                                            )
                                          : Text(
                                              'Preview pulls camera snapshots from the ESP32-CAM while preview or scale detection is active. When detection finishes, the camera returns to idle.',
                                              style: TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 12,
                                                height: 1.35,
                                              ),
                                            ),
                                    ),
                                    if (panelNotice != null) ...<Widget>[
                                      SizedBox(height: 12),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: _cameraEyeHasProblem
                                              ? AppColors.pink.withValues(
                                                  alpha: 0.10,
                                                )
                                              : AppColors.palm.withValues(
                                                  alpha: 0.10,
                                                ),
                                          border: Border.all(
                                            color: _cameraEyeHasProblem
                                                ? AppColors.pink.withValues(
                                                    alpha: 0.30,
                                                  )
                                                : AppColors.palm.withValues(
                                                    alpha: 0.30,
                                                  ),
                                            width: 0.5,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Icon(
                                              _cameraEyeHasProblem
                                                  ? Icons.error_outline_rounded
                                                  : Icons.info_outline_rounded,
                                              color: _cameraEyeHasProblem
                                                  ? AppColors.pinkText
                                                  : AppColors.greenText,
                                              size: 18,
                                            ),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                panelNotice!,
                                                style: TextStyle(
                                                  color:
                                                      AppColors.textSecondary,
                                                  fontSize: 12,
                                                  height: 1.35,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    if (_cameraEyeBusy) ...<Widget>[
                                      SizedBox(height: 12),
                                      LinearProgressIndicator(
                                        minHeight: 2,
                                        color: AppColors.orangeText,
                                        backgroundColor: AppColors.bgSurface,
                                      ),
                                    ],
                                    SizedBox(height: 14),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        PrimaryButton(
                                          label: _cameraEyeBusy
                                              ? 'Working'
                                              : 'Connect',
                                          icon: Icons.wifi_rounded,
                                          onPressed: _cameraEyeBusy
                                              ? null
                                              : () => runCameraAction(
                                                  () => _connectCameraEye(
                                                    showToast: false,
                                                  ),
                                                ),
                                          busy: _cameraEyeBusy,
                                        ),
                                        GhostButton(
                                          label: 'Check',
                                          icon: Icons.refresh_rounded,
                                          onPressed: _cameraEyeBusy
                                              ? null
                                              : () => runCameraAction(
                                                  () => _refreshCameraEye(
                                                    showToast: false,
                                                  ),
                                                ),
                                        ),
                                        GhostButton(
                                          label: previewOpen
                                              ? 'Hide preview'
                                              : 'Preview',
                                          icon: previewOpen
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                          onPressed: _cameraEyeBusy
                                              ? null
                                              : () {
                                                  setDialogState(() {
                                                    previewOpen = !previewOpen;
                                                    panelNotice = previewOpen
                                                        ? 'Opening ESP32-CAM preview...'
                                                        : 'Camera preview closed.';
                                                  });
                                                },
                                        ),
                                        GhostButton(
                                          label: 'Release',
                                          icon: Icons.link_off_rounded,
                                          onPressed: _cameraEyeBusy
                                              ? null
                                              : () => runCameraAction(
                                                  () => _releaseCameraEyeRoute(
                                                    showToast: false,
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
      transitionBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
                child: child,
              ),
            );
          },
    );
  }

  Widget _cameraInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  Widget _forecastScreen() {
    final DashboardStats stats = _dashboardStats();
    final List<_ForecastRecommendation> recommendations =
        _forecastRecommendations(stats);
    final _ForecastChartData forecastChart = _forecastChartData();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: SectionTitle(
                      _isGuestSession ? 'Demo forecast' : 'AI automation',
                    ),
                  ),
                  _isGuestSession
                      ? StatusBadge.blue('Demo')
                      : _latestAiError == null
                      ? StatusBadge.green('Ready')
                      : StatusBadge.orange('Check AI'),
                ],
              ),
              if (_forecastGenerating)
                Row(
                  children: <Widget>[
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.orangeText,
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _isGuestSession
                            ? 'Building a local demo forecast from sample sales...'
                            : 'Updating forecast...',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  _latestAiError ??
                      _latestAiForecast?.summary ??
                      (_isGuestSession
                          ? 'Demo forecast preview only.'
                          : 'Tap the dashboard forecast icon to refresh recommendations.'),
                  style: TextStyle(
                    color: _latestAiError == null
                        ? AppColors.textSecondary
                        : AppColors.pinkText,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              if (_latestAiForecast != null) ...<Widget>[
                SizedBox(height: 8),
                Text(
                  'Source: ${_latestAiForecast!.sourceLabel}',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle('Projected daily sales'),
              Text(
                forecastChart.hasSales
                    ? (_isGuestSession
                          ? 'Demo projection from sample sales only.'
                          : 'Projection from sales activity.')
                    : 'No sales yet.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              SizedBox(height: 10),
              if (forecastChart.hasSales) ...<Widget>[
                ChartLegend(
                  labels: forecastChart.fruitLabels,
                  colors: AppColors.chartColors,
                ),
                SizedBox(height: 10),
                StackedBarChart(
                  labels: forecastChart.labels,
                  series: forecastChart.series,
                  colors: AppColors.chartColors,
                  valueSuffix: ' kg',
                  showValueLabels: true,
                ),
              ] else
                const _ForecastChartEmptyState(),
              SizedBox(height: 12),
              MetricGrid(
                maxColumns: 3,
                metrics: <MetricData>[
                  const MetricData('Forecast period', 'Next 7 days', ''),
                  MetricData(
                    'Analyzed',
                    forecastChart.analyzedLabel,
                    forecastChart.analyzedSubtext,
                  ),
                  MetricData(
                    'Last updated',
                    forecastChart.lastUpdatedLabel,
                    forecastChart.lastUpdatedSubtext,
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionTitle('What to do next'),
              if (recommendations.isEmpty)
                const _ForecastEmptyState()
              else
                ...recommendations.map((_ForecastRecommendation item) {
                  return GuidedActionRow(
                    fruitName: item.fruitName,
                    title: item.title,
                    detail: item.detail,
                    badge: item.badge,
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  _ForecastChartData _forecastChartData() {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime periodStart = today.subtract(const Duration(days: 6));
    final Map<String, double> fruitTotals = <String, double>{
      for (final String fruit in _scanReadyFruitOrder) fruit: 0,
    };
    final Set<String> observedDays = <String>{};
    DateTime? lastUpdated;
    int analyzedCount = 0;

    for (final TransactionData transaction in _activeTransactionHistory) {
      if (!_isSoldTransaction(transaction) ||
          !_scanReadyFruits.contains(transaction.fruit)) {
        continue;
      }

      DateTime? soldAt = transaction.soldAt;
      if (_isGuestSession) {
        soldAt ??= now.subtract(Duration(days: analyzedCount % 7));
      }
      if (soldAt == null) {
        continue;
      }
      if (!_isGuestSession && soldAt.isBefore(periodStart)) {
        continue;
      }

      final double weightKg = _parseKgAmount(transaction.weight);
      if (weightKg <= 0) {
        continue;
      }
      fruitTotals.update(
        transaction.fruit,
        (double value) => value + weightKg,
        ifAbsent: () => weightKg,
      );
      observedDays.add('${soldAt.year}-${soldAt.month}-${soldAt.day}');
      if (lastUpdated == null || soldAt.isAfter(lastUpdated)) {
        lastUpdated = soldAt;
      }
      analyzedCount++;
    }

    final List<MapEntry<String, double>> rankedFruits =
        fruitTotals.entries
            .where((MapEntry<String, double> entry) => entry.value > 0)
            .toList()
          ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
            return b.value.compareTo(a.value);
          });

    if (rankedFruits.isEmpty) {
      return _ForecastChartData.empty();
    }

    const List<double> dailyPattern = <double>[
      0.92,
      1.00,
      1.06,
      1.02,
      1.12,
      1.18,
      1.08,
    ];
    final int observedDayCount = math.max(1, observedDays.length);
    final List<String> labels = List<String>.generate(7, (int index) {
      final DateTime forecastDate = now.add(Duration(days: index + 1));
      return dayNames[forecastDate.weekday - 1];
    });
    final List<String> fruitLabels = rankedFruits
        .take(AppColors.chartColors.length)
        .map((MapEntry<String, double> entry) => entry.key)
        .toList();
    final List<List<num>> series = rankedFruits
        .take(AppColors.chartColors.length)
        .map((MapEntry<String, double> entry) {
          final double dailyAverage = entry.value / observedDayCount;
          return dailyPattern.map((double multiplier) {
            return double.parse((dailyAverage * multiplier).toStringAsFixed(1));
          }).toList();
        })
        .toList();

    return _ForecastChartData(
      labels: labels,
      fruitLabels: fruitLabels,
      series: series,
      analyzedCount: analyzedCount,
      lastUpdated: lastUpdated,
      now: now,
    );
  }

  AnalyticsData _generateAnalytics(
    int year,
    int month,
    AnalyticsPeriod period,
  ) {
    final DateTime now = DateTime.now();
    final List<_AnalyticsSale> sales = _analyticsSales(
      period,
      year,
      month,
      now,
    );
    final _AnalyticsBuckets buckets = _analyticsBuckets(
      period,
      year,
      month,
      now,
      sales,
    );
    final Map<String, int> revenueByFruit = <String, int>{};
    final Map<String, double> weightByFruit = <String, double>{};

    for (final _AnalyticsSale sale in sales) {
      revenueByFruit.update(
        sale.fruit,
        (int value) => value + sale.revenuePhp,
        ifAbsent: () => sale.revenuePhp,
      );
      weightByFruit.update(
        sale.fruit,
        (double value) => value + sale.weightKg,
        ifAbsent: () => sale.weightKg,
      );
    }

    final List<MapEntry<String, int>> rankedFruits =
        revenueByFruit.entries.toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
            final int revenueCompare = b.value.compareTo(a.value);
            if (revenueCompare != 0) {
              return revenueCompare;
            }
            return a.key.compareTo(b.key);
          });
    final List<String> shareLabels = rankedFruits
        .take(AppColors.chartColors.length)
        .map((MapEntry<String, int> entry) => entry.key)
        .toList();
    final List<int> shareValues = rankedFruits
        .take(AppColors.chartColors.length)
        .map((MapEntry<String, int> entry) => entry.value)
        .toList();
    final Map<String, List<int>> revenueByBucket = <String, List<int>>{
      for (final String fruit in shareLabels)
        fruit: List<int>.filled(buckets.labels.length, 0),
    };

    for (final _AnalyticsSale sale in sales) {
      final List<int>? fruitSeries = revenueByBucket[sale.fruit];
      if (fruitSeries == null) {
        continue;
      }
      final int bucketIndex = buckets.bucketFor(sale.soldAt);
      if (bucketIndex < 0 || bucketIndex >= fruitSeries.length) {
        continue;
      }
      fruitSeries[bucketIndex] += sale.revenuePhp;
    }

    final int totalRevenue = sales.fold<int>(
      0,
      (int sum, _AnalyticsSale sale) => sum + sale.revenuePhp,
    );
    final double totalWeightKg = sales.fold<double>(
      0,
      (double sum, _AnalyticsSale sale) => sum + sale.weightKg,
    );
    final List<AnalyticsMovement> movements = rankedFruits.map((
      MapEntry<String, int> entry,
    ) {
      return AnalyticsMovement(
        name: entry.key,
        weightKg: weightByFruit[entry.key] ?? 0,
        revenuePhp: entry.value,
      );
    }).toList();
    final int averageRevenue = buckets.averageDivisor <= 0
        ? 0
        : (totalRevenue / buckets.averageDivisor).round();
    final bool hasSales = sales.isNotEmpty;

    return AnalyticsData(
      revenueLabels: buckets.labels,
      revenueSeries: shareLabels
          .map((String fruit) => revenueByBucket[fruit] ?? <int>[])
          .toList(),
      shareLabels: shareLabels,
      shareValues: shareValues,
      movements: movements,
      hasSales: hasSales,
      revenue: money(totalRevenue),
      periodLabel: buckets.periodLabel,
      unitsSold: _formatKgValue(totalWeightKg),
      bestSeller: hasSales ? shareLabels.first : 'No sales yet',
      bestSellerRevenue: hasSales
          ? '${money(shareValues.first)} revenue'
          : 'Waiting for transactions',
      averageRevenue: money(averageRevenue),
      averageLabel: buckets.averageLabel,
      chartTitle: buckets.chartTitle,
      chartSub: hasSales
          ? (_isGuestSession
                ? 'Demo analytics from sample sales only'
                : 'Sales breakdown by fruit')
          : 'No sales in this range yet',
      contextText: buckets.contextText,
    );
  }

  List<_AnalyticsSale> _analyticsSales(
    AnalyticsPeriod period,
    int year,
    int month,
    DateTime now,
  ) {
    final _AnalyticsRange range = _analyticsRange(period, year, month, now);
    final List<_AnalyticsSale> sales = <_AnalyticsSale>[];
    for (int index = 0; index < _activeTransactionHistory.length; index++) {
      final TransactionData transaction = _activeTransactionHistory[index];
      if (!_isSoldTransaction(transaction)) {
        continue;
      }
      DateTime? soldAt = transaction.soldAt;
      if (soldAt == null && _isGuestSession) {
        soldAt = now.subtract(Duration(days: index % 12));
      }
      if (soldAt == null) {
        continue;
      }
      if (range.start != null && soldAt.isBefore(range.start!)) {
        continue;
      }
      if (range.endExclusive != null && !soldAt.isBefore(range.endExclusive!)) {
        continue;
      }
      final int revenuePhp = _parsePesoAmount(transaction.price);
      final double weightKg = _parseKgAmount(transaction.weight);
      if (revenuePhp <= 0 && weightKg <= 0) {
        continue;
      }
      sales.add(
        _AnalyticsSale(
          fruit: transaction.fruit,
          soldAt: soldAt,
          revenuePhp: revenuePhp,
          weightKg: weightKg,
        ),
      );
    }
    return sales;
  }

  _AnalyticsRange _analyticsRange(
    AnalyticsPeriod period,
    int year,
    int month,
    DateTime now,
  ) {
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final DateTime tomorrowStart = todayStart.add(const Duration(days: 1));
    return switch (period) {
      AnalyticsPeriod.sevenDays => _AnalyticsRange(
        start: tomorrowStart.subtract(const Duration(days: 7)),
        endExclusive: tomorrowStart,
      ),
      AnalyticsPeriod.thirtyDays => _AnalyticsRange(
        start: tomorrowStart.subtract(const Duration(days: 30)),
        endExclusive: tomorrowStart,
      ),
      AnalyticsPeriod.month => _AnalyticsRange(
        start: DateTime(year, month + 1),
        endExclusive: DateTime(year, month + 2),
      ),
      AnalyticsPeriod.year => _AnalyticsRange(
        start: DateTime(year),
        endExclusive: DateTime(year + 1),
      ),
      AnalyticsPeriod.allTime => const _AnalyticsRange(),
    };
  }

  _AnalyticsBuckets _analyticsBuckets(
    AnalyticsPeriod period,
    int year,
    int month,
    DateTime now,
    List<_AnalyticsSale> sales,
  ) {
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final DateTime tomorrowStart = todayStart.add(const Duration(days: 1));
    switch (period) {
      case AnalyticsPeriod.sevenDays:
        final DateTime start = tomorrowStart.subtract(const Duration(days: 7));
        return _AnalyticsBuckets(
          labels: List<String>.generate(7, (int index) {
            return dayNames[start.add(Duration(days: index)).weekday - 1];
          }),
          bucketFor: (DateTime date) => date.difference(start).inDays,
          averageDivisor: 7,
          periodLabel: 'Last 7 days',
          chartTitle: 'Daily revenue - Last 7 days',
          contextText: 'Last 7 days',
          averageLabel: 'Daily average',
        );
      case AnalyticsPeriod.thirtyDays:
        final DateTime start = tomorrowStart.subtract(const Duration(days: 30));
        return _AnalyticsBuckets(
          labels: const <String>[
            'Days 1-6',
            'Days 7-12',
            'Days 13-18',
            'Days 19-24',
            'Days 25-30',
          ],
          bucketFor: (DateTime date) {
            return math.min(4, date.difference(start).inDays ~/ 6);
          },
          averageDivisor: 30,
          periodLabel: 'Last 30 days',
          chartTitle: 'Revenue by week - Last 30 days',
          contextText: 'Last 30 days',
          averageLabel: 'Daily average',
        );
      case AnalyticsPeriod.month:
        final DateTime start = DateTime(year, month + 1);
        final DateTime end = DateTime(year, month + 2);
        final int daysInMonth = end.difference(start).inDays;
        final int bucketCount = (daysInMonth / 7).ceil();
        return _AnalyticsBuckets(
          labels: List<String>.generate(bucketCount, (int index) {
            final int firstDay = index * 7 + 1;
            final int lastDay = math.min(daysInMonth, firstDay + 6);
            return '$firstDay-$lastDay';
          }),
          bucketFor: (DateTime date) {
            return math.min(bucketCount - 1, (date.day - 1) ~/ 7);
          },
          averageDivisor: daysInMonth,
          periodLabel: '${monthNames[month]} $year',
          chartTitle: 'Weekly revenue - ${monthNames[month]} $year',
          contextText: '${monthNames[month]} $year',
          averageLabel: 'Daily average',
        );
      case AnalyticsPeriod.year:
        return _AnalyticsBuckets(
          labels: monthNames,
          bucketFor: (DateTime date) => date.month - 1,
          averageDivisor: 365,
          periodLabel: '$year',
          chartTitle: 'Monthly revenue - $year',
          contextText: '$year',
          averageLabel: 'Daily average',
        );
      case AnalyticsPeriod.allTime:
        final List<int> years =
            sales
                .map((_AnalyticsSale sale) => sale.soldAt.year)
                .toSet()
                .toList()
              ..sort();
        final List<int> labelsYears = years.isEmpty ? <int>[now.year] : years;
        return _AnalyticsBuckets(
          labels: labelsYears.map((int value) => value.toString()).toList(),
          bucketFor: (DateTime date) => labelsYears.indexOf(date.year),
          averageDivisor: _allTimeAverageDays(sales, now),
          periodLabel: 'All time',
          chartTitle: 'Revenue by year - All time',
          contextText: 'All time',
          averageLabel: 'Daily average',
        );
    }
  }

  int _allTimeAverageDays(List<_AnalyticsSale> sales, DateTime now) {
    if (sales.isEmpty) {
      return 1;
    }
    final List<DateTime> dates =
        sales
            .map(
              (_AnalyticsSale sale) => DateTime(
                sale.soldAt.year,
                sale.soldAt.month,
                sale.soldAt.day,
              ),
            )
            .toList()
          ..sort();
    return math.max(1, dates.last.difference(dates.first).inDays + 1);
  }

  Widget _analyticsScreen() {
    final AnalyticsData data = _generateAnalytics(
      _selectedYear,
      _selectedMonth,
      _period,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _analyticsFilterPill(data),
        SizedBox(height: 14),
        MetricGrid(
          maxColumns: 2,
          minColumns: 2,
          metrics: <MetricData>[
            MetricData(
              'Total revenue',
              data.revenue,
              data.periodLabel,
              valueColor: AppColors.orangeText,
            ),
            MetricData('Units sold', data.unitsSold, 'Across all fruits'),
            MetricData(
              'Best seller',
              data.bestSeller,
              data.bestSellerRevenue,
              valueColor: AppColors.greenText,
            ),
            MetricData(
              'Avg daily rev.',
              data.averageRevenue,
              data.averageLabel,
            ),
          ],
        ),
        SizedBox(height: 12),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SectionTitle(data.chartTitle),
              Text(
                data.chartSub,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              SizedBox(height: 12),
              if (data.hasSales) ...<Widget>[
                ChartLegend(
                  labels: data.shareLabels,
                  colors: AppColors.chartColors,
                ),
                SizedBox(height: 10),
                StackedBarChart(
                  labels: data.revenueLabels,
                  series: data.revenueSeries,
                  colors: AppColors.chartColors,
                  valueFormatter: money,
                ),
              ] else
                const _AnalyticsEmptyState(
                  message: 'No sales in this range yet.',
                ),
            ],
          ),
        ),
        SizedBox(height: 12),
        _analyticsInsightToggle(data),
        if (_showAnalyticsDetails) ...<Widget>[
          SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool wide = constraints.maxWidth >= 560;
                return Flex(
                  direction: wide ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: wide ? 150 : double.infinity,
                      height: 150,
                      child: DonutChart(
                        values: data.shareValues,
                        colors: AppColors.shareColors,
                      ),
                    ),
                    SizedBox(width: wide ? 18 : 0, height: wide ? 0 : 14),
                    Expanded(
                      flex: wide ? 1 : 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const SectionTitle('Revenue share by fruit'),
                          SizedBox(height: 8),
                          if (data.hasSales)
                            ..._shareRows(data.shareLabels, data.shareValues)
                          else
                            const _AnalyticsEmptyState(
                              message: 'No revenue share yet.',
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SectionTitle('Inventory movement'),
                AppDataTable(
                  columns: const <String>[
                    'Fruit',
                    'Sold (kg)',
                    'Revenue',
                    'Avg PHP/kg',
                    'Trend',
                  ],
                  rows: _movementRows(data.movements),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _analyticsInsightToggle(AnalyticsData data) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _showAnalyticsDetails = !_showAnalyticsDetails;
        });
      },
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Icon(Icons.insights_rounded, color: AppColors.greenText, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                data.hasSales
                    ? (_showAnalyticsDetails
                          ? '${data.bestSeller} leads revenue. Tap to hide share and inventory movement.'
                          : '${data.bestSeller} leads revenue. Tap to view share and inventory movement.')
                    : (_showAnalyticsDetails
                          ? 'No revenue leader yet. Tap to hide details.'
                          : 'No revenue leader yet. Tap to view details.'),
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            SizedBox(width: 8),
            AnimatedRotation(
              turns: _showAnalyticsDetails ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textSecondary,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _analyticsFilterPill(AnalyticsData data) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openAnalyticsFilterSheet,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 310),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.12),
            border: Border.all(color: AppColors.borderStrong, width: 0.5),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.calendar_month_rounded,
                color: AppColors.orangeText,
                size: 16,
              ),
              SizedBox(width: 7),
              Flexible(
                child: Text(
                  data.contextText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.orangeText,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SizedBox(width: 5),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.orangeText,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAnalyticsFilterSheet() async {
    AnalyticsPeriod sheetPeriod = _period;
    int sheetYear = _selectedYear;
    int sheetMonth = _selectedMonth;
    final int maxYear = DateTime.now().year;
    const int minYear = 2023;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            void apply({AnalyticsPeriod? period, int? year, int? month}) {
              setSheetState(() {
                sheetPeriod = period ?? sheetPeriod;
                sheetYear = year ?? sheetYear;
                sheetMonth = month ?? sheetMonth;
              });
              if (!mounted) {
                return;
              }
              setState(() {
                _period = sheetPeriod;
                _selectedYear = sheetYear;
                _selectedMonth = sheetMonth;
              });
            }

            void changeYear(int delta) {
              apply(year: (sheetYear + delta).clamp(minYear, maxYear));
            }

            final bool monthEnabled = sheetPeriod == AnalyticsPeriod.month;
            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.88,
                  ),
                  child: AppCard(
                    padding: const EdgeInsets.all(14),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(child: SectionTitle('Date range')),
                              IconButton(
                                tooltip: 'Close',
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(),
                                icon: Icon(
                                  Icons.close_rounded,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          _analyticsFilterOption(
                            icon: Icons.calendar_view_week_rounded,
                            title: 'Last 7 days',
                            detail: 'Daily sales view',
                            selected: sheetPeriod == AnalyticsPeriod.sevenDays,
                            onTap: () =>
                                apply(period: AnalyticsPeriod.sevenDays),
                          ),
                          _analyticsFilterOption(
                            icon: Icons.date_range_rounded,
                            title: 'Last 30 days',
                            detail: 'Weekly sales view',
                            selected: sheetPeriod == AnalyticsPeriod.thirtyDays,
                            onTap: () =>
                                apply(period: AnalyticsPeriod.thirtyDays),
                          ),
                          _analyticsFilterOption(
                            icon: Icons.timeline_rounded,
                            title: 'This month',
                            detail: 'Selected month only',
                            selected: sheetPeriod == AnalyticsPeriod.month,
                            onTap: () => apply(period: AnalyticsPeriod.month),
                          ),
                          _analyticsFilterOption(
                            icon: Icons.bar_chart_rounded,
                            title: 'This year',
                            detail: 'Monthly sales view',
                            selected: sheetPeriod == AnalyticsPeriod.year,
                            onTap: () => apply(period: AnalyticsPeriod.year),
                          ),
                          _analyticsFilterOption(
                            icon: Icons.timeline_rounded,
                            title: 'All time',
                            detail: 'All sales',
                            selected: sheetPeriod == AnalyticsPeriod.allTime,
                            onTap: () => apply(period: AnalyticsPeriod.allTime),
                          ),
                          SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              Expanded(child: SectionLabel('Year')),
                              _compactIconButton(
                                tooltip: 'Previous year',
                                icon: Icons.chevron_left_rounded,
                                onPressed: sheetYear <= minYear
                                    ? null
                                    : () => changeYear(-1),
                              ),
                              Container(
                                width: 74,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  '$sheetYear',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              _compactIconButton(
                                tooltip: 'Next year',
                                icon: Icons.chevron_right_rounded,
                                onPressed: sheetYear >= maxYear
                                    ? null
                                    : () => changeYear(1),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Row(
                            children: <Widget>[
                              Expanded(child: SectionLabel('Month')),
                              if (!monthEnabled)
                                Text(
                                  'Used for month view',
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Opacity(
                            opacity: monthEnabled ? 1 : 0.42,
                            child: AbsorbPointer(
                              absorbing: !monthEnabled,
                              child: LayoutBuilder(
                                builder:
                                    (
                                      BuildContext context,
                                      BoxConstraints constraints,
                                    ) {
                                      const double gap = 8;
                                      final double tileWidth = _tileWidth(
                                        constraints.maxWidth,
                                        3,
                                        gap,
                                      );
                                      return Wrap(
                                        spacing: gap,
                                        runSpacing: gap,
                                        children: List<Widget>.generate(12, (
                                          int index,
                                        ) {
                                          return _analyticsMonthTile(
                                            width: tileWidth,
                                            label: monthNames[index],
                                            selected: sheetMonth == index,
                                            onTap: () => apply(month: index),
                                          );
                                        }),
                                      );
                                    },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _compactIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(
          icon,
          color: onPressed == null ? AppColors.textMuted : AppColors.orangeText,
        ),
      ),
    );
  }

  Widget _analyticsFilterOption({
    required IconData icon,
    required String title,
    required String detail,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: selected ? AppColors.orangeDim : AppColors.bgSurface,
            border: Border.all(
              color: selected ? AppColors.borderStrong : AppColors.borderSoft,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                color: selected ? AppColors.orangeText : AppColors.textMuted,
                size: 19,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.orangeText,
                  size: 18,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analyticsMonthTile({
    required double width,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: width,
      height: 38,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: selected
              ? AppColors.textPrimary
              : AppColors.textSecondary,
          backgroundColor: selected ? AppColors.bgRaised : AppColors.bgCard,
          side: BorderSide(
            color: selected ? AppColors.borderStrong : AppColors.borderMid,
            width: 0.5,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label.substring(0, 3),
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  Widget _dashboardNav() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _operationsOpen ? AppColors.orangeDim : AppColors.bgCard,
            border: Border.all(
              color: _operationsOpen
                  ? AppColors.borderStrong
                  : AppColors.borderMid,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: IconButton(
            tooltip: _operationsOpen
                ? 'Close operations menu'
                : 'Open operations menu',
            padding: EdgeInsets.zero,
            onPressed: () {
              setState(() {
                _operationsOpen = !_operationsOpen;
              });
            },
            icon: Icon(
              _operationsOpen ? Icons.close_rounded : Icons.menu_rounded,
              color: _operationsOpen
                  ? AppColors.orangeText
                  : AppColors.textSecondary,
            ),
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              Text(
                'FruityVens',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              if (_isGuestSession) StatusBadge.orange('Guest'),
            ],
          ),
        ),
        SizedBox(width: 10),
        _cameraEyeTopBarButton(),
        SizedBox(width: 8),
        _topBarIconButton(
          tooltip: _forecastGenerating
              ? 'Generating forecast'
              : 'Generate forecast',
          icon: _forecastGenerating
              ? Icons.hourglass_top_rounded
              : Icons.auto_graph_rounded,
          highlighted: true,
          onPressed: _forecastGenerating
              ? null
              : () => _generateAiForecast(quickAction: true),
        ),
      ],
    );
  }

  Widget _topBarIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    final Color color = highlighted
        ? AppColors.orangeText
        : AppColors.textSecondary;
    final Color effectiveColor = onPressed == null
        ? AppColors.textMuted
        : color;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: highlighted ? AppColors.orangeDim : AppColors.bgCard,
        border: Border.all(
          color: highlighted ? AppColors.borderStrong : AppColors.borderMid,
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, color: effectiveColor, size: 20),
      ),
    );
  }

  Widget _centeredScreenNav({
    required String title,
    required VoidCallback onBack,
    List<Widget> trailing = const <Widget>[],
    double titleSidePadding = 56,
  }) {
    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: _topBarIconButton(
              tooltip: 'Back',
              icon: Icons.arrow_back_rounded,
              onPressed: onBack,
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: titleSidePadding),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          if (trailing.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
            ),
        ],
      ),
    );
  }

  Widget _subNav({
    required String title,
    List<Widget> actions = const <Widget>[],
  }) {
    return _centeredScreenNav(
      title: title,
      onBack: () => _show(AppScreen.dashboard),
      titleSidePadding: actions.length > 1 ? 108 : 56,
      trailing: actions,
    );
  }

  Widget _historyNav() {
    final bool selectedToday = _isSameDay(_selectedHistoryDate, DateTime.now());
    return _subNav(
      title: 'History',
      actions: <Widget>[
        _topBarIconButton(
          tooltip: 'Pick history date',
          icon: Icons.calendar_month_rounded,
          onPressed: () => unawaited(_pickHistoryDate()),
        ),
        if (!selectedToday) ...<Widget>[
          SizedBox(width: 8),
          _topBarIconButton(
            tooltip: 'Show today',
            icon: Icons.today_rounded,
            highlighted: true,
            onPressed: _showTodayHistory,
          ),
        ],
      ],
    );
  }

  Widget _analyticsNav() {
    return _centeredScreenNav(
      title: 'Analytics',
      onBack: () => _show(AppScreen.dashboard),
    );
  }

  List<Widget> _shareRows(List<String> labels, List<int> values) {
    final int total = values.fold<int>(0, (int sum, int item) => sum + item);
    if (total <= 0) {
      return <Widget>[];
    }
    return List<Widget>.generate(labels.length, (int index) {
      final int percent = ((values[index] / total) * 100).round();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.shareColors[index],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(labels[index], style: TextStyle(fontSize: 13)),
            ),
            Text(
              '${money(values[index])} - $percent%',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    });
  }

  List<List<Widget>> _movementRows(List<AnalyticsMovement> movements) {
    if (movements.isEmpty) {
      return <List<Widget>>[
        <Widget>[
          Text('No sales yet'),
          Text('0 kg'),
          Text('PHP 0'),
          Text('Unset'),
          Align(
            alignment: Alignment.centerLeft,
            child: StatusBadge.orange('Waiting'),
          ),
        ],
      ];
    }
    return List<List<Widget>>.generate(movements.length, (int index) {
      final AnalyticsMovement movement = movements[index];
      return <Widget>[
        Text(movement.name),
        Text(_formatKgValue(movement.weightKg)),
        Text(
          money(movement.revenuePhp),
          style: TextStyle(color: AppColors.orangeText),
        ),
        Text(
          movement.weightKg <= 0
              ? 'Unset'
              : '${money(movement.averagePricePerKg)}/kg',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: switch (index) {
            0 => StatusBadge.green('Top'),
            1 => StatusBadge.blue('Steady'),
            _ => StatusBadge.orange('Watch'),
          },
        ),
      ];
    });
  }
}

class AppColors {
  static final ValueNotifier<bool> lightThemeEnabled = ValueNotifier<bool>(
    false,
  );

  static bool get isLightTheme => lightThemeEnabled.value;

  static void setLightTheme(bool enabled) {
    if (lightThemeEnabled.value != enabled) {
      lightThemeEnabled.value = enabled;
    }
  }

  static ThemeData materialTheme(bool lightThemeEnabled) {
    final Brightness brightness = lightThemeEnabled
        ? Brightness.light
        : Brightness.dark;
    final TextTheme baseTextTheme = lightThemeEnabled
        ? ThemeData.light().textTheme
        : ThemeData.dark().textTheme;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bgBase,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: palm,
        onPrimary: bgBase,
        secondary: orange,
        onSecondary: bgBase,
        error: pink,
        onError: bgBase,
        surface: bgCard,
        onSurface: textPrimary,
      ),
      textTheme: baseTextTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgCard,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(color: textPrimary),
      ),
    );
  }

  static Color get bgBase =>
      isLightTheme ? const Color(0xFFF0F4EF) : const Color(0xFF0D1F0F);
  static Color get bgSurface =>
      isLightTheme ? const Color(0xFFE4EDE4) : const Color(0xFF132916);
  static Color get bgCard =>
      isLightTheme ? const Color(0xFFFFFFFF) : const Color(0xFF1A3320);
  static Color get bgRaised =>
      isLightTheme ? const Color(0xFFD5E3D5) : const Color(0xFF1F3D26);
  static Color get palm =>
      isLightTheme ? const Color(0xFF2E7D32) : const Color(0xFF43A047);
  static Color get palmDark =>
      isLightTheme ? const Color(0xFF43A047) : const Color(0xFF1B5E20);
  static Color get orange =>
      isLightTheme ? const Color(0xFFE65100) : const Color(0xFFFB8C00);
  static Color get orangeDim =>
      isLightTheme ? const Color(0xFFFFF3E0) : const Color(0xFF3D2200);
  static Color get orangeText =>
      isLightTheme ? const Color(0xFFBF360C) : const Color(0xFFFFB74D);
  static Color get pink =>
      isLightTheme ? const Color(0xFFC2185B) : const Color(0xFFEC407A);
  static Color get pinkText =>
      isLightTheme ? const Color(0xFFC2185B) : const Color(0xFFF48FB1);
  static Color get sand =>
      isLightTheme ? const Color(0xFFE65100) : const Color(0xFFFFF3E0);
  static Color get textPrimary =>
      isLightTheme ? const Color(0xFF1A2E1B) : const Color(0xFFFFF3E0);
  static Color get textSecondary =>
      isLightTheme ? const Color(0xFF4A6741) : const Color(0xFFA5C9A8);
  static Color get textMuted =>
      isLightTheme ? const Color(0xFF7A9B7C) : const Color(0xFF5A8A5D);
  static Color get greenText =>
      isLightTheme ? const Color(0xFF2E7D32) : const Color(0xFF81C784);
  static Color get borderSoft =>
      isLightTheme ? const Color(0x3343A047) : const Color(0x2E43A047);
  static Color get borderMid =>
      isLightTheme ? const Color(0x6643A047) : const Color(0x5243A047);
  static Color get borderStrong =>
      isLightTheme ? const Color(0x99E65100) : const Color(0x73FB8C00);

  static List<Color> get chartColors => <Color>[
    palm,
    orange,
    pink,
    sand,
    palmDark,
  ];

  static List<Color> get shareColors => <Color>[
    palm,
    sand,
    orange,
    pink,
    palmDark,
    textMuted,
  ];
}

class _CameraEyeSnapshotPreview extends StatefulWidget {
  const _CameraEyeSnapshotPreview({
    required this.service,
    required this.onNotice,
  });

  final CameraEyeService service;
  final ValueChanged<String> onNotice;

  @override
  State<_CameraEyeSnapshotPreview> createState() =>
      _CameraEyeSnapshotPreviewState();
}

class _CameraEyeSnapshotPreviewState extends State<_CameraEyeSnapshotPreview> {
  Timer? _timer;
  Uint8List? _imageBytes;
  String _message = 'Starting ESP32-CAM preview...';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startPreview());
  }

  Future<void> _startPreview() async {
    try {
      await widget.service.startPreview();
      if (!mounted) {
        return;
      }
      widget.onNotice('ESP32-CAM preview started.');
      setState(() {
        _message = 'Live snapshot preview';
      });
      await _loadFrame();
      _timer = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => _loadFrame(),
      );
    } on CameraEyeException catch (error) {
      if (!mounted) {
        return;
      }
      widget.onNotice(error.message);
      setState(() {
        _message = error.message;
      });
    }
  }

  Future<void> _loadFrame() async {
    if (_loading) {
      return;
    }
    _loading = true;
    try {
      final Uint8List bytes = await widget.service.fetchSnapshot();
      if (!mounted) {
        return;
      }
      setState(() {
        _imageBytes = bytes;
        _message = 'Live snapshot preview';
      });
    } on CameraEyeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = error.message;
      });
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(widget.service.stopPreview());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _imageBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: bytes == null
                  ? CircularProgressIndicator(
                      color: AppColors.orangeText,
                      strokeWidth: 2,
                    )
                  : Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      width: double.infinity,
                      height: double.infinity,
                    ),
            ),
          ),
        ),
        SizedBox(height: 8),
        Text(
          _message,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _WalkthroughStep {
  const _WalkthroughStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.points,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<String> points;
}

class FruitInfo {
  const FruitInfo(this.name, this.icon, this.price, this.stock);

  final String name;
  final IconData icon;
  final int price;
  final int stock;
}

class MetricData {
  const MetricData(this.label, this.value, this.subtext, {this.valueColor});

  final String label;
  final String value;
  final String subtext;
  final Color? valueColor;
}

class TransactionData {
  const TransactionData(
    this.fruit,
    this.weight,
    this.price,
    this.date,
    this.time,
    this.status, {
    this.soldAt,
    this.saleId,
    this.cloudId,
  });

  final String fruit;
  final String weight;
  final String price;
  final String date;
  final String time;
  final String status;
  final DateTime? soldAt;
  final int? saleId;
  final String? cloudId;
}

class DashboardStats {
  const DashboardStats({
    required this.salesTotal,
    required this.transactionCount,
    required this.averageWeightKg,
    required this.topFruit,
    required this.topFruitRanks,
    required this.salesSubtext,
  });

  final int salesTotal;
  final int transactionCount;
  final double averageWeightKg;
  final String topFruit;
  final List<FruitRank> topFruitRanks;
  final String salesSubtext;

  String get averageWeightLabel {
    if (averageWeightKg <= 0) {
      return '0 kg';
    }
    return '${averageWeightKg.toStringAsFixed(1)} kg';
  }
}

class FruitRank {
  const FruitRank({
    required this.name,
    required this.transactions,
    required this.weightKg,
    required this.revenuePhp,
  });

  final String name;
  final int transactions;
  final double weightKg;
  final int revenuePhp;

  IconData get icon => _FruityVensCatalogIcons.iconFor(name);

  double get averageWeightKg => transactions <= 0 ? 0 : weightKg / transactions;

  String get weightLabel => _formatKgValue(weightKg);

  String get averageWeightLabel => _formatKgValue(averageWeightKg);
}

class _ForecastChartData {
  const _ForecastChartData({
    required this.labels,
    required this.fruitLabels,
    required this.series,
    required this.analyzedCount,
    required this.lastUpdated,
    required this.now,
  });

  factory _ForecastChartData.empty() {
    return _ForecastChartData(
      labels: const <String>[],
      fruitLabels: const <String>[],
      series: const <List<num>>[],
      analyzedCount: 0,
      lastUpdated: null,
      now: DateTime.now(),
    );
  }

  final List<String> labels;
  final List<String> fruitLabels;
  final List<List<num>> series;
  final int analyzedCount;
  final DateTime? lastUpdated;
  final DateTime now;

  bool get hasSales =>
      analyzedCount > 0 && fruitLabels.isNotEmpty && series.isNotEmpty;

  String get analyzedLabel => formatNumber(analyzedCount);

  String get analyzedSubtext =>
      analyzedCount == 1 ? 'Transaction' : 'Transactions';

  String get lastUpdatedLabel {
    final DateTime? updated = lastUpdated;
    if (updated == null) {
      return 'No sales yet';
    }
    if (_isSameDay(updated, now)) {
      return 'Today';
    }
    final DateTime yesterday = now.subtract(const Duration(days: 1));
    if (_isSameDay(updated, yesterday)) {
      return 'Yesterday';
    }
    return _formatDate(updated);
  }

  String get lastUpdatedSubtext {
    final DateTime? updated = lastUpdated;
    if (updated == null) {
      return 'Waiting for sales';
    }
    return _formatTime(updated);
  }
}

class _FruityVensCatalogIcons {
  const _FruityVensCatalogIcons._();

  static IconData iconFor(String fruitName) {
    return switch (fruitName) {
      'Apple' => Icons.apple_rounded,
      'Mango' || 'Mango Carabao' || 'Indian Mango' => Icons.spa_rounded,
      'Watermelon' || 'Orange' || 'Lemon' || 'Pomelo' => Icons.circle_rounded,
      'Melon' => Icons.blur_circular_rounded,
      'Papaya' || 'Guyabano' => Icons.eco_rounded,
      'Avocado' => Icons.grass_rounded,
      'Banana' || 'Langkatan' => Icons.rice_bowl_rounded,
      'Grapes' => Icons.bubble_chart_rounded,
      'Pear' || 'Guava' => Icons.local_florist_rounded,
      'Pineapple' => Icons.park_rounded,
      'Lanzones' => Icons.scatter_plot_rounded,
      'Calamansi' => Icons.brightness_1_rounded,
      'Strawberries' || 'Strawberry' => Icons.favorite_rounded,
      _ => Icons.spa_rounded,
    };
  }
}

class _ForecastRecommendation {
  const _ForecastRecommendation({
    required this.fruitName,
    required this.title,
    required this.detail,
    required this.value,
    required this.note,
    required this.badge,
  });

  final String fruitName;
  final String title;
  final String detail;
  final String value;
  final String note;
  final Widget badge;
}

class _RestockSignal {
  const _RestockSignal({
    required this.label,
    required this.detail,
    required this.badge,
  });

  final String label;
  final String detail;
  final Widget badge;
}

class _KeyboardStableViewport extends StatelessWidget {
  const _KeyboardStableViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.removeViewInsets(removeBottom: true),
      child: child,
    );
  }
}

class AnalyticsData {
  const AnalyticsData({
    required this.revenueLabels,
    required this.revenueSeries,
    required this.shareLabels,
    required this.shareValues,
    required this.movements,
    required this.hasSales,
    required this.revenue,
    required this.periodLabel,
    required this.unitsSold,
    required this.bestSeller,
    required this.bestSellerRevenue,
    required this.averageRevenue,
    required this.averageLabel,
    required this.chartTitle,
    required this.chartSub,
    required this.contextText,
  });

  final List<String> revenueLabels;
  final List<List<int>> revenueSeries;
  final List<String> shareLabels;
  final List<int> shareValues;
  final List<AnalyticsMovement> movements;
  final bool hasSales;
  final String revenue;
  final String periodLabel;
  final String unitsSold;
  final String bestSeller;
  final String bestSellerRevenue;
  final String averageRevenue;
  final String averageLabel;
  final String chartTitle;
  final String chartSub;
  final String contextText;
}

class AnalyticsMovement {
  const AnalyticsMovement({
    required this.name,
    required this.weightKg,
    required this.revenuePhp,
  });

  final String name;
  final double weightKg;
  final int revenuePhp;

  int get averagePricePerKg =>
      weightKg <= 0 ? 0 : (revenuePhp / weightKg).round();
}

class _AnalyticsSale {
  const _AnalyticsSale({
    required this.fruit,
    required this.soldAt,
    required this.revenuePhp,
    required this.weightKg,
  });

  final String fruit;
  final DateTime soldAt;
  final int revenuePhp;
  final double weightKg;
}

class _AnalyticsRange {
  const _AnalyticsRange({this.start, this.endExclusive});

  final DateTime? start;
  final DateTime? endExclusive;
}

class _AnalyticsBuckets {
  const _AnalyticsBuckets({
    required this.labels,
    required this.bucketFor,
    required this.averageDivisor,
    required this.periodLabel,
    required this.chartTitle,
    required this.contextText,
    required this.averageLabel,
  });

  final List<String> labels;
  final int Function(DateTime date) bucketFor;
  final int averageDivisor;
  final String periodLabel;
  final String chartTitle;
  final String contextText;
  final String averageLabel;
}

const List<String> monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> dayNames = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

String money(num value) {
  final int centavos = value.round();
  final bool negative = centavos < 0;
  final int absolute = centavos.abs();
  final int pesos = absolute ~/ 100;
  final int cents = absolute % 100;
  return 'PHP ${negative ? '-' : ''}${formatNumber(pesos)}.${cents.toString().padLeft(2, '0')}';
}

String formatNumber(int value) {
  final bool negative = value < 0;
  final String raw = value.abs().toString();
  final StringBuffer buffer = StringBuffer();
  for (int index = 0; index < raw.length; index++) {
    final int remaining = raw.length - index;
    buffer.write(raw[index]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return '${negative ? '-' : ''}$buffer';
}

String _priceInputFromCentavos(int centavos) {
  if (centavos <= 0) {
    return '';
  }
  final int pesos = centavos ~/ 100;
  final int cents = centavos % 100;
  return '$pesos.${cents.toString().padLeft(2, '0')}';
}

int? _parsePriceInputCentavos(String value) {
  final String clean = value
      .trim()
      .replaceAll(RegExp(r'php', caseSensitive: false), '')
      .replaceAll(',', '')
      .replaceAll(' ', '');
  if (clean.isEmpty) {
    return null;
  }
  if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(clean)) {
    return null;
  }
  final double? parsed = double.tryParse(clean);
  if (parsed == null || parsed.isNaN || parsed.isInfinite) {
    return null;
  }
  return (parsed * 100).round();
}

int _parsePesoAmount(String value) {
  final RegExpMatch? match = RegExp(r'\d+(?:\.\d+)?').firstMatch(value);
  if (match == null) {
    return 0;
  }
  return ((double.tryParse(match.group(0) ?? '') ?? 0) * 100).round();
}

double _parseKgAmount(String value) {
  final RegExpMatch? match = RegExp(r'\d+(?:\.\d+)?').firstMatch(value);
  if (match == null) {
    return 0;
  }
  return double.tryParse(match.group(0) ?? '') ?? 0;
}

String _formatWeight(int grams) {
  final double kg = grams / 1000;
  return '${kg.toStringAsFixed(kg >= 10 ? 0 : 1)} kg';
}

String _formatKgValue(double kg) {
  if (kg <= 0) {
    return '0 kg';
  }
  return '${kg.toStringAsFixed(kg >= 10 ? 0 : 1)} kg';
}

String _formatChartNumber(num value) {
  if (value == value.roundToDouble()) {
    return formatNumber(value.round());
  }
  if (value.abs() < 10) {
    return value.toStringAsFixed(1);
  }
  return formatNumber(value.round());
}

String _formatDate(DateTime date) {
  return '${monthNames[date.month - 1]} ${date.day}, ${date.year}';
}

String _formatTime(DateTime date) {
  final int hour = date.hour;
  final int displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  final String minute = date.minute.toString().padLeft(2, '0');
  final String suffix = hour >= 12 ? 'PM' : 'AM';
  return '$displayHour:$minute $suffix';
}

String _shortDateTime(DateTime date) {
  return '${monthNames[date.month - 1]} ${date.day}, ${_formatTime(date)}';
}

String _displayStatus(String status) {
  final String clean = status.trim().toLowerCase();
  if (clean == 'removed') {
    return 'Removed';
  }
  if (clean == 'cancelled' || clean == 'canceled') {
    return 'Cancelled';
  }
  return 'Sold';
}

bool _isSoldTransaction(TransactionData transaction) {
  return transaction.status == 'Sold';
}

DateTime _historyDateOnly(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

DateTime? _transactionHistoryDay(TransactionData transaction) {
  final DateTime? soldAt = transaction.soldAt;
  if (soldAt != null) {
    return _historyDateOnly(soldAt);
  }
  return _parseHistoryDate(transaction.date);
}

DateTime? _parseHistoryDate(String value) {
  final RegExpMatch? match = RegExp(
    r'^([A-Za-z]{3})\s+(\d{1,2}),\s*(\d{4})$',
  ).firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  final int month = monthNames.indexOf(match.group(1)!) + 1;
  final int? day = int.tryParse(match.group(2)!);
  final int? year = int.tryParse(match.group(3)!);
  if (month <= 0 || day == null || year == null) {
    return null;
  }
  return DateTime(year, month, day);
}

bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

double _tileWidth(double maxWidth, int count, double gap) {
  if (count <= 1) {
    return maxWidth;
  }
  return (maxWidth - gap * (count - 1)) / count;
}

class AppCard extends StatelessWidget {
  AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _PhoneLinkSetupScreen extends StatefulWidget {
  const _PhoneLinkSetupScreen({required this.email});

  final String email;

  @override
  State<_PhoneLinkSetupScreen> createState() => _PhoneLinkSetupScreenState();
}

class _PhoneLinkSetupScreenState extends State<_PhoneLinkSetupScreen> {
  String _firstPin = '';
  String _entry = '';
  String? _errorText;
  bool _confirming = false;
  bool _useBiometrics = true;

  void _appendDigit(String digit) {
    if (_entry.length >= 6) {
      return;
    }
    final String next = '$_entry$digit';
    setState(() {
      _entry = next;
      _errorText = null;
    });
    if (next.length == 6) {
      _handleCompleteEntry(next);
    }
  }

  void _handleCompleteEntry(String pin) {
    if (!_confirming) {
      setState(() {
        _firstPin = pin;
        _entry = '';
        _confirming = true;
      });
      return;
    }
    if (pin == _firstPin) {
      Navigator.of(
        context,
      ).pop(_PhoneLinkSetup(pin: pin, useBiometrics: _useBiometrics));
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _firstPin = '';
      _entry = '';
      _confirming = false;
      _errorText = 'PINs did not match. Create it again.';
    });
  }

  void _backspace() {
    if (_entry.isEmpty) {
      return;
    }
    setState(() {
      _entry = _entry.substring(0, _entry.length - 1);
      _errorText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxHeight < 700;
            final double buttonSize = compact ? 58 : 66;
            return Center(
              child: SizedBox(
                width: math.min(430, constraints.maxWidth),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    compact ? 10 : 18,
                    24,
                    compact ? 18 : 28,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(0, constraints.maxHeight - 36),
                    ),
                    child: Column(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Spacer(),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                              ),
                              child: Text('Not now'),
                            ),
                          ],
                        ),
                        SizedBox(height: compact ? 8 : 20),
                        BrandMark(size: compact ? 52 : 62),
                        SizedBox(height: compact ? 14 : 20),
                        Text(
                          _confirming
                              ? 'Confirm your phone PIN'
                              : 'Create your phone PIN',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: compact ? 24 : 28,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                            letterSpacing: 0,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          widget.email,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                        SizedBox(height: compact ? 26 : 44),
                        _PinDots(filledCount: _entry.length),
                        SizedBox(height: 14),
                        SizedBox(
                          height: 42,
                          child: Center(
                            child: Text(
                              _errorText ??
                                  (_confirming
                                      ? 'Enter the same 6 digits again.'
                                      : 'This PIN unlocks FruityVens on this phone.'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _errorText == null
                                    ? AppColors.textSecondary
                                    : AppColors.pinkText,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: compact ? 8 : 14),
                        _BiometricFirstToggle(
                          value: _useBiometrics,
                          onChanged: (bool value) {
                            setState(() {
                              _useBiometrics = value;
                            });
                          },
                        ),
                        SizedBox(height: compact ? 18 : 28),
                        _PhonePinPad(
                          buttonSize: buttonSize,
                          onDigit: _appendDigit,
                          onBackspace: _backspace,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PhoneLinkUnlockScreen extends StatefulWidget {
  const _PhoneLinkUnlockScreen({
    required this.email,
    required this.biometricsEnabled,
    required this.verifyPin,
    required this.onBiometricUnlock,
  });

  final String email;
  final bool biometricsEnabled;
  final bool Function(String pin) verifyPin;
  final Future<bool> Function() onBiometricUnlock;

  @override
  State<_PhoneLinkUnlockScreen> createState() => _PhoneLinkUnlockScreenState();
}

class _PhoneLinkUnlockScreenState extends State<_PhoneLinkUnlockScreen> {
  String _entry = '';
  String? _errorText;
  bool _biometricBusy = false;

  void _appendDigit(String digit) {
    if (_entry.length >= 6) {
      return;
    }
    final String next = '$_entry$digit';
    setState(() {
      _entry = next;
      _errorText = null;
    });
    if (next.length == 6) {
      _submitPin(next);
    }
  }

  void _submitPin(String pin) {
    if (widget.verifyPin(pin)) {
      Navigator.of(context).pop('unlock');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _entry = '';
      _errorText = 'Incorrect PIN. Try again.';
    });
  }

  void _backspace() {
    if (_entry.isEmpty) {
      return;
    }
    setState(() {
      _entry = _entry.substring(0, _entry.length - 1);
      _errorText = null;
    });
  }

  Future<void> _tryBiometrics() async {
    if (!widget.biometricsEnabled || _biometricBusy) {
      return;
    }
    setState(() {
      _biometricBusy = true;
      _errorText = null;
    });
    final bool unlocked = await widget.onBiometricUnlock();
    if (!mounted) {
      return;
    }
    if (unlocked) {
      Navigator.of(context).pop('biometric');
      return;
    }
    setState(() {
      _biometricBusy = false;
      _errorText = 'Biometrics did not unlock. Use PIN or try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxHeight < 700;
            final double buttonSize = compact ? 58 : 66;
            return Center(
              child: SizedBox(
                width: math.min(430, constraints.maxWidth),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    compact ? 18 : 32,
                    24,
                    compact ? 18 : 28,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(0, constraints.maxHeight - 46),
                    ),
                    child: Column(
                      children: <Widget>[
                        BrandMark(size: compact ? 52 : 62),
                        SizedBox(height: compact ? 18 : 28),
                        Text(
                          'Ready when you are',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: compact ? 25 : 30,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                            letterSpacing: 0,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          widget.email,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                        SizedBox(height: compact ? 34 : 56),
                        _PinDots(filledCount: _entry.length),
                        SizedBox(height: 14),
                        SizedBox(
                          height: 42,
                          child: Center(
                            child: Text(
                              _errorText ?? 'Enter your 6-digit phone PIN.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _errorText == null
                                    ? AppColors.textSecondary
                                    : AppColors.pinkText,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: compact ? 30 : 58),
                        _PhonePinPad(
                          buttonSize: buttonSize,
                          onDigit: _appendDigit,
                          onBackspace: _backspace,
                          leading: widget.biometricsEnabled
                              ? _PinPadIconButton(
                                  size: buttonSize,
                                  tooltip: 'Use biometrics',
                                  icon: _biometricBusy
                                      ? null
                                      : Icons.fingerprint_rounded,
                                  onPressed: _tryBiometrics,
                                  child: _biometricBusy
                                      ? SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppColors.orangeText,
                                          ),
                                        )
                                      : null,
                                )
                              : SizedBox(width: buttonSize, height: buttonSize),
                        ),
                        SizedBox(height: compact ? 14 : 24),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: <Widget>[
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pop('password'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.orangeText,
                              ),
                              child: Text('Use password'),
                            ),
                            Text(
                              'or',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pop('switch'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                              ),
                              child: Text('Switch account'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BiometricFirstToggle extends StatelessWidget {
  const _BiometricFirstToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.palm.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.fingerprint_rounded,
              color: AppColors.greenText,
              size: 21,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Use biometrics first',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  'PIN stays ready as backup.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.palm,
          ),
        ],
      ),
    );
  }
}

class _PhoneUnlockGate extends StatelessWidget {
  const _PhoneUnlockGate({
    required this.email,
    required this.biometricsEnabled,
  });

  final String? email;
  final bool biometricsEnabled;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgBase,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const BrandMark(size: 64),
                SizedBox(height: 22),
                Text(
                  'Authentication required',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  email == null || email!.isEmpty
                      ? 'Unlock this linked phone to continue.'
                      : 'Unlock ${email!} on this phone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                SizedBox(height: 26),
                SizedBox(
                  width: 124,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(999),
                    backgroundColor: AppColors.bgSurface,
                    color: biometricsEnabled
                        ? AppColors.greenText
                        : AppColors.orangeText,
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  biometricsEnabled
                      ? 'Biometrics will open first. PIN is ready as backup.'
                      : 'Your 6-digit phone PIN is ready.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filledCount});

  final int filledCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(6, (int index) {
        final bool filled = index < filledCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: filled ? 16 : 14,
          height: filled ? 16 : 14,
          decoration: BoxDecoration(
            color: filled
                ? AppColors.orangeText
                : AppColors.textSecondary.withValues(alpha: 0.26),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}

class _PhonePinPad extends StatelessWidget {
  const _PhonePinPad({
    required this.buttonSize,
    required this.onDigit,
    required this.onBackspace,
    this.leading,
  });

  final double buttonSize;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _row(<Widget>[_digit('1'), _digit('2'), _digit('3')]),
        SizedBox(height: 16),
        _row(<Widget>[_digit('4'), _digit('5'), _digit('6')]),
        SizedBox(height: 16),
        _row(<Widget>[_digit('7'), _digit('8'), _digit('9')]),
        SizedBox(height: 16),
        _row(<Widget>[
          leading ?? SizedBox(width: buttonSize, height: buttonSize),
          _digit('0'),
          _PinPadIconButton(
            size: buttonSize,
            tooltip: 'Delete',
            icon: Icons.backspace_outlined,
            onPressed: onBackspace,
          ),
        ]),
      ],
    );
  }

  Widget _row(List<Widget> children) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
    );
  }

  Widget _digit(String digit) {
    return _PinPadTextButton(
      size: buttonSize,
      label: digit,
      onPressed: () => onDigit(digit),
    );
  }
}

class _PinPadTextButton extends StatelessWidget {
  const _PinPadTextButton({
    required this.size,
    required this.label,
    required this.onPressed,
  });

  final double size;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 30,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinPadIconButton extends StatelessWidget {
  const _PinPadIconButton({
    required this.size,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.child,
  });

  final double size;
  final String tooltip;
  final IconData? icon;
  final Widget? child;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child:
                  child ??
                  Icon(icon, color: AppColors.textSecondary, size: size * 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

class FloatingGlassSplash extends StatefulWidget {
  const FloatingGlassSplash({super.key});

  @override
  State<FloatingGlassSplash> createState() => _FloatingGlassSplashState();
}

class _FloatingGlassSplashState extends State<FloatingGlassSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _hover;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat(reverse: true);
    _hover = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _glow = CurvedAnimation(parent: _controller, curve: Curves.easeOutSine);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF071409),
            AppColors.bgBase,
            Color(0xFF172918),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: CustomPaint(painter: _GlassSplashPainter())),
          Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final double lift = ui.lerpDouble(-8, 8, _hover.value)!;
                final double glow = ui.lerpDouble(0.20, 0.38, _glow.value)!;
                return Transform.translate(
                  offset: Offset(0, lift),
                  child: Container(
                    width: 236,
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                        width: 0.8,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: AppColors.palm.withValues(alpha: glow),
                          blurRadius: 34,
                          spreadRadius: 1,
                          offset: const Offset(0, 18),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.34),
                          blurRadius: 40,
                          offset: const Offset(0, 22),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const BrandMark(size: 68),
                            SizedBox(height: 18),
                            Text(
                              'FruityVens',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            SizedBox(height: 7),
                            Text(
                              'Smart fruit sales',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textSecondary.withValues(
                                  alpha: 0.92,
                                ),
                                letterSpacing: 0,
                              ),
                            ),
                            SizedBox(height: 18),
                            SizedBox(
                              width: 96,
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(999),
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.12,
                                ),
                                color: AppColors.orangeText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassSplashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.06);
    final Paint greenPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 42
      ..strokeCap = StrokeCap.round
      ..color = AppColors.palm.withValues(alpha: 0.08);
    final Paint amberPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26
      ..strokeCap = StrokeCap.round
      ..color = AppColors.orange.withValues(alpha: 0.07);

    canvas.drawLine(
      Offset(size.width * 0.14, size.height * 0.18),
      Offset(size.width * 0.86, size.height * 0.08),
      linePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.82),
      Offset(size.width * 0.92, size.height * 0.72),
      linePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.78, size.height * 0.18),
      Offset(size.width * 0.30, size.height * 0.92),
      greenPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.16, size.height * 0.30),
      Offset(size.width * 0.72, size.height * 0.68),
      amberPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GlassSplashPainter oldDelegate) => false;
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.palm.withValues(alpha: 0.20),
        border: Border.all(
          color: AppColors.palm.withValues(alpha: 0.45),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(size > 40 ? 12 : 7),
      ),
      child: Icon(
        Icons.bubble_chart_rounded,
        color: AppColors.palm,
        size: size * 0.54,
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffix,
    this.textInputAction,
    this.onSubmitted,
    this.inputFormatters,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final IconData? prefixIcon;
  final Widget? suffix;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: TextStyle(
        color: enabled ? AppColors.textPrimary : AppColors.textMuted,
        fontSize: 14,
      ),
      decoration: appInputDecoration(
        label: label,
        hint: hint,
        prefixIcon: prefixIcon,
        suffix: suffix,
      ),
    );
  }
}

class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.itemLabel,
  });

  final T? value;
  final List<T> items;
  final ValueChanged<T?>? onChanged;
  final String? hint;
  final String Function(T value)? itemLabel;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: AppColors.bgRaised,
      iconEnabledColor: AppColors.textSecondary,
      style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
      decoration: appInputDecoration(label: '', hint: hint ?? ''),
      hint: hint == null ? null : Text(hint!, overflow: TextOverflow.ellipsis),
      items: items.map((T item) {
        return DropdownMenuItem<T>(
          value: item,
          child: Text(itemLabel?.call(item) ?? item.toString()),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}

InputDecoration appInputDecoration({
  required String label,
  required String hint,
  IconData? prefixIcon,
  Widget? suffix,
}) {
  return InputDecoration(
    labelText: label.isEmpty ? null : label,
    hintText: hint,
    hintStyle: TextStyle(color: AppColors.textMuted),
    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 13),
    prefixIcon: prefixIcon == null
        ? null
        : Icon(prefixIcon, color: AppColors.textSecondary, size: 20),
    suffixIcon: suffix,
    filled: true,
    fillColor: AppColors.bgSurface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.borderMid, width: 0.5),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.orange, width: 1),
    ),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.expanded = false,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool expanded;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Widget button = FilledButton.icon(
      onPressed: onPressed,
      icon: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.bgBase,
              ),
            )
          : Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.palm,
        foregroundColor: AppColors.bgBase,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          backgroundColor: AppColors.bgSurface,
          side: BorderSide(color: AppColors.borderMid, width: 0.5),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.orangeText,
                ),
              )
            else
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.sand,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  'G',
                  style: TextStyle(
                    color: AppColors.bgBase,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            SizedBox(width: 10),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.highlighted = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: highlighted
            ? AppColors.orangeText
            : AppColors.textSecondary,
        backgroundColor: highlighted ? AppColors.orangeDim : AppColors.bgCard,
        side: BorderSide(
          color: highlighted ? AppColors.borderStrong : AppColors.borderMid,
          width: 0.5,
        ),
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class PeriodButton extends StatelessWidget {
  const PeriodButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected
            ? AppColors.textPrimary
            : AppColors.textSecondary,
        backgroundColor: selected ? AppColors.bgRaised : AppColors.bgCard,
        side: BorderSide(
          color: selected ? AppColors.borderStrong : AppColors.borderMid,
          width: 0.5,
        ),
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label),
    );
  }
}

class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.metrics,
    this.maxColumns = 4,
    this.minColumns = 1,
  });

  final List<MetricData> metrics;
  final int maxColumns;
  final int minColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int responsiveCount = constraints.maxWidth >= 740
            ? 4
            : constraints.maxWidth >= 460
            ? 2
            : 1;
        final int count = math.min(
          maxColumns,
          math.max(minColumns, responsiveCount),
        );
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: metrics.map((MetricData metric) {
            return SizedBox(
              width: _tileWidth(constraints.maxWidth, count, 10),
              child: MetricCard(metric: metric),
            );
          }).toList(),
        );
      },
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({super.key, required this.metric});

  final MetricData metric;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            metric.label,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          SizedBox(height: 5),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(
              metric.value,
              style: TextStyle(
                color: metric.valueColor ?? AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (metric.subtext.isNotEmpty) ...<Widget>[
            SizedBox(height: 3),
            Text(
              metric.subtext,
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.onTap,
    this.locked = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final Color effectiveColor = locked ? AppColors.textMuted : color;
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(
                color: locked ? AppColors.borderMid : AppColors.borderSoft,
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: effectiveColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    locked ? Icons.lock_outline_rounded : icon,
                    color: effectiveColor,
                  ),
                ),
                SizedBox(height: 10),
                if (locked) ...<Widget>[
                  Text(
                    'LOCKED',
                    style: TextStyle(
                      color: AppColors.orangeText,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 4),
                ],
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                SizedBox(height: 5),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppDataTable extends StatelessWidget {
  const AppDataTable({super.key, required this.columns, required this.rows});

  final List<String> columns;
  final List<List<Widget>> rows;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double tableWidth = math.max(660, constraints.maxWidth);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              children: <Widget>[
                _tableRow(
                  columns.map((String column) {
                    return Text(
                      column,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  }).toList(),
                  header: true,
                ),
                ...rows.map(_tableRow),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tableRow(List<Widget> cells, {bool header = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSoft, width: 0.5),
        ),
      ),
      child: Row(
        children: cells.map((Widget cell) {
          return Expanded(
            child: DefaultTextStyle(
              style: TextStyle(
                color: header ? AppColors.textSecondary : AppColors.textPrimary,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
              child: cell,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  StatusBadge.green(this.label, {super.key})
    : background = AppColors.palm.withValues(alpha: 0.22),
      foreground = AppColors.greenText;

  StatusBadge.orange(this.label, {super.key})
    : background = AppColors.orange.withValues(alpha: 0.20),
      foreground = AppColors.orangeText;

  StatusBadge.red(this.label, {super.key})
    : background = AppColors.pink.withValues(alpha: 0.24),
      foreground = AppColors.pinkText;

  StatusBadge.blue(this.label, {super.key})
    : background = AppColors.palm.withValues(alpha: 0.15),
      foreground = AppColors.textSecondary;

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class TopFruitRanking extends StatelessWidget {
  const TopFruitRanking({super.key, required this.ranks});

  final List<FruitRank> ranks;

  static const List<Color> _rankColors = <Color>[
    Color(0xFFFFD54F),
    Color(0xFFB0BEC5),
    Color(0xFFD08A4E),
  ];

  @override
  Widget build(BuildContext context) {
    final int maxRevenue = ranks.isEmpty ? 0 : ranks.first.revenuePhp;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.emoji_events_rounded,
                color: AppColors.orangeText,
                size: 17,
              ),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Daily restock ranking',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          if (ranks.isEmpty)
            const _TopFruitEmptyState()
          else
            ...ranks.asMap().entries.map((MapEntry<int, FruitRank> entry) {
              return Padding(
                padding: EdgeInsets.only(top: entry.key == 0 ? 0 : 7),
                child: _TopFruitRankRow(
                  rank: entry.key + 1,
                  fruit: entry.value,
                  color: _rankColors[entry.key],
                  maxRevenue: maxRevenue,
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _TopFruitRankRow extends StatelessWidget {
  const _TopFruitRankRow({
    required this.rank,
    required this.fruit,
    required this.color,
    required this.maxRevenue,
  });

  final int rank;
  final FruitRank fruit;
  final Color color;
  final int maxRevenue;

  @override
  Widget build(BuildContext context) {
    final double rawFill = maxRevenue <= 0 ? 0 : fruit.revenuePhp / maxRevenue;
    final double fill = rawFill <= 0 ? 0.12 : rawFill.clamp(0.18, 1.0);
    final StatusBadge restockBadge = switch (rank) {
      1 => StatusBadge.red('Heavy restock'),
      2 => StatusBadge.orange('Medium restock'),
      _ => StatusBadge.green('Light top-up'),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Container(color: AppColors.bgCard.withValues(alpha: 0.66)),
          ),
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fill,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderSoft, width: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    border: Border.all(
                      color: color.withValues(alpha: 0.72),
                      width: 0.5,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$rank',
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.bgSurface,
                    border: Border.all(color: AppColors.borderSoft, width: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: FruitMark(name: fruit.name, size: 20),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        fruit.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 1),
                      Text(
                        'Avg ${fruit.averageWeightLabel}/sale - ${fruit.transactions} sales',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    restockBadge,
                    SizedBox(height: 4),
                    Text(
                      money(fruit.revenuePhp),
                      style: TextStyle(
                        color: AppColors.orangeText,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 1),
                    Text(
                      fruit.weightLabel,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopFruitEmptyState extends StatelessWidget {
  const _TopFruitEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bgCard.withValues(alpha: 0.60),
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.point_of_sale_rounded,
            color: AppColors.textMuted,
            size: 18,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'No fruit sales yet',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Rankings will appear after your first sale.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InventoryFruitCard extends StatelessWidget {
  const _InventoryFruitCard({
    required this.fruit,
    required this.price,
    required this.priceConfigured,
    required this.restockSignal,
    required this.expanded,
    required this.readOnly,
    required this.priceController,
    required this.priceFocusNode,
    required this.onToggle,
    required this.onPriceTyped,
    required this.onPriceDown,
    required this.onPriceUp,
    required this.onSave,
  });

  final FruitInfo fruit;
  final int price;
  final bool priceConfigured;
  final _RestockSignal restockSignal;
  final bool expanded;
  final bool readOnly;
  final TextEditingController priceController;
  final FocusNode priceFocusNode;
  final VoidCallback onToggle;
  final ValueChanged<String> onPriceTyped;
  final VoidCallback onPriceDown;
  final VoidCallback onPriceUp;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: expanded
                        ? AppColors.orange.withValues(alpha: 0.14)
                        : AppColors.palm.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: FruitMark(name: fruit.name, size: 24),
                ),
                SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        fruit.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 1),
                      Text(
                        priceConfigured || price > 0
                            ? '${money(price)}/kg'
                            : 'Set price per kg',
                        style: TextStyle(
                          color: priceConfigured || price > 0
                              ? AppColors.textSecondary
                              : AppColors.orangeText,
                          fontSize: 11,
                          fontWeight: priceConfigured || price > 0
                              ? FontWeight.w500
                              : FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                restockSignal.badge,
                SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppColors.textSecondary,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            firstChild: SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.bgRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderSoft),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        restockSignal.label,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        restockSignal.detail,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 9),
                SmartStepper(
                  label: 'Enter price / kg',
                  value: price > 0 ? money(price) : 'Set price',
                  controller: priceController,
                  focusNode: priceFocusNode,
                  hint: '90.00',
                  enabled: !readOnly,
                  onChanged: onPriceTyped,
                  onSubmitted: (_) => onSave(),
                  textInputAction: TextInputAction.done,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onMinus: readOnly ? null : onPriceDown,
                  onPlus: readOnly ? null : onPriceUp,
                ),
                SizedBox(height: 8),
                if (readOnly)
                  Text(
                    'Preview only in Demo Mode.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  PrimaryButton(
                    label: 'Save',
                    icon: Icons.check_rounded,
                    onPressed: onSave,
                    expanded: true,
                  ),
              ],
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
            firstCurve: Curves.easeOutCubic,
            secondCurve: Curves.easeOutCubic,
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

class _InventoryEmptySignal extends StatelessWidget {
  const _InventoryEmptySignal();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.insights_rounded,
            color: AppColors.textSecondary,
            size: 19,
          ),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'No fruit sales yet. Restock priority is waiting.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SmartStepper extends StatelessWidget {
  const SmartStepper({
    super.key,
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.controller,
    this.focusNode,
    this.hint,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.keyboardType,
    this.inputFormatters,
  });

  final String label;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                  ),
                ),
                SizedBox(height: 1),
                if (controller == null)
                  Text(
                    value,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  )
                else
                  TextField(
                    controller: controller,
                    focusNode: focusNode,
                    enabled: enabled,
                    keyboardType: keyboardType,
                    textInputAction: textInputAction,
                    inputFormatters: inputFormatters,
                    scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 300),
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    style: TextStyle(
                      color: enabled
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: hint ?? value,
                      hintStyle: TextStyle(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                      prefixText: 'PHP ',
                      suffixText: '/kg',
                      prefixStyle: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      suffixStyle: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SquareButton(icon: Icons.remove_rounded, onPressed: onMinus),
          SizedBox(width: 6),
          SquareButton(icon: Icons.add_rounded, onPressed: onPlus),
        ],
      ),
    );
  }
}

class GuidedActionRow extends StatelessWidget {
  const GuidedActionRow({
    super.key,
    required this.fruitName,
    required this.title,
    required this.detail,
    required this.badge,
  });

  final String fruitName;
  final String title;
  final String detail;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return BorderRow(
      child: Row(
        children: <Widget>[
          FruitMark(name: fruitName, size: 24),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          badge,
        ],
      ),
    );
  }
}

class _AnalyticsEmptyState extends StatelessWidget {
  const _AnalyticsEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.query_stats_rounded,
            color: AppColors.textSecondary,
            size: 19,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForecastEmptyState extends StatelessWidget {
  const _ForecastEmptyState();

  @override
  Widget build(BuildContext context) {
    return BorderRow(
      child: Row(
        children: <Widget>[
          Icon(Icons.insights_rounded, color: AppColors.textMuted, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No sales pattern yet.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForecastChartEmptyState extends StatelessWidget {
  const _ForecastChartEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.show_chart_rounded, color: AppColors.textMuted, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No sales to project yet.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ForecastTile extends StatelessWidget {
  const ForecastTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.note,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String value;
  final String note;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.orangeText, size: 20),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  note,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          badge,
        ],
      ),
    );
  }
}

class HistoryTransactionCard extends StatelessWidget {
  const HistoryTransactionCard({
    super.key,
    required this.transaction,
    this.onManage,
  });

  final TransactionData transaction;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final bool cancelled = transaction.status == 'Cancelled';
    final VoidCallback? manageAction = onManage;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        border: Border.all(color: AppColors.borderSoft, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: cancelled
                  ? AppColors.pink.withValues(alpha: 0.14)
                  : AppColors.palm.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: FruitMark(
              name: transaction.fruit,
              size: 23,
              muted: cancelled,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${transaction.fruit} - ${transaction.date}',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  '${transaction.weight} · ${transaction.time}',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                transaction.price,
                style: TextStyle(
                  color: AppColors.orangeText,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 5),
              cancelled ? StatusBadge.red('Void') : StatusBadge.green('Done'),
            ],
          ),
          if (manageAction != null) ...<Widget>[
            SizedBox(width: 4),
            IconButton(
              tooltip: 'Manage sale',
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: manageAction,
              icon: Icon(
                Icons.more_vert_rounded,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class BorderRow extends StatelessWidget {
  const BorderRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSoft, width: 0.5),
        ),
      ),
      child: child,
    );
  }
}

class SquareButton extends StatelessWidget {
  const SquareButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: onPressed == null
              ? AppColors.textMuted
              : AppColors.textPrimary,
          backgroundColor: AppColors.bgRaised,
          side: BorderSide(color: AppColors.borderMid, width: 0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Icon(icon, size: 18),
      ),
    );
  }
}

class FruitChip extends StatelessWidget {
  const FruitChip({super.key, required this.label, required this.onRemove});

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.borderMid, width: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FruitMark(name: label, size: 18),
          SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.close_rounded,
                size: 16,
                color: AppColors.pinkText,
              ),
              tooltip: 'Remove $label',
            ),
        ],
      ),
    );
  }
}

class ForecastRow extends StatelessWidget {
  const ForecastRow({
    super.key,
    required this.icon,
    required this.name,
    required this.value,
    required this.badge,
  });

  final IconData icon;
  final String name;
  final String value;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return BorderRow(
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: AppColors.greenText, size: 19),
              SizedBox(width: 8),
              Text(name),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                value,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              SizedBox(width: 8),
              badge,
            ],
          ),
        ],
      ),
    );
  }
}

class RestockRow extends StatelessWidget {
  const RestockRow({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return BorderRow(
      child: Row(
        children: <Widget>[
          Icon(icon, color: AppColors.greenText, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          badge,
        ],
      ),
    );
  }
}

class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.labels, required this.colors});

  final List<String> labels;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: List<Widget>.generate(labels.length, (int index) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: colors[index],
                borderRadius: BorderRadius.circular(2),
                border: colors[index] == AppColors.sand
                    ? Border.all(
                        color: AppColors.sand.withValues(alpha: 0.4),
                        width: 0.5,
                      )
                    : null,
              ),
            ),
            SizedBox(width: 5),
            Text(
              labels[index],
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        );
      }),
    );
  }
}

class StackedBarChart extends StatelessWidget {
  const StackedBarChart({
    super.key,
    required this.labels,
    required this.series,
    required this.colors,
    this.valuePrefix = '',
    this.valueSuffix = '',
    this.valueFormatter,
    this.showValueLabels = false,
  });

  final List<String> labels;
  final List<List<num>> series;
  final List<Color> colors;
  final String valuePrefix;
  final String valueSuffix;
  final String Function(num value)? valueFormatter;
  final bool showValueLabels;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 230,
      width: double.infinity,
      child: CustomPaint(
        painter: StackedBarPainter(
          labels: labels,
          series: series,
          colors: colors,
          valuePrefix: valuePrefix,
          valueSuffix: valueSuffix,
          valueFormatter: valueFormatter,
          showValueLabels: showValueLabels,
        ),
      ),
    );
  }
}

class StackedBarPainter extends CustomPainter {
  const StackedBarPainter({
    required this.labels,
    required this.series,
    required this.colors,
    required this.valuePrefix,
    required this.valueSuffix,
    required this.valueFormatter,
    required this.showValueLabels,
  });

  final List<String> labels;
  final List<List<num>> series;
  final List<Color> colors;
  final String valuePrefix;
  final String valueSuffix;
  final String Function(num value)? valueFormatter;
  final bool showValueLabels;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty || series.isEmpty) {
      return;
    }
    final double topPadding = showValueLabels ? 30 : 14;
    const double bottomPadding = 34;
    const double leftPadding = 6;
    const double rightPadding = 6;
    final double chartHeight = size.height - topPadding - bottomPadding;
    final double chartWidth = size.width - leftPadding - rightPadding;
    final List<num> totals = List<num>.generate(labels.length, (int index) {
      return series.fold<num>(
        0,
        (num sum, List<num> item) => sum + item[index],
      );
    });
    final num maxTotal = totals.reduce(math.max);
    if (maxTotal <= 0) {
      return;
    }
    final double scaleMax = maxTotal.toDouble() * 1.18;

    final Paint gridPaint = Paint()
      ..color = AppColors.palm.withValues(alpha: 0.13)
      ..strokeWidth = 1;
    final Paint axisPaint = Paint()
      ..color = AppColors.borderSoft
      ..strokeWidth = 1;

    for (int i = 0; i <= 3; i++) {
      final double y = topPadding + chartHeight * (i / 3);
      canvas.drawLine(
        Offset(leftPadding, y),
        Offset(size.width - rightPadding, y),
        gridPaint,
      );
    }
    canvas.drawLine(
      Offset(leftPadding, topPadding + chartHeight),
      Offset(size.width - rightPadding, topPadding + chartHeight),
      axisPaint,
    );

    final double groupWidth = chartWidth / labels.length;
    final double barWidth = math.min(34, groupWidth * 0.54);
    for (int index = 0; index < labels.length; index++) {
      final double centerX = leftPadding + groupWidth * index + groupWidth / 2;
      double yCursor = topPadding + chartHeight;
      for (int seriesIndex = 0; seriesIndex < series.length; seriesIndex++) {
        final num value = series[seriesIndex][index];
        final double height = chartHeight * value.toDouble() / scaleMax;
        final Rect segment = Rect.fromLTWH(
          centerX - barWidth / 2,
          yCursor - height,
          barWidth,
          height,
        );
        final RRect rounded = RRect.fromRectAndRadius(
          segment,
          const Radius.circular(4),
        );
        final Paint paint = Paint()
          ..color = colors[seriesIndex % colors.length];
        canvas.drawRRect(rounded, paint);
        yCursor -= height;
      }

      if (showValueLabels) {
        _drawFittedText(
          canvas,
          _formatChartValue(totals[index]),
          Offset(centerX, math.max(2, yCursor - 17)),
          TextStyle(
            color: AppColors.textPrimary,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
          maxWidth: math.max(barWidth + 14, groupWidth - 2),
        );
      }

      _drawText(
        canvas,
        labels[index],
        Offset(centerX, size.height - 18),
        TextStyle(color: AppColors.textMuted, fontSize: 10),
      );
    }

    if (!showValueLabels) {
      _drawText(
        canvas,
        _formatChartValue(maxTotal),
        const Offset(leftPadding, 0),
        TextStyle(color: AppColors.textMuted, fontSize: 10),
        align: TextAlign.left,
      );
    }
  }

  String _formatChartValue(num value) {
    final String Function(num value)? formatter = valueFormatter;
    if (formatter != null) {
      return formatter(value);
    }
    return '$valuePrefix${_formatChartNumber(value)}$valueSuffix';
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    TextAlign align = TextAlign.center,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 90);
    final double dx = align == TextAlign.center
        ? offset.dx - painter.width / 2
        : offset.dx;
    painter.paint(canvas, Offset(dx, offset.dy));
  }

  void _drawFittedText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    required double maxWidth,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '',
    )..layout(maxWidth: maxWidth);
    if (painter.didExceedMaxLines || painter.width > maxWidth) {
      return;
    }
    painter.paint(canvas, Offset(offset.dx - painter.width / 2, offset.dy));
  }

  @override
  bool shouldRepaint(covariant StackedBarPainter oldDelegate) {
    return oldDelegate.labels != labels ||
        oldDelegate.series != series ||
        oldDelegate.valuePrefix != valuePrefix ||
        oldDelegate.valueSuffix != valueSuffix ||
        oldDelegate.showValueLabels != showValueLabels;
  }
}

class DonutChart extends StatelessWidget {
  const DonutChart({super.key, required this.values, required this.colors});

  final List<int> values;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: DonutChartPainter(values: values, colors: colors),
      child: Center(
        child: Text(
          money(values.fold<int>(0, (int sum, int value) => sum + value)),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class DonutChartPainter extends CustomPainter {
  const DonutChartPainter({required this.values, required this.colors});

  final List<int> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 - 15;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    final int total = values.fold<int>(0, (int sum, int value) => sum + value);
    double startAngle = -math.pi / 2;

    final Paint basePaint = Paint()
      ..color = AppColors.bgSurface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, basePaint);

    for (int index = 0; index < values.length; index++) {
      final double sweep = (values[index] / total) * math.pi * 2;
      final Paint paint = Paint()
        ..color = colors[index % colors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, startAngle, sweep, false, paint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutChartPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}
