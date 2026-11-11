import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import '../data/biz.dart';
import '../data/seed.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';
import 'widgets/deleted_businesses.dart';
import 'widgets/global_search.dart';
import 'widgets/cloud_widgets.dart';
import 'widgets/shop_mark.dart';
import 'screens/settings_cloud.dart' show confirmLogout;
import '../state/cloud_state.dart';
import '../state/website_state.dart';
import '../sync/google_auth.dart';

class NavItem {
  final String path;
  final T label;
  final IconData icon;
  final String? key;
  final LogicalKeyboardKey? shortcut;
  const NavItem(this.path, this.label, this.icon, {this.key, this.shortcut});
}

const _sell = [
  NavItem('/pos', T.newSale, Icons.point_of_sale_rounded, key: 'F2', shortcut: LogicalKeyboardKey.f2),
  NavItem('/sales', T.sales, Icons.receipt_long_rounded),
  NavItem('/orders', T.orders, Icons.local_shipping_outlined, key: 'F5', shortcut: LogicalKeyboardKey.f5),
];
const _stock = [
  NavItem('/products', T.products, Icons.inventory_2_outlined, key: 'F3', shortcut: LogicalKeyboardKey.f3),
  NavItem('/purchases', T.purchases, Icons.shopping_bag_outlined, key: 'F6', shortcut: LogicalKeyboardKey.f6),
];
const _khata = [
  NavItem('/customers', T.customers, Icons.menu_book_rounded, key: 'F4', shortcut: LogicalKeyboardKey.f4),
  NavItem('/suppliers', T.suppliers, Icons.storefront_outlined),
];
const _money = [
  NavItem('/expenses', T.expenses, Icons.receipt_outlined, key: 'F7', shortcut: LogicalKeyboardKey.f7),
  NavItem('/cashbox', T.cashbox, Icons.account_balance_wallet_outlined, key: 'F8', shortcut: LogicalKeyboardKey.f8),
  NavItem('/reports', T.reports, Icons.insights_rounded, key: 'F10', shortcut: LogicalKeyboardKey.f10),
];

final pendingOrdersProvider = StreamProvider<int>((ref) => ref
    .watch(bizProvider)
    .orders
    .watchStatusCounts()
    .map((m) => (m['pending'] ?? 0) + (m['confirmed'] ?? 0)));

final lowStockCountProvider = StreamProvider<int>((ref) => ref.watch(bizProvider).products.watchLowStockCount());

class AppShell extends ConsumerWidget {
  final String location;
  final Widget child;
  const AppShell({super.key, required this.location, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const {};
    final online = settings.flag(K.onlineEnabled);
    final actor = ref.watch(actorProvider);
    final wide = MediaQuery.sizeOf(context).width >= 940;
    // Start the Google Drive and website syncers (they keep running in the background).
    ref.listen(cloudSyncProvider, (_, _) {});
    ref.listen(websiteProvider, (_, _) {});

    final bindings = <ShortcutActivator, VoidCallback>{
      for (final item in [..._sell, ..._stock, ..._khata, ..._money])
        if (item.shortcut != null && (item.path != '/orders' || online) && actor.canVisit(item.path))
          SingleActivator(item.shortcut!): () => context.go(item.path),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): () => lockOrExplain(context, ref),
      const SingleActivator(LogicalKeyboardKey.home, control: true): () => context.go(actor.home),
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showGlobalSearch(context),
    };

    // A staff member who lands on a page they may not open goes to their home page.
    var page = child;
    if (!actor.canVisit(location)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go(actor.home);
      });
      page = const SizedBox.shrink();
    }

    final sidebar = _Sidebar(location: location, online: online);
    final phone = MediaQuery.sizeOf(context).width < 600;
    final Widget body = wide
        ? Scaffold(
            body: Row(children: [
              sidebar,
              Expanded(child: ClipRect(child: page)),
            ]),
          )
        : Scaffold(
            appBar: AppBar(
              backgroundColor: C.brandDeep,
              foregroundColor: Colors.white,
              titleSpacing: 0,
              title: Text(ref.watch(sessionProvider).info.name, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  key: const ValueKey('open-search'),
                  tooltip: T.search.s,
                  onPressed: () => showGlobalSearch(context),
                  icon: const Icon(Icons.search_rounded),
                ),
                IconButton(
                  tooltip: T.language.s,
                  onPressed: () => ref.read(langProvider.notifier).toggle(),
                  icon: Text(isBangla ? 'EN' : 'বাং',
                      style: const TextStyle(fontFamily: kBody, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
                IconButton(
                  tooltip: T.lock.s,
                  onPressed: () => lockOrExplain(context, ref),
                  icon: const Icon(Icons.lock_outline_rounded),
                ),
              ],
            ),
            drawer: Drawer(width: 270, backgroundColor: C.brandDeep, child: SafeArea(child: sidebar)),
            body: page,
            bottomNavigationBar: phone ? _BottomNav(location: location, online: online, actor: actor) : null,
          );

    // Android back button: step up to the parent page instead of closing the app.
    return PopScope(
      canPop: location == actor.home,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final segments = location.split('/').where((s) => s.isNotEmpty).toList();
        context.go(segments.length > 1 ? '/${segments.first}' : actor.home);
      },
      child: CallbackShortcuts(
        bindings: bindings,
        child: _IdleLock(
          minutes: settings.num(K.autoLockMinutes).toInt(),
          child: Focus(autofocus: true, child: body),
        ),
      ),
    );
  }
}

