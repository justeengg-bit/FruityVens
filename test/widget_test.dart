import 'package:flutter/material.dart'
    show CalendarDatePicker, DropdownButtonFormField, Switch;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/data/app_database.dart';
import 'package:fruityvens_app/main.dart';
import 'package:fruityvens_app/services/ai_automation_client.dart';
import 'package:fruityvens_app/services/cdo_sample_sales_service.dart';
import 'package:fruityvens_app/services/daily_sales_report_service.dart';
import 'package:fruityvens_app/services/report_export_service.dart';

class _CaptureReportExportService extends ReportExportService {
  ReportExportData? report;

  @override
  Future<ReportExportResult> export(ReportExportData data) async {
    report = data;
    return ReportExportResult(fileName: data.fileName, path: '', saved: false);
  }
}

class _NineFruitForecastClient extends AiAutomationClient {
  int calls = 0;
  int transactionCount = 0;

  @override
  Future<AiAutomationResult> generateForecast({
    required List<Map<String, Object?>> inventory,
    required Map<String, Object?> salesSnapshot,
    List<Map<String, Object?>> transactions = const <Map<String, Object?>>[],
    Map<String, Object?>? cameraEye,
  }) async {
    calls++;
    transactionCount = transactions.length;
    const List<String> fruits = <String>[
      'Apple',
      'Banana',
      'Grapes',
      'Mango Carabao',
      'Orange',
      'Papaya',
      'Pineapple',
      'Watermelon',
      'Calamansi',
    ];
    return AiAutomationResult(
      summary: 'Nine-fruit demand forecast.',
      model: 'Regression fixture',
      source: 'Test forecast service',
      forecastStart: DateTime(2026, 2, 16),
      forecastEnd: DateTime(2026, 2, 22),
      coverage: AiForecastCoverage(
        transactionCount: 30,
        observedDays: 30,
        dataStart: DateTime(2026, 1, 17),
        dataEnd: DateTime(2026, 2, 15),
        fruits: fruits,
      ),
      validation: const AiForecastValidation(evaluatedDays: 14, maeKg: 0.24),
      predictions: List<AiForecastPrediction>.generate(fruits.length, (
        int fruit,
      ) {
        final List<double> daily = List<double>.generate(
          7,
          (int day) => (fruit + 1).toDouble() + day / 10,
        );
        return AiForecastPrediction(
          fruit: fruits[fruit],
          predictedKgTomorrow: daily.first,
          predictedKgTotal: daily.fold<double>(
            0,
            (double a, double b) => a + b,
          ),
          dailyPredictions: daily,
          recommendation: 'Light top-up',
          confidence: 'High',
          reason:
              'Historical Q2 production in Northern Mindanao is above the annual average across six reference years.',
        );
      }),
    );
  }
}

