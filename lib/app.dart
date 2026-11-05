import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/i18n.dart';
import 'core/theme.dart';
import 'state/app_state.dart';
import 'ui/screens/cashbox_screen.dart';
import 'ui/screens/contacts_screen.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/screens/expenses_screen.dart';
import 'ui/screens/lock_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/order_detail_screen.dart';
import 'ui/screens/order_form_screen.dart';
import 'ui/screens/orders_screen.dart';
import 'ui/screens/pos_screen.dart';
import 'ui/screens/products_screen.dart';
import 'ui/screens/purchase_form_screen.dart';
import 'ui/screens/purchases_screen.dart';
import 'ui/screens/reports_screen.dart';
import 'ui/screens/sale_detail_screen.dart';
import 'ui/screens/sales_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/shell.dart';

Page<void> _page(GoRouterState state, Widget child) => CustomTransitionPage(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 160),
      reverseTransitionDuration: const Duration(milliseconds: 100),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.008), end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );

int? _id(GoRouterState s) => int.tryParse(s.pathParameters['id'] ?? '');

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', pageBuilder: (c, s) => _page(s, const DashboardScreen())),
        GoRoute(path: '/pos', pageBuilder: (c, s) => _page(s, const PosScreen())),
        GoRoute(path: '/sales', pageBuilder: (c, s) => _page(s, const SalesScreen())),
        GoRoute(path: '/sales/:id', pageBuilder: (c, s) => _page(s, SaleDetailScreen(id: _id(s)!))),
        GoRoute(path: '/orders', pageBuilder: (c, s) => _page(s, const OrdersScreen())),
        GoRoute(path: '/orders/new', pageBuilder: (c, s) => _page(s, const OrderFormScreen())),
        GoRoute(path: '/orders/:id', pageBuilder: (c, s) => _page(s, OrderDetailScreen(id: _id(s)!))),
        GoRoute(path: '/products', pageBuilder: (c, s) => _page(s, const ProductsScreen())),
        GoRoute(path: '/products/:id', pageBuilder: (c, s) => _page(s, ProductsScreen(selectedId: _id(s)))),
        GoRoute(path: '/purchases', pageBuilder: (c, s) => _page(s, const PurchasesScreen())),
        GoRoute(path: '/purchases/new', pageBuilder: (c, s) => _page(s, const PurchaseFormScreen())),
        GoRoute(path: '/customers', pageBuilder: (c, s) => _page(s, const ContactsScreen(type: 'customer'))),
        GoRoute(
            path: '/customers/:id',
            pageBuilder: (c, s) => NoTransitionPage(child: ContactsScreen(type: 'customer', selectedId: _id(s)))),
        GoRoute(path: '/suppliers', pageBuilder: (c, s) => _page(s, const ContactsScreen(type: 'supplier'))),
        GoRoute(
            path: '/suppliers/:id',
            pageBuilder: (c, s) => NoTransitionPage(child: ContactsScreen(type: 'supplier', selectedId: _id(s)))),
        GoRoute(path: '/expenses', pageBuilder: (c, s) => _page(s, const ExpensesScreen())),
        GoRoute(path: '/cashbox', pageBuilder: (c, s) => _page(s, const CashboxScreen())),
        GoRoute(path: '/reports', pageBuilder: (c, s) => _page(s, const ReportsScreen())),
        GoRoute(path: '/settings', pageBuilder: (c, s) => _page(s, const SettingsScreen())),
      ],
    ),
  ],
);

class BizKhataApp extends ConsumerWidget {
  const BizKhataApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(langProvider);
    final phase = ref.watch(appProvider);
    final theme = buildTheme();
    final locale = Locale(lang == Lang.bn ? 'bn' : 'en');
    const delegates = [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];
    const locales = [Locale('en'), Locale('bn')];

    Widget plain(Widget home) => MaterialApp(
          key: ValueKey('plain-$lang'),
          debugShowCheckedModeBanner: false,
          title: T.appName.s,
          theme: theme,
          locale: locale,
          localizationsDelegates: delegates,
          supportedLocales: locales,
          home: home,
        );

    return switch (phase) {
      Booting() => plain(const _Splash()),
      BootError(:final message) => plain(_BootErrorView(message)),
      Onboarding(:final canCancel) => plain(OnboardingScreen(canCancel: canCancel)),
      Locked() => plain(const LockScreen()),
      Ready() => MaterialApp.router(
          key: ValueKey('app-$lang'),
          debugShowCheckedModeBanner: false,
          title: T.appName.s,
          theme: theme,
          locale: locale,
          localizationsDelegates: delegates,
          supportedLocales: locales,
          routerConfig: appRouter,
        ),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.brandDeep,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const BrandMark(size: 64),
          const SizedBox(height: 18),
          Text(T.appName.s, style: Txt.display(30, color: Colors.white)),
        ]),
      ),
    );
  }
}

class _BootErrorView extends StatelessWidget {
  final String message;
  const _BootErrorView(this.message);
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: C.outRed),
            const SizedBox(height: 12),
            Text('BizKhata could not open its data', style: Txt.display(22)),
            const SizedBox(height: 10),
            SelectableText(message, style: Txt.small, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

/// The app mark: a ledger page with a margin line and a tick.
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 40});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _MarkPainter());
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final r = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(w * 0.24));
    canvas.drawRRect(r, Paint()..color = C.marigold);
    final page = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.22, w * 0.18, w * 0.56, w * 0.64), Radius.circular(w * 0.06));
    canvas.drawRRect(page, Paint()..color = C.card);
    final line = Paint()
      ..color = C.line
      ..strokeWidth = w * 0.035;
    for (var i = 0; i < 4; i++) {
      final y = w * (0.34 + i * 0.12);
      canvas.drawLine(Offset(w * 0.36, y), Offset(w * 0.70, y), line);
    }
    canvas.drawLine(
        Offset(w * 0.33, w * 0.2),
        Offset(w * 0.33, w * 0.8),
        Paint()
          ..color = C.margin
          ..strokeWidth = w * 0.03);
    final tick = Path()
      ..moveTo(w * 0.42, w * 0.55)
      ..lineTo(w * 0.52, w * 0.65)
      ..lineTo(w * 0.72, w * 0.40);
    canvas.drawPath(
        tick,
        Paint()
          ..color = C.brand
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.08
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