/// Phone bottom bar: the five things a shopkeeper does all day.
class _BottomNav extends StatelessWidget {
  final String location;
  final bool online;
  final Actor actor;
  const _BottomNav({required this.location, required this.online, required this.actor});

  @override
  Widget build(BuildContext context) {
    final items = <(String, IconData, IconData, String)>[
      if (actor.can(Cap.dashboard)) ('/', Icons.space_dashboard_outlined, Icons.space_dashboard_rounded, T.dashboard.s),
      ('/pos', Icons.point_of_sale_outlined, Icons.point_of_sale_rounded, isBangla ? 'বিক্রি' : 'Sell'),
      ('/customers', Icons.menu_book_outlined, Icons.menu_book_rounded, T.sectionKhata.s),
      ('/products', Icons.inventory_2_outlined, Icons.inventory_2_rounded, T.stock.s),
      online
          ? ('/orders', Icons.local_shipping_outlined, Icons.local_shipping_rounded, isBangla ? 'অর্ডার' : 'Orders')
          : ('/sales', Icons.receipt_long_outlined, Icons.receipt_long_rounded, T.sales.s),
      // Cashiers have no dashboard; give them their sales list instead.
      if (!actor.can(Cap.dashboard) && online) ('/sales', Icons.receipt_long_outlined, Icons.receipt_long_rounded, T.sales.s),
    ];
    var index = items.lastIndexWhere((i) => i.$1 != '/' && (location == i.$1 || location.startsWith('${i.$1}/')));
    if (index < 0 && location == '/') index = 0;
    return NavigationBar(
      height: 64,
      backgroundColor: C.card,
      indicatorColor: index < 0 ? Colors.transparent : C.brandSoft,
      surfaceTintColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      // -1 (a page not in the bar) shows no highlight.
      selectedIndex: index < 0 ? 0 : index,
      onDestinationSelected: (i) => context.go(items[i].$1),
      destinations: [
        for (var i = 0; i < items.length; i++)
          NavigationDestination(
            icon: Icon(items[i].$2, color: index == i ? C.brand : C.ink2),
            selectedIcon: Icon(items[i].$3, color: index == i ? C.brand : C.ink2),
            label: items[i].$4,
          ),
      ],
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final String location;
  final bool online;
  const _Sidebar({required this.location, required this.online});

  bool _active(String path) => path == '/' ? location == '/' : location == path || location.startsWith('$path/');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingOrdersProvider).value ?? 0;
    final low = ref.watch(lowStockCountProvider).value ?? 0;
    final actor = ref.watch(actorProvider);
    final money = [for (final n in _money) if (actor.canVisit(n.path)) n];

    Widget item(NavItem n, {int badge = 0, Tone badgeTone = Tone.accent}) => _NavTile(
          item: n,
          active: _active(n.path),
          badge: badge,
          badgeTone: badgeTone,
          onTap: () {
            if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.of(context).pop();
            context.go(n.path);
          },
        );

    return Container(
      width: 236,
      color: C.brandDeep,
      child: Column(children: [
        const _BusinessSwitcher(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            children: [
              if (actor.can(Cap.dashboard)) item(const NavItem('/', T.dashboard, Icons.space_dashboard_outlined)),
              _NewSaleButton(onTap: () => context.go('/pos'), active: _active('/pos')),
              _group(T.sectionSell),
              item(_sell[1]),
              if (online) item(_sell[2], badge: pending),
              _group(T.sectionStock),
              item(_stock[0], badge: low, badgeTone: Tone.bad),
              if (actor.canVisit(_stock[1].path)) item(_stock[1]),
              _group(T.sectionKhata),
              for (final n in _khata)
                if (actor.canVisit(n.path)) item(n),
              if (money.isNotEmpty) _group(T.sectionMoney),
              for (final n in money) item(n),
            ],
          ),
        ),
        _SidebarFooter(location: location),
      ]),
    );
  }

  Widget _group(T label) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
        child: Text(label.s.toUpperCase(),
            style: TextStyle(
                fontFamily: kBody,
                fontSize: 10.5,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.38))),
      );
}