void main() {
  Future<void> dismissPhoneLinkPrompt(WidgetTester tester) async {
    await tester.pumpAndSettle();
    if (find.text('Not now').evaluate().isNotEmpty) {
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> enterPhonePin(WidgetTester tester, String pin) async {
    for (final String digit in pin.split('')) {
      await tester.tap(find.text(digit).last);
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> createAccountAndOpenDashboard(
    WidgetTester tester, {
    String name = 'Khent Student',
    String email = 'student@phinmaed.com',
    String password = 'student123',
    bool dismissPhoneLink = true,
  }) async {
    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Create account'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), name);
    await tester.enterText(fields.at(1), email);
    await tester.enterText(fields.at(2), password);
    await tester.enterText(fields.at(3), password);
    await tester.ensureVisible(find.text('Create account').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account').last);
    await tester.pump(const Duration(seconds: 3));
    if (dismissPhoneLink) {
      await dismissPhoneLinkPrompt(tester);
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> openOperationsMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Open operations menu'));
    await tester.pumpAndSettle();
  }

  void expectGoogleBlockedBeforeSignIn() {
    final int warningCount =
        find
            .text(
              'Google sign-in needs internet. Connect to the internet, then try again.',
            )
            .evaluate()
            .length +
        find
            .text(
              'Google account picker is unavailable. Check Google sign-in setup or type an email for local fallback.',
            )
            .evaluate()
            .length;
    expect(warningCount, 1);
  }

  for (final Size viewport in <Size>[Size(360, 800), Size(900, 1000)]) {
    testWidgets(
      'Forecast stays readable at ${viewport.width.toInt()}px and keeps market outlook optional',
      (WidgetTester tester) async {
        final AppDatabase database = AppDatabase.inMemory();
        final DateTime now = DateTime.now();
        final DateTime today = DateTime(now.year, now.month, now.day, 12);
        for (int day = 0; day < 30; day++) {
          await database.addSale(
            fruitName: 'Mango',
            weightGrams: 1000,
            unitPrice: 6000,
            totalPrice: 6000,
            soldAt: today.subtract(Duration(days: day)),
          );
        }
        final _NineFruitForecastClient client = _NineFruitForecastClient();
        await tester.pumpWidget(
          FruityVensApp(database: database, aiAutomationClient: client),
        );
        await createAccountAndOpenDashboard(tester);
        await openOperationsMenu(tester);
        await tester.tap(find.text('Generate forecast'));
        await tester.pumpAndSettle();
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpAndSettle();
        final Finder generateButton = find.widgetWithText(
          PrimaryButton,
          'Generate forecast',
        );
        await tester.ensureVisible(generateButton);
        await tester.pumpAndSettle();
        await tester.tap(generateButton);
        await tester.pumpAndSettle();
        fruityVensMessengerKey.currentState?.hideCurrentSnackBar();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(client.calls, 1);
        expect(client.transactionCount, 30);
        expect(find.text('Nine-fruit demand forecast.'), findsNothing);
        expect(find.text('High confidence'), findsOneWidget);
        expect(
          find.text('333.90 kg projected across 9 fruits'),
          findsOneWidget,
        );
        expect(find.text('Tomorrow'), findsNothing);
        expect(find.text('Next 7 days'), findsNothing);
        expect(find.text('Fruit ranking'), findsOneWidget);
        expect(find.text('#1'), findsOneWidget);
        expect(find.text('65.10 kg | 19.5% of forecast'), findsOneWidget);
        expect(
          find.byKey(const PageStorageKey<String>('forecast-priority-Apple')),
          findsNothing,
        );
        expect(
          tester.getTopLeft(find.text('Calamansi')).dy,
          lessThan(tester.getTopLeft(find.text('Watermelon')).dy),
        );
        await tester.ensureVisible(find.text('Show all 9 fruits'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show all 9 fruits'));
        await tester.pumpAndSettle();
        expect(find.text('#9'), findsOneWidget);
        expect(find.text('9.10 kg | 2.7% of forecast'), findsOneWidget);
        await tester.ensureVisible(find.text('Show top 3'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show top 3'));
        await tester.pumpAndSettle();
        expect(find.text('#4'), findsNothing);
        expect(find.textContaining('Historical Q2 production'), findsNothing);
        expect(find.text('Price and supply'), findsNothing);
        expect(find.text('PSA'), findsNothing);
        expect(find.byType(StackedBarChart), findsNothing);
        await tester.ensureVisible(find.text('Daily breakdown'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Daily breakdown'));
        await tester.pumpAndSettle();
        final StackedBarChart chart = tester.widget<StackedBarChart>(
          find.byType(StackedBarChart),
        );
        final ChartLegend legend = tester.widget<ChartLegend>(
          find.byType(ChartLegend),
        );
        expect(chart.series, hasLength(5));
        expect(legend.labels.last, 'Other');
        expect(chart.labels, hasLength(7));
        expect(chart.labels.first.endsWith('Feb 16'), isTrue);
        expect(chart.labels.last.endsWith('Feb 22'), isTrue);
        for (int day = 0; day < 7; day++) {
          final num total = chart.series.fold<num>(
            0,
            (num sum, List<num> values) => sum + values[day],
          );
          expect(total, closeTo(45 + 0.9 * day, 0.000000001));
          expect(chart.series.last[day], closeTo(15 + 0.5 * day, 0.000000001));
        }
        final Finder priority = find.byKey(
          const PageStorageKey<String>('forecast-priority-Calamansi'),
        );
        await tester.ensureVisible(priority);
        await tester.pumpAndSettle();
        await tester.tap(priority);
        await tester.pumpAndSettle();
        expect(find.textContaining('Historical Q2 production'), findsOneWidget);

        await tester.ensureVisible(find.text('Forecast details'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Forecast details'));
        await tester.pumpAndSettle();
        expect(find.text('Nine-fruit demand forecast.'), findsOneWidget);
        expect(find.text('0.24 kg per fruit/day'), findsOneWidget);
        expect(find.text('Selling days'), findsOneWidget);
        expect(find.text('Sales period'), findsOneWidget);

        final Finder marketButton = find.widgetWithText(
          GhostButton,
          'CDO market outlook',
        );
        await tester.ensureVisible(marketButton);
        await tester.pumpAndSettle();
        await tester.tap(marketButton);
        await tester.pumpAndSettle();
        expect(find.text('Price and supply'), findsOneWidget);
        expect(find.text('Forecast summary'), findsNothing);
        expect(find.text('PSA'), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('Forecast summary'), findsOneWidget);
        expect(find.text('Price and supply'), findsNothing);
        expect(client.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final bool choosePastDay in <bool>[false, true]) {
    testWidgets(
      'Daily PDF ${choosePastDay ? 'exports selected day' : 'defaults to today'} without mixing history',
      (WidgetTester tester) async {
        final AppDatabase database = AppDatabase.inMemory();
        final DateTime today = DailySalesReportService.businessDay(
          DateTime.now(),
        );
        final DateTime yesterday = today.subtract(const Duration(days: 1));
        // Noon Manila is 04:00 UTC, independent of the test host timezone.
        await database.addSale(
          fruitName: 'Mango',
          weightGrams: 1250,
          unitPrice: 6000,
          totalPrice: 7500,
          soldAt: DateTime.utc(today.year, today.month, today.day, 4),
        );
        await database.addSale(
          fruitName: 'Banana',
          weightGrams: 2000,
          unitPrice: 3500,
          totalPrice: 7000,
          soldAt: DateTime.utc(
            yesterday.year,
            yesterday.month,
            yesterday.day,
            4,
          ),
        );
        final _CaptureReportExportService exporter =
            _CaptureReportExportService();
        await tester.pumpWidget(
          FruityVensApp(database: database, reportExportService: exporter),
        );
        await createAccountAndOpenDashboard(tester);
        await openOperationsMenu(tester);
        await tester.tap(find.text('Download PDF'));
        await tester.pumpAndSettle();
        expect(find.text('Daily sales PDF'), findsOneWidget);
        expect(find.textContaining('Today - '), findsOneWidget);
        expect(find.text('PHP 75.00'), findsWidgets);
        expect(find.text('1 completed sales'), findsOneWidget);
        expect(exporter.report, isNull);

        if (choosePastDay) {
          await tester.tap(find.textContaining('Today - '));
          await tester.pumpAndSettle();
          final CalendarDatePicker picker = tester.widget(
            find.byType(CalendarDatePicker),
          );
          expect(picker.lastDate, today);
          picker.onDateChanged(yesterday);
          await tester.tap(find.text('Use this day'));
          await tester.pumpAndSettle();
          expect(find.text('2.000 kg sold'), findsOneWidget);
        }
        await tester.tap(find.widgetWithText(PrimaryButton, 'Download PDF'));
        await tester.pumpAndSettle();
        final ReportExportData report = exporter.report!;
        expect(report.reportDate, choosePastDay ? yesterday : today);
        expect(
          report.transactions.single.fruit,
          choosePastDay ? 'Banana' : 'Mango',
        );
        expect(
          report.dailySummary!.revenueCentavos,
          choosePastDay ? 7000 : 7500,
        );
        expect(report.preparedBy, 'student@phinmaed.com');
        expect(tester.takeException(), isNull);

        await openOperationsMenu(tester);
        await tester.tap(find.text('Download PDF'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close report'));
        await tester.pumpAndSettle();
        expect(exporter.report, same(report));
      },
    );
  }

  testWidgets('Dashboard preserves grouped sale amounts', (
    WidgetTester tester,
  ) async {
    final AppDatabase database = AppDatabase.inMemory();
    await database.addSale(
      fruitName: 'Mango',
      weightGrams: 1234,
      unitPrice: 97245,
      totalPrice: 120000,
      soldAt: DateTime.now(),
    );
    await tester.pumpWidget(FruityVensApp(database: database));
    await createAccountAndOpenDashboard(tester);
    expect(find.text('PHP 1,200.00'), findsWidgets);
    expect(find.text('PHP 1.00'), findsNothing);
  });

  testWidgets(
    'Imported CDO history remains editable without an import button',
    (WidgetTester tester) async {
      final AppDatabase database = AppDatabase.inMemory();
      await database.addSale(
        fruitName: 'Mango',
        weightGrams: 1000,
        unitPrice: 10000,
        totalPrice: 10000,
        soldAt: DateTime.now(),
      );
      await tester.runAsync(() async {
        final dataset = await const CdoSampleSalesService().load();
        await dataset.importInto(database);
      });
      await tester.pumpWidget(FruityVensApp(database: database));
      await createAccountAndOpenDashboard(tester);
      await openOperationsMenu(tester);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(await database.getSalesTransactions(), hasLength(1250));
      expect(find.byTooltip('Manage sale'), findsWidgets);
      expect(find.textContaining('Includes generated CDO sales'), findsWidgets);
      expect(find.text('Add July–October sales'), findsNothing);
      expect(find.text('Use actual sales'), findsNothing);
      expect(find.text('Use CDO sample sales'), findsNothing);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await openOperationsMenu(tester);
      await tester.tap(find.text('View analytics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 days').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All time').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('PHP 170,438.24'), findsWidgets);
      final StackedBarChart chart = tester.widget<StackedBarChart>(
        find.byType(StackedBarChart).first,
      );
      expect(
        chart.series.expand((values) => values).fold<num>(0, (a, b) => a + b),
        17043824,
      );

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await openOperationsMenu(tester);
      await tester.tap(find.text('Generate forecast'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('CDO market outlook')).dy,
        greaterThan(tester.getTopLeft(find.text('What to do next')).dy),
      );
      expect(find.text('PSA'), findsNothing);
    },
  );

  testWidgets(
    'Analytics counts completed sales per fruit within the selected dates',
    (WidgetTester tester) async {
      final AppDatabase database = AppDatabase.inMemory();
      final DateTime now = DateTime.now();
      for (final entry in <String, int>{'Mango': 89, 'Banana': 31}.entries) {
        for (int i = 0; i < entry.value; i++) {
          await database.addSale(
            fruitName: entry.key,
            weightGrams: 500,
            unitPrice: 6000,
            totalPrice: 3000,
            soldAt: now,
          );
        }
      }
      for (int i = 0; i < 10; i++) {
        await database.addSale(
          fruitName: 'Mango',
          weightGrams: 1000,
          unitPrice: 6000,
          totalPrice: 6000,
          soldAt: now.subtract(const Duration(days: 45)),
        );
      }
      await database.addSale(
        fruitName: 'Mango',
        weightGrams: 1000,
        unitPrice: 6000,
        totalPrice: 6000,
        soldAt: now,
        status: 'cancelled',
      );
      await database.addSale(
        fruitName: 'Banana',
        weightGrams: 1000,
        unitPrice: 6000,
        totalPrice: 6000,
        soldAt: now,
        status: 'removed',
      );
      await tester.pumpWidget(FruityVensApp(database: database));
      await createAccountAndOpenDashboard(tester);
      await openOperationsMenu(tester);
      await tester.tap(find.text('View analytics'));
      await tester.pumpAndSettle();
      final Finder mangoRow = find.byKey(
        const ValueKey<String>('analytics-sales-count-Mango'),
      );
      final Finder bananaRow = find.byKey(
        const ValueKey<String>('analytics-sales-count-Banana'),
      );
      expect(
        find.descendant(of: mangoRow, matching: find.text('89 sales')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bananaRow, matching: find.text('31 sales')),
        findsOneWidget,
      );
      expect(find.textContaining('120 completed sales'), findsOneWidget);
      await tester.tap(find.text('Last 7 days').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All time').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: mangoRow, matching: find.text('99 sales')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bananaRow, matching: find.text('31 sales')),
        findsOneWidget,
      );
      expect(find.textContaining('130 completed sales'), findsOneWidget);
    },
  );

  testWidgets('FruityVens login smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    expect(find.text('FruityVens'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Vendor or student email'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('OTHER OPTIONS'), findsOneWidget);
    expect(find.text('Guest Mode'), findsOneWidget);
    expect(find.text('Biometrics'), findsNothing);
  });

  testWidgets('Google sign-in warns when internet is unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await tester.tap(find.text('Continue with Google'));
    await tester.pump(const Duration(seconds: 4));

    expectGoogleBlockedBeforeSignIn();
    expect(find.text('Dashboard'), findsNothing);
  });

  testWidgets('Google sign-in does not auto-create while offline', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await tester.enterText(find.byType(EditableText).first, 'vendor@gmail.com');
    await tester.tap(find.text('Continue with Google'));
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Dashboard'), findsNothing);
  });

  testWidgets('Created account remains usable with offline email sign-in', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await createAccountAndOpenDashboard(tester);

    expect(find.text('Dashboard'), findsOneWidget);

    await openOperationsMenu(tester);
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'student@phinmaed.com');
    await tester.enterText(fields.at(1), 'student123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    expect(find.text('Dashboard'), findsOneWidget);
  });

  testWidgets('Saved phone account can sign in offline', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await createAccountAndOpenDashboard(tester);
    await openOperationsMenu(tester);
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'student@phinmaed.com');
    await tester.enterText(fields.at(1), 'student123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    expect(find.text('Dashboard'), findsOneWidget);
  });

  testWidgets('Unknown account warns when no phone account exists', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'missing@phinmaed.com');
    await tester.enterText(fields.at(1), 'missing123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsNothing);
    expect(
      find.text(
        'No saved account on this phone. Connect to internet or create an account first.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Forgot password opens account recovery screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Reset Password'), findsOneWidget);
    expect(find.text('ACCOUNT RECOVERY'), findsOneWidget);
    expect(find.text('Send reset instructions'), findsOneWidget);
  });

  testWidgets('Create account opens as its own screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Create account'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Create FruityVens Account'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Create or continue with Google'), findsOneWidget);
    expect(find.text('Already have an account?'), findsOneWidget);
  });

  testWidgets('Create account accepts any valid email', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Create account'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'Any Email User');
    await tester.enterText(fields.at(1), 'vendor@example.com');
    await tester.enterText(fields.at(2), 'vendor123');
    await tester.enterText(fields.at(3), 'vendor123');
    await tester.ensureVisible(find.text('Create account').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account').last);
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    expect(find.text('Dashboard'), findsOneWidget);
  });

  testWidgets('New account after logout must create its own phone PIN', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1612);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await createAccountAndOpenDashboard(tester, dismissPhoneLink: false);
    expect(find.text('Create your phone PIN'), findsOneWidget);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    await enterPhonePin(tester, '123456');
    await tester.pumpAndSettle();
    expect(find.text('Confirm your phone PIN'), findsOneWidget);
    await enterPhonePin(tester, '123456');
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);

    await openOperationsMenu(tester);
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    await createAccountAndOpenDashboard(
      tester,
      name: 'Second User',
      email: 'second@example.com',
      password: 'second123',
      dismissPhoneLink: false,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Create your phone PIN'), findsOneWidget);
    expect(find.text('second@example.com'), findsOneWidget);
  });

  testWidgets('Guest mode locks full-access dashboard operations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Guest Mode'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('Guest Mode'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    await openOperationsMenu(tester);
    expect(find.text('LOCKED'), findsNWidgets(2));
    expect(find.text('Download PDF'), findsOneWidget);

    await tester.tap(find.text('Generate forecast'));
    await tester.pumpAndSettle();

    expect(find.text('Forecasting'), findsOneWidget);
    expect(find.text('CDO market outlook'), findsOneWidget);
    expect(find.text('PSA'), findsNothing);
    expect(find.text('Demo forecast'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('What to do next'), findsOneWidget);
    expect(find.text('Daily breakdown'), findsOneWidget);
  });

  testWidgets('Guest demo rankings do not leak into real accounts', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Guest Mode'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('Guest Mode'));
    await tester.pumpAndSettle();

    expect(find.text('Daily restock ranking'), findsOneWidget);
    expect(find.text('Heavy restock'), findsOneWidget);

    await openOperationsMenu(tester);
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    await createAccountAndOpenDashboard(tester);

    expect(find.text('Daily restock ranking'), findsOneWidget);
    expect(find.text('No fruit sales yet'), findsOneWidget);
    expect(find.text('Heavy restock'), findsNothing);
  });

  testWidgets('Signed-in users can open full-access operations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FruityVensApp(database: AppDatabase.inMemory()));

    await createAccountAndOpenDashboard(tester);

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('View more'), findsOneWidget);

    final Finder scrollView = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('View more'),
      240,
      scrollable: scrollView,
    );
    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();
    expect(find.text('History'), findsWidgets);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openOperationsMenu(tester);
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    expect(find.text('FRUIT PRICES'), findsOneWidget);
    expect(find.text('Avg price'), findsNothing);
    expect(find.text('Catalog pricing'), findsNothing);
    expect(find.text('Prices set'), findsNothing);
    expect(find.text('Signals'), findsNothing);
    expect(find.text('Today\'s restock priority'), findsNothing);
    expect(find.textContaining('Set price'), findsWidgets);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openOperationsMenu(tester);
    await tester.tap(find.text('Generate forecast'));
    await tester.pumpAndSettle();
    expect(find.text('Forecasting'), findsOneWidget);
    expect(find.text('CDO market outlook'), findsOneWidget);
    expect(find.text('Forecast summary'), findsOneWidget);
    expect(find.text('Collecting'), findsOneWidget);
    expect(
      find.textContaining('0 of 30 selling days recorded'),
      findsOneWidget,
    );
    expect(find.text('Collecting sales history'), findsOneWidget);
    expect(
      find.text('Daily projections unlock after 30 selling days.'),
      findsNothing,
    );
    await tester.ensureVisible(find.text('Daily breakdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily breakdown'));
    await tester.pumpAndSettle();
    expect(
      find.text('Daily projections unlock after 30 selling days.'),
      findsWidgets,
    );
    expect(find.text('1,248'), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openOperationsMenu(tester);
    await tester.tap(find.text('View analytics'));
    await tester.pumpAndSettle();
    expect(find.text('Analytics'), findsWidgets);
    expect(find.text('Last 7 days'), findsWidgets);
    await tester.tap(find.text('Last 7 days').first);
    await tester.pumpAndSettle();
    expect(find.text('Date range'), findsOneWidget);
    expect(find.text('Last 30 days'), findsWidgets);
    await tester.tap(find.text('Last 30 days').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Last 30 days'), findsWidgets);
    expect(find.text('Compact'), findsNothing);
    expect(find.text('No sales in this range yet.'), findsOneWidget);
    final Finder analyticsToggle = find.textContaining('Tap to view details');
    expect(analyticsToggle, findsOneWidget);
    await tester.ensureVisible(analyticsToggle);
    await tester.pumpAndSettle();
    await tester.tap(analyticsToggle);
    await tester.pumpAndSettle();
    expect(find.text('Revenue share by fruit'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openOperationsMenu(tester);
    expect(find.text('Download PDF'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('History can void, restore, and remove mistaken sales', (
    WidgetTester tester,
  ) async {
    final AppDatabase database = AppDatabase.inMemory();
    await database.addSale(
      fruitName: 'Mango',
      weightGrams: 1200,
      unitPrice: 6000,
      totalPrice: 7200,
      soldAt: DateTime.now(),
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await createAccountAndOpenDashboard(tester);

    await tester.ensureVisible(find.text('View more'));
    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.text('1 sold'), findsOneWidget);
    expect(find.byTooltip('Manage sale'), findsOneWidget);

    await tester.tap(find.byTooltip('Manage sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel sale'));
    await tester.pumpAndSettle();

    expect(find.text('0 sold'), findsOneWidget);
    expect(find.text('1 cancelled'), findsOneWidget);
    expect(find.text('Void'), findsOneWidget);

    await tester.tap(find.byTooltip('Manage sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore sale'));
    await tester.pumpAndSettle();

    expect(find.text('1 sold'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.byTooltip('Manage sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();

    expect(find.text('No transaction records'), findsOneWidget);
    final List<LocalSale> sales = await database.getSalesTransactions();
    expect(sales.single.status, 'removed');
  });

  testWidgets('History filters records by selected date', (
    WidgetTester tester,
  ) async {
    final AppDatabase database = AppDatabase.inMemory();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 10, 15);
    final DateTime otherDay = now.day > 1
        ? DateTime(now.year, now.month, now.day - 1, 9, 30)
        : DateTime(now.year, now.month, now.day + 1, 9, 30);

    await database.addSale(
      fruitName: 'Mango',
      weightGrams: 1200,
      unitPrice: 6000,
      totalPrice: 7200,
      soldAt: today,
    );
    await database.addSale(
      fruitName: 'Banana',
      weightGrams: 1000,
      unitPrice: 3500,
      totalPrice: 3500,
      soldAt: otherDay,
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await createAccountAndOpenDashboard(tester);

    await tester.ensureVisible(find.text('View more'));
    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.textContaining('Banana'), findsNothing);
    expect(find.byTooltip('Pick history date'), findsOneWidget);

    await tester.tap(find.byTooltip('Pick history date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${otherDay.day}').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Banana'), findsWidgets);
    expect(find.textContaining('Mango'), findsNothing);
    expect(find.byTooltip('Show today'), findsOneWidget);

    await tester.tap(find.byTooltip('Show today'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.textContaining('Banana'), findsNothing);
  });

  testWidgets('History swipes between days and stops at today', (
    WidgetTester tester,
  ) async {
    final AppDatabase database = AppDatabase.inMemory();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 10, 15);
    final DateTime previousDay = today.subtract(const Duration(days: 1));

    await database.addSale(
      fruitName: 'Mango',
      weightGrams: 1200,
      unitPrice: 6000,
      totalPrice: 7200,
      soldAt: today,
    );
    await database.addSale(
      fruitName: 'Banana',
      weightGrams: 1000,
      unitPrice: 3500,
      totalPrice: 3500,
      soldAt: previousDay,
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await createAccountAndOpenDashboard(tester);

    await tester.ensureVisible(find.text('View more'));
    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.textContaining('Banana'), findsNothing);
    final Finder historySwipeArea = find.byKey(
      const ValueKey<String>('history-swipe-area'),
    );
    expect(historySwipeArea, findsOneWidget);

    await tester.drag(historySwipeArea, const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(find.textContaining('Banana'), findsWidgets);
    expect(find.textContaining('Mango'), findsNothing);
    expect(find.byTooltip('Show today'), findsOneWidget);

    await tester.drag(historySwipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.textContaining('Banana'), findsNothing);

    await tester.drag(historySwipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mango'), findsWidgets);
    expect(find.textContaining('Banana'), findsNothing);
  });

  testWidgets('Worker can send request after editing a synced sale', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1612);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final AppDatabase database = AppDatabase.inMemory();
    await database.saveAccount(
      name: 'Worker',
      email: 'worker@fruityvens.test',
      password: 'worker123',
      role: AccountRole.worker,
      ownerUid: 'owner-uid',
      firebaseUid: 'worker-uid',
    );
    await database.addSale(
      cloudId: 'sale-cloud-1',
      fruitName: 'Mango',
      weightGrams: 1200,
      unitPrice: 6000,
      totalPrice: 7200,
      soldAt: DateTime.now(),
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await tester.tap(find.text('Worker'));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'worker@fruityvens.test');
    await tester.enterText(fields.at(1), 'worker123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    await openOperationsMenu(tester);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Manage sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit sale details'));
    await tester.pumpAndSettle();

    final Finder totalPriceField = find.byWidgetPredicate((Widget widget) {
      return widget is EditableText && widget.controller.text == '72.00';
    });
    expect(totalPriceField, findsOneWidget);
    await tester.enterText(totalPriceField, '80.00');
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    final List<LocalWorkerRequest> requests = await database.getWorkerRequests(
      ownerUid: 'owner-uid',
    );
    expect(requests, hasLength(1));
    expect(requests.single.type, 'edit_sale');
    expect(requests.single.saleCloudId, 'sale-cloud-1');
    expect(requests.single.requestedData['totalPrice'], 8000);
    expect(
      find.text('Request saved. It will send when Firebase is available.'),
      findsOneWidget,
    );
  });

  testWidgets('Worker scale sale waits for owner approval', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1612);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final AppDatabase database = AppDatabase.inMemory();
    await database.saveAccount(
      name: 'Worker',
      email: 'worker@fruityvens.test',
      password: 'worker123',
      role: AccountRole.worker,
      ownerUid: 'owner-uid',
      firebaseUid: 'worker-uid',
    );
    await database.saveWorkerRequest(
      requestId: 'create_sale_scale_1',
      type: 'create_sale',
      status: 'pending',
      ownerUid: 'owner-uid',
      workerUid: 'worker-uid',
      workerName: 'Worker',
      saleCloudId: 'scale_fruityvens_scale_01_sale_1',
      requestedPayload: <String, Object?>{
        'cloudId': 'scale_fruityvens_scale_01_sale_1',
        'fruitName': 'Mango',
        'weightGrams': 1250,
        'unitPrice': 6000,
        'totalPrice': 7500,
        'status': 'sold',
        'soldAt': DateTime(2026, 6, 4, 10, 30).toIso8601String(),
      },
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await tester.tap(find.text('Worker'));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'worker@fruityvens.test');
    await tester.enterText(fields.at(1), 'worker123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    final List<LocalSale> sales = await database.getSalesTransactions();
    expect(sales, isEmpty);

    final List<LocalWorkerRequest> pendingRequests = await database
        .getWorkerRequests(status: 'pending', ownerUid: 'owner-uid');
    expect(pendingRequests, hasLength(1));
    final List<LocalWorkerRequest> requests = await database.getWorkerRequests(
      ownerUid: 'owner-uid',
    );
    expect(requests.single.status, 'pending');
  });

  testWidgets('Worker can request a manually added sale from history', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1612);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final AppDatabase database = AppDatabase.inMemory();
    await database.saveAccount(
      name: 'Worker',
      email: 'worker@fruityvens.test',
      password: 'worker123',
      role: AccountRole.worker,
      ownerUid: 'owner-uid',
      firebaseUid: 'worker-uid',
    );

    await tester.pumpWidget(FruityVensApp(database: database));
    await tester.tap(find.text('Worker'));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'worker@fruityvens.test');
    await tester.enterText(fields.at(1), 'worker123');
    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(seconds: 1));
    await dismissPhoneLinkPrompt(tester);

    await openOperationsMenu(tester);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Request sale'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).at(0), '1.50');
    await tester.enterText(find.byType(EditableText).at(1), '120.00');
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();

    final List<LocalWorkerRequest> requests = await database.getWorkerRequests(
      ownerUid: 'owner-uid',
    );
    expect(requests, hasLength(1));
    expect(requests.single.type, 'create_sale');
    expect(requests.single.saleCloudId, isNotEmpty);
    expect(
      requests.single.requestedData['cloudId'],
      requests.single.saleCloudId,
    );
    expect(requests.single.requestedData['fruitName'], 'Apple');
    expect(requests.single.requestedData['weightGrams'], 1500);
    expect(requests.single.requestedData['totalPrice'], 12000);
    expect(await database.getSalesTransactions(), isEmpty);
    expect(
      find.text('Request saved. It will send when Firebase is available.'),
      findsOneWidget,
    );
  });

  testWidgets('Inventory adds Philippine fruits and saves typed prices', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1612);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final AppDatabase database = AppDatabase.inMemory();
    await tester.pumpWidget(FruityVensApp(database: database));
    await createAccountAndOpenDashboard(tester);

    await openOperationsMenu(tester);
    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage fruits'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Apple Mango'), findsOneWidget);
    expect(find.text('Lemon'), findsOneWidget);
    expect(find.text('Papaya'), findsOneWidget);
    expect(find.text('Watermelon'), findsOneWidget);
    for (final String removedFruit in <String>[
      'Guava',
      'Coconut',
      'Dalandan',
      'Chico',
      'Atis',
      'Santol',
      'Star Apple',
      'Jackfruit',
      'Tamarind',
      'Langkatan',
    ]) {
      expect(find.text(removedFruit), findsNothing);
    }
    await tester.tap(find.text('Lemon'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText).last, '42.50');
    await tester.tap(find.text('Add fruit'));
    await tester.pumpAndSettle();

    expect(find.text('Lemon'), findsWidgets);
    LocalFruit? lemon = await database.getManagedFruit('Lemon');
    expect(lemon?.price, 4250);

    await tester.tap(find.byTooltip('Done managing fruits'));
    await tester.pumpAndSettle();
    expect(find.text('PHP 42.50/kg'), findsOneWidget);
    expect(find.text('Set price per piece'), findsNothing);
    expect(find.text('Per piece'), findsNothing);

    final Finder lemonPriceField = find.byWidgetPredicate((Widget widget) {
      return widget is EditableText && widget.controller.text == '42.50';
    });
    expect(lemonPriceField, findsOneWidget);
    await tester.enterText(lemonPriceField, '55.75');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('PHP 55.75/kg'), findsOneWidget);
    lemon = await database.getManagedFruit('Lemon');
    expect(lemon?.price, 5575);

    final Finder updatedLemonPriceField = find.byWidgetPredicate((
      Widget widget,
    ) {
      return widget is EditableText && widget.controller.text == '55.75';
    });
    expect(updatedLemonPriceField, findsOneWidget);
    await tester.enterText(updatedLemonPriceField, '62.25');
    final Finder visibleSaveButton = find
        .widgetWithText(PrimaryButton, 'Save')
        .hitTestable();
    expect(visibleSaveButton, findsOneWidget);
    await tester.tap(visibleSaveButton);
    await tester.pumpAndSettle();

    expect(find.text('PHP 62.25/kg'), findsOneWidget);
    lemon = await database.getManagedFruit('Lemon');
    expect(lemon?.price, 6225);

    expect(find.text('Per piece'), findsNothing);
    expect(find.text('PHP 62.25/kg'), findsOneWidget);
    lemon = await database.getManagedFruit('Lemon');
    expect(lemon?.pricingUnit, 'kg');
  });
}
