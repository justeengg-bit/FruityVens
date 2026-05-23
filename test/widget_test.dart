import 'package:flutter/material.dart' show DropdownButtonFormField, Switch;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruityvens_app/data/app_database.dart';
import 'package:fruityvens_app/main.dart';

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
    expect(find.text('Download Data'), findsOneWidget);

    await tester.tap(find.text('Generate forecast'));
    await tester.pumpAndSettle();

    expect(find.text('Forecasting'), findsOneWidget);
    expect(find.text('Demo forecast'), findsOneWidget);
    expect(find.text('Demo forecast preview only.'), findsOneWidget);
    expect(find.text('What to do next'), findsOneWidget);
    expect(find.text('Projected daily sales'), findsOneWidget);
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
    expect(find.text('PRICES AND RESTOCK SIGNALS'), findsOneWidget);
    expect(find.text('Avg price'), findsNothing);
    expect(find.text('Prices set'), findsOneWidget);
    expect(find.textContaining('Set price'), findsWidgets);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openOperationsMenu(tester);
    await tester.tap(find.text('Generate forecast'));
    await tester.pumpAndSettle();
    expect(find.text('Forecasting'), findsOneWidget);
    expect(find.text('No sales yet.'), findsOneWidget);
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
    expect(find.text('Download Data'), findsOneWidget);
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

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Lemon'), findsOneWidget);
    expect(find.text('Papaya'), findsOneWidget);
    expect(find.text('Watermelon'), findsOneWidget);
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
  });
}