class _NewSaleButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool active;
  const _NewSaleButton({required this.onTap, required this.active});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Material(
        color: C.marigold,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: active ? Border.all(color: Colors.white, width: 1.5) : null,
            ),
            child: Row(children: [
              const Icon(Icons.add_shopping_cart_rounded, size: 19, color: C.brandDeep),
              const SizedBox(width: 10),
              Expanded(
                child: Text(T.newSale.s,
                    style: const TextStyle(fontFamily: kBody, fontWeight: FontWeight.w700, fontSize: 14.5, color: C.brandDeep)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: C.brandDeep.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                child: const Text('F2',
                    style: TextStyle(fontFamily: kBody, fontSize: 10.5, fontWeight: FontWeight.w700, color: C.brandDeep)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  final NavItem item;
  final bool active;
  final int badge;
  final Tone badgeTone;
  final VoidCallback onTap;
  const _NavTile({required this.item, required this.active, required this.onTap, this.badge = 0, this.badgeTone = Tone.accent});

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 1),
          height: 40,
          decoration: BoxDecoration(
            color: active
                ? Colors.white.withValues(alpha: 0.11)
                : (hover ? Colors.white.withValues(alpha: 0.05) : Colors.transparent),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 3,
              height: active ? 20 : 0,
              decoration: BoxDecoration(color: C.marigold, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 9),
            Icon(widget.item.icon, size: 19, color: active ? C.marigold : Colors.white.withValues(alpha: 0.72)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.item.label.s,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kBody,
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? Colors.white : Colors.white.withValues(alpha: 0.80),
                ),
              ),
            ),
            if (widget.badge > 0)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: widget.badgeTone == Tone.bad ? const Color(0xFFE5654A) : C.marigold,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(number(widget.badge),
                    style: const TextStyle(fontFamily: kBody, fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
              )
            else if (widget.item.key != null && hover)
              Padding(padding: const EdgeInsets.only(right: 8), child: KeyCap(widget.item.key!, dark: true)),
          ]),
        ),
      ),
    );
  }
}

class _BusinessSwitcher extends ConsumerWidget {
  const _BusinessSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final list = ref.watch(businessesProvider).value ?? const [];
    final deleted = ref.watch(deletedBusinessesProvider).value ?? const [];
    final user = ref.watch(googleUserProvider);
    final type = businessTypeById(session.info.type);
    // The logo from Settings → Business profile (the type's icon without one).
    final logo = (ref.watch(settingsProvider).value ?? const <String, String>{})[K.logoPath];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 6),
      child: PopupMenuButton<String>(
        // Staff work in this one business only.
        enabled: session.actor.isOwner,
        tooltip: T.switchBusiness.s,
        position: PopupMenuPosition.under,
        offset: const Offset(0, 6),
        onSelected: (v) async {
          if (v == '+') {
            ref.read(appProvider.notifier).startAddBusiness();
          } else if (v == 'cloud') {
            showOpenFromDrive(context, ref);
          } else if (v == 'deleted') {
            showDeletedBusinesses(context);
          } else if (v == 'logout') {
            await confirmLogout(context, ref);
          } else if (v != session.info.id) {
            await ref.read(appProvider.notifier).switchTo(v);
            if (context.mounted) context.go('/');
          }
        },
        itemBuilder: (_) => [
          for (final b in list)
            PopupMenuItem(
              value: b.id,
              child: Row(children: [
                // Only the open shop's settings are at hand, so only it shows its logo here.
                ShopMark(logo: b.id == session.info.id ? logo : null, icon: businessTypeById(b.type).icon, size: 24, radius: 6),
                const SizedBox(width: 10),
                Expanded(child: Text(b.name, overflow: TextOverflow.ellipsis)),
                if (b.id == session.info.id) const Icon(Icons.check_rounded, size: 18, color: C.brand),
              ]),
            ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'cloud',
            enabled: GoogleConfig.ready,
            child: Row(children: [
              const Icon(Icons.cloud_download_outlined, size: 18, color: C.brand),
              const SizedBox(width: 10),
              Flexible(child: Text(T.openFromDrive.s, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          PopupMenuItem(
            value: '+',
            child: Row(children: [
              const Icon(Icons.add_business_outlined, size: 18, color: C.brand),
              const SizedBox(width: 10),
              Flexible(child: Text(T.addBusiness.s, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          if (deleted.isNotEmpty)
            PopupMenuItem(
              value: 'deleted',
              child: Row(children: [
                const Icon(Icons.restore_from_trash_outlined, size: 18, color: C.ink2),
                const SizedBox(width: 10),
                Flexible(child: Text('${T.recentlyDeleted.s} (${number(deleted.length)})', overflow: TextOverflow.ellipsis)),
              ]),
            ),
          if (AppController.requireAccount) ...[
            const PopupMenuDivider(),
            if (user != null)
              PopupMenuItem(
                enabled: false,
                height: 36,
                child: Text(user.email, style: Txt.tiny, overflow: TextOverflow.ellipsis),
              ),
            PopupMenuItem(
              value: 'logout',
              child: Row(children: [
                const Icon(Icons.logout_rounded, size: 18, color: C.outRed),
                const SizedBox(width: 10),
                Flexible(child: Text(T.logout.s, style: const TextStyle(color: C.outRed), overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ],
        ],
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(children: [
            ShopMark(key: const ValueKey('switcher-mark'), logo: logo, icon: type.icon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(session.info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: kBody, fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white)),
                Text(isBangla ? type.bn : type.en,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: kBody, fontSize: 11.5, color: Colors.white.withValues(alpha: 0.55))),
              ]),
            ),
            Icon(Icons.unfold_more_rounded, size: 18, color: Colors.white.withValues(alpha: 0.5)),
          ]),
        ),
      ),
    );
  }
}

class _SidebarFooter extends ConsumerWidget {
  final String location;
  const _SidebarFooter({required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(langProvider);
    final actor = ref.watch(actorProvider);
    final settingsActive = location.startsWith('/settings');
    final faint = Colors.white.withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08)))),
      child: Column(children: [
        const CloudStatusChip(),
        _SearchTile(key: const ValueKey('open-search'), onTap: () => showGlobalSearch(context)),
        if (!actor.isOwner)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(children: [
              Icon(Icons.badge_outlined, size: 17, color: faint),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${actor.name} · ${tKey('role', actor.role.name)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: kBody, fontSize: 13, fontWeight: FontWeight.w600, color: faint)),
              ),
            ]),
          ),
        if (actor.can(Cap.settings))
          _NavTile(
            item: const NavItem('/settings', T.settings, Icons.tune_rounded),
            active: settingsActive,
            onTap: () => context.go('/settings'),
          ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Container(
              height: 34,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(9)),
              child: Row(children: [
                for (final l in Lang.values)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => ref.read(langProvider.notifier).set(l),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: lang == l ? C.card : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(l == Lang.en ? 'English' : 'বাংলা',
                              style: TextStyle(
                                  fontFamily: kBody,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: lang == l ? C.brandDeep : faint)),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: '${actor.isOwner ? T.lock.s : T.switchUser.s} (Ctrl+L)',
            child: Material(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(9),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => lockOrExplain(context, ref),
                child: SizedBox(width: 34, height: 34, child: Icon(Icons.lock_outline_rounded, size: 17, color: faint)),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Lock now, or tell the owner where to turn the PIN on.
Future<void> lockOrExplain(BuildContext context, WidgetRef ref) async {
  // Ask the database, not the settings stream, which may still be loading.
  final pin = await ref.read(bizProvider).settings.get(K.pinHash) ?? '';
  if (pin.isEmpty) {
    if (!context.mounted) return;
    toast(context, '${T.pinOff.s} — ${T.settings.s} → ${T.security.s}');
    return;
  }
  await ref.read(appProvider.notifier).lock();
}

class _SearchTile extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchTile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Row(children: [
              const SizedBox(width: 12),
              Icon(Icons.search_rounded, size: 18, color: Colors.white.withValues(alpha: 0.7)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(T.search.s,
                    style: TextStyle(fontFamily: kBody, fontSize: 13.5, color: Colors.white.withValues(alpha: 0.7))),
              ),
              const Padding(padding: EdgeInsets.only(right: 8), child: KeyCap('Ctrl K', dark: true)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Locks the app after [minutes] without a tap, click or key press, and when
/// the phone comes back after being away that long.
class _IdleLock extends ConsumerStatefulWidget {
  final int minutes;
  final Widget child;
  const _IdleLock({required this.minutes, required this.child});

  @override
  ConsumerState<_IdleLock> createState() => _IdleLockState();
}

class _IdleLockState extends ConsumerState<_IdleLock> with WidgetsBindingObserver {
  DateTime _last = DateTime.now();
  DateTime? _awaySince;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    _last = DateTime.now();
    return false;
  }

  void _touch([Object? _]) => _last = DateTime.now();

  bool _expired(DateTime since) =>
      widget.minutes > 0 && DateTime.now().difference(since) >= Duration(minutes: widget.minutes);

  void _check() {
    if (_expired(_last)) {
      _last = DateTime.now();
      ref.read(appProvider.notifier).lock();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _awaySince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _awaySince;
      _awaySince = null;
      if (away != null && _expired(away)) {
        ref.read(appProvider.notifier).lock();
      } else {
        _touch();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _touch,
        onPointerHover: _touch,
        onPointerSignal: _touch,
        child: widget.child,
      );
}
