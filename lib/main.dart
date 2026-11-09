import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'admin_screen.dart';
import 'api.dart';
import 'auth_screen.dart';
import 'avatar_2d.dart';
import 'catalog_screen.dart';
import 'common.dart';
import 'i18n.dart';
import 'looks_screen.dart';
import 'tryon_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.load();
  await ServerConfig.init();
  Session.load();
  final mode = AppSettings.themeMode;
  FitColors.dark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system &&
          WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
  runApp(const FitMeApp());
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // FitColors reads this flag; set it while the colours below are taken.
  final previous = FitColors.dark;
  FitColors.dark = dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: FitColors.accent,
    brightness: brightness,
    primary: FitColors.accent,
    onPrimary: Colors.white,
    surface: FitColors.card,
  );
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: FitColors.background,
    canvasColor: FitColors.background,
    dividerColor: FitColors.line,
    appBarTheme: AppBarTheme(
      backgroundColor: FitColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      // Built from the theme's own text style so the app font is kept (a bare TextStyle drops it).
      titleTextStyle: (dark ? Typography.material2021().white : Typography.material2021().black)
          .titleLarge!
          .copyWith(color: FitColors.text, fontSize: 20, fontWeight: FontWeight.w800),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FitColors.cardHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: FitColors.line2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: FitColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        side: BorderSide(color: FitColors.line2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: FitColors.accent.withValues(alpha: dark ? .30 : .14),
        selectedForegroundColor: dark ? Colors.white : FitColors.accentSoft,
        side: BorderSide(color: FitColors.line2),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: FitColors.cardHigh,
      selectedColor: FitColors.accent.withValues(alpha: dark ? .32 : .16),
      side: BorderSide(color: FitColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: FitColors.accent,
      inactiveTrackColor: FitColors.accent.withValues(alpha: .18),
      thumbColor: FitColors.accent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: FitColors.card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FitColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: FitColors.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: FitColors.accent.withValues(alpha: dark ? .28 : .14),
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? FitColors.text : FitColors.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? FitColors.accentSoft : FitColors.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: FitColors.card,
      indicatorColor: FitColors.accent.withValues(alpha: dark ? .28 : .14),
      selectedIconTheme: IconThemeData(color: FitColors.accentSoft),
      unselectedIconTheme: IconThemeData(color: FitColors.muted),
      selectedLabelTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: FitColors.text),
      unselectedLabelTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: FitColors.muted),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
  FitColors.dark = previous;
  return theme;
}

/// In a browser lists can also be dragged with the mouse (the outfit row has no scrollbar).
class _FitScrollBehavior extends MaterialScrollBehavior {
  const _FitScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}

class FitMeApp extends StatefulWidget {
  const FitMeApp({super.key});

  @override
  State<FitMeApp> createState() => _FitMeAppState();
}

class _FitMeAppState extends State<FitMeApp> {
  @override
  void initState() {
    super.initState();
    AppSettings.revision.addListener(_changed);
  }

  @override
  void dispose() {
    AppSettings.revision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _rebuildEverything();
  }

  /// Screens read FitColors / t() directly, so after a theme or language change
  /// every widget must build again (state such as the current outfit is kept).
  void _rebuildEverything() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void mark(Element e) {
        e.markNeedsBuild();
        e.visitChildren(mark);
      }

      (context as Element).visitChildren(mark);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitMe AI',
      scrollBehavior: const _FitScrollBehavior(),
      themeMode: AppSettings.themeMode,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        if (FitColors.dark != dark) {
          FitColors.dark = dark;
          _rebuildEverything(); // e.g. the phone switched to night mode
        }
        return child!;
      },
      home: const AuthGate(),
    );
  }
}

/// Shows the sign-in screen until there is an account on this phone.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    if (Session.signedIn) _refresh();
  }

  /// The role may have changed, or the account was blocked: ask the server once at start.
  Future<void> _refresh() async {
    try {
      await FitMeApi.me();
    } catch (_) {
      // Offline is fine (the app still opens); a revoked token signs out inside the API.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AccountUser?>(
      valueListenable: Session.user,
      builder: (context, user, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: user == null
            ? const AuthScreen(key: ValueKey('auth'))
            : FitMeShell(key: ValueKey('shell-${user.id}')),
      ),
    );
  }
}

class FitMeShell extends StatefulWidget {
  const FitMeShell({super.key});

  @override
  State<FitMeShell> createState() => _FitMeShellState();
}

class _FitMeShellState extends State<FitMeShell> with WidgetsBindingObserver {
  final _tryOnKey = GlobalKey<TryOnScreenState>();
  int _index = 0;
  int _catalogVisit = 0;
  int _looksVisit = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ServerConfig.discover();
    ServerConfig.startKeepAlive();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ServerConfig.stopKeepAlive();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the background (e.g. after switching Wi-Fi ↔ mobile data).
    if (state == AppLifecycleState.resumed) {
      ServerConfig.discover();
      ServerConfig.startKeepAlive();
    } else if (state == AppLifecycleState.paused) {
      ServerConfig.stopKeepAlive();
    }
  }

  void _select(int value) {
    setState(() {
      if (value == 1 && _index != 1) _catalogVisit++;
      if (value == 3 && _index != 3) _looksVisit++;
      _index = value;
    });
  }

  void _addToOutfit(CatalogItem item) {
    _select(2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryOnKey.currentState?.addCatalogItem(item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 840; // a browser window or a tablet: side menu instead of the bottom bar
    final extended = width >= 1180;
    final tabs = <(IconData, IconData, String)>[
      (Icons.home_outlined, Icons.home_rounded, t('Главная')),
      (Icons.checkroom_outlined, Icons.checkroom, t('Каталог')),
      (Icons.auto_awesome_outlined, Icons.auto_awesome, t('Примерка')),
      (Icons.favorite_border, Icons.favorite, t('Луки')),
      (Icons.person_outline, Icons.person, t('Профиль')),
    ];
    final pages = DecoratedBox(
      // A faint accent glow at the top of every tab.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [FitColors.tint, FitColors.background],
        ),
      ),
      child: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            PageWidth(child: HomeScreen(onNavigate: _select)),
            PageWidth(
              maxWidth: 1180,
              child: CatalogScreen(key: ValueKey('catalog-$_catalogVisit'), onTryOn: _addToOutfit),
            ),
            PageWidth(child: TryOnScreen(key: _tryOnKey)),
            PageWidth(maxWidth: 1180, child: LooksScreen(key: ValueKey('looks-$_looksVisit'))),
            const PageWidth(child: ProfileScreen()),
          ],
        ),
      ),
    );
    return Scaffold(
      body: !wide
          ? pages
          : Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  extended: extended,
                  minExtendedWidth: 200,
                  labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      extended ? 'FitMe AI' : 'FitMe',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: FitColors.accentSoft),
                    ),
                  ),
                  destinations: [
                    for (final (icon, selected, label) in tabs)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(selected),
                        label: Text(label),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, color: FitColors.line),
                Expanded(child: pages),
              ],
            ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: [
                for (final (icon, selected, label) in tabs)
                  NavigationDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selected),
                    label: label,
                  ),
              ],
            ),
    );
  }
}

/// Live status of the connection to the laptop / GPU.
class ServerStatusCard extends StatefulWidget {
  const ServerStatusCard({super.key, this.showActions = true});

  final bool showActions;

  @override
  State<ServerStatusCard> createState() => _ServerStatusCardState();
}

class _ServerStatusCardState extends State<ServerStatusCard> {
  bool checking = true;
  bool online = false;
  bool aiReady = false;
  String? gpu;
  bool upscaler = false;
  bool wrongKey = false;
  String? problem;

  @override
  void initState() {
    super.initState();
    ServerConfig.baseUrlNotifier.addListener(_onUrl);
    _check();
  }

  @override
  void dispose() {
    ServerConfig.baseUrlNotifier.removeListener(_onUrl);
    super.dispose();
  }

  void _onUrl() => _check();

  Future<void> _check({bool search = false}) async {
    if (!mounted) return;
    setState(() => checking = true);
    if (search || !await ServerConfig.isFitMe(ServerConfig.baseUrl)) {
      await ServerConfig.discover();
    }
    var ok = await ServerConfig.isFitMe(ServerConfig.baseUrl);
    var ai = false;
    String? gpuName;
    var up = false;
    String? error;
    var badKey = false;
    if (ok) {
      try {
        final status = await FitMeApi.aiStatus();
        ai = status['online'] == true;
        final details = status['ai'];
        up = details is Map && details['upscaler'] == true;
        gpuName = details is Map ? details['gpu']?.toString() : null;
      } catch (e) {
        ok = false;
        error = e.toString();
        badKey = e is FitMeApiException && e.code == kBadKeyCode;
      }
    }
    if (!mounted) return;
    setState(() {
      checking = false;
      online = ok;
      aiReady = ai;
      gpu = gpuName;
      upscaler = up;
      wrongKey = badKey;
      problem = error;
    });
  }

  /// A website has no key built in: it is typed here when the link did not carry it.
  Future<void> _enterKey() async {
    final ctrl = TextEditingController(text: ServerConfig.accessKey);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('Ключ доступа')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: ctrl, autofocus: true),
            const SizedBox(height: 8),
            HintText(t('Ключ показан в окне START_LOCAL_GPU.bat на ноутбуке.')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(t('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, ctrl.text), child: Text(t('Сохранить'))),
        ],
      ),
    );
    ctrl.dispose();
    if (value == null) return;
    ServerConfig.setAccessKey(value);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final color = checking
        ? FitColors.muted
        : aiReady
        ? FitColors.ok
        : online
        ? FitColors.warn
        : FitColors.danger;
    final route = t(ServerConfig.routeLabel());
    final title = checking
        ? t('Подключение...')
        : aiReady
        ? t('AI готов • {route}', {'route': route})
        : online
        ? t('Сервер найден • {route}', {'route': route})
        : t('Нет связи с ноутбуком');
    final detail = checking
        ? t('Ищу сервер...')
        : aiReady
        ? [
            'FASHN VTON 1.5',
            ?gpu,
            if (upscaler) t('улучшение чёткости'),
          ].join(' • ')
        : online
        ? t('Сервер есть, но GPU не отвечает')
        : (problem ?? t('Сервер не найден'));
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: checking
                ? Padding(
                    padding: const EdgeInsets.all(11),
                    child: CircularProgressIndicator(strokeWidth: 2, color: color),
                  )
                : Icon(
                    aiReady ? Icons.bolt_rounded : (online ? Icons.memory : Icons.wifi_off_rounded),
                    color: color,
                    size: 21,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: FitColors.muted, fontSize: 12.5),
                ),
                if (!checking && !online) ...[
                  const SizedBox(height: 6),
                  HintText(
                    t('Запустите START_LOCAL_GPU.bat на ноутбуке и проверьте интернет. '
                        'Ноутбук должен быть включён.'),
                  ),
                ],
                if (kIsWeb && !checking && wrongKey)
                  TextButton(onPressed: _enterKey, child: Text(t('Ввести ключ'))),
              ],
            ),
          ),
          IconButton(
            tooltip: t('Обновить'),
            onPressed: checking ? null : () => _check(search: true),
            icon: Icon(Icons.refresh_rounded, color: FitColors.muted),
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _avatarVersion = 0;

  @override
  Widget build(BuildContext context) {
    final user = Session.user.value;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        ScreenTitle(
          user == null ? 'FitMe AI' : t('Привет, {name}!', {'name': user.displayName}),
          subtitle: t('Виртуальная примерочная'),
        ),
        const ServerStatusCard(),
        const AppDownloadCard(),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _QuickAction(
                icon: Icons.auto_awesome,
                title: t('Примерить'),
                subtitle: t('до 3 вещей'),
                primary: true,
                onTap: () => widget.onNavigate(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAction(
                icon: Icons.checkroom,
                title: t('Каталог'),
                subtitle: t('мои вещи'),
                onTap: () => widget.onNavigate(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(icon: Icons.accessibility_new, title: t('Мой аватар')),
              const SizedBox(height: 12),
              Avatar2DPreview(
                key: ValueKey('home-avatar-$_avatarVersion-${AvatarPhotoStore.revision}'),
                height: 250,
              ),
              const SizedBox(height: 10),
              HintText(t('Фото в полный рост без фона — выбирайте его на примерке кнопкой «Аватар».')),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const Avatar2DScreen()),
                    );
                    if (!mounted) return;
                    setState(() => _avatarVersion++);
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(t('Настроить аватар')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.white : FitColors.text;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: primary ? null : FitColors.card,
            border: primary ? null : Border.all(color: FitColors.line),
            gradient: primary
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [FitColors.accent, Color.lerp(FitColors.accent, const Color(0xFFE56BD3), .45)!],
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: primary ? Colors.white : FitColors.accentSoft),
              const SizedBox(height: 14),
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: fg)),
              Text(
                subtitle,
                style: TextStyle(color: fg.withValues(alpha: .72), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? usage;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    try {
      final data = await FitMeApi.me();
      if (mounted) setState(() => usage = data['usage'] as Map<String, dynamic>?);
    } catch (_) {
      // Shown without numbers when the laptop is offline.
    }
  }

  Future<String?> _ask(String title, {String initial = '', bool password = false, String? label}) async {
    final ctrl = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: password,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(t('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, ctrl.text), child: Text(t('Готово'))),
        ],
      ),
    );
    ctrl.dispose();
    return value;
  }

  Future<void> _editName() async {
    final name = await _ask(t('Имя'), initial: Session.user.value?.name ?? '');
    if (name == null || !mounted) return;
    try {
      await FitMeApi.updateName(name);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Future<void> _changePassword() async {
    final old = await _ask(t('Текущий пароль'), password: true);
    if (old == null || old.isEmpty || !mounted) return;
    final fresh = await _ask(t('Новый пароль'), password: true, label: t('Не короче 8 символов, буквы и цифры'));
    if (fresh == null || !mounted) return;
    final problem = passwordProblem(fresh);
    if (problem != null) {
      showMessage(context, problem);
      return;
    }
    try {
      await FitMeApi.changePassword(old, fresh);
      if (mounted) showMessage(context, t('Пароль изменён. На других устройствах нужно войти заново.'));
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Future<void> _logout() async {
    final ok = await confirmAction(context, title: t('Выйти из аккаунта?'), confirm: t('Выйти'));
    if (!ok) return;
    await FitMeApi.logout();
  }

  Future<void> _deleteAccount() async {
    final ok = await confirmAction(
      context,
      title: t('Удалить аккаунт?'),
      message: t('Удалятся ваш каталог, примерки и луки. Это нельзя отменить.'),
    );
    if (!ok || !mounted) return;
    final password = await _ask(t('Введите пароль для подтверждения'), password: true);
    if (password == null || password.isEmpty || !mounted) return;
    try {
      await FitMeApi.deleteAccount(password);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Widget _accountCard() {
    final user = Session.user.value;
    if (user == null) return const SizedBox.shrink();
    final u = usage;
    final limit = (u?['daily_limit'] as num?)?.toInt() ?? 0;
    return SectionCard(
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: FitColors.accent,
                child: Text(
                  user.displayName.substring(0, 1).toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    Text(user.email, style: TextStyle(color: FitColors.muted, fontSize: 13)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: FitColors.tint, borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        t(roleLabel(user.role)),
                        style: TextStyle(color: FitColors.accentSoft, fontSize: 11.5, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(tooltip: t('Изменить имя'), onPressed: _editName, icon: Icon(Icons.edit_outlined, color: FitColors.muted)),
            ],
          ),
          if (u != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                for (final (label, value) in [
                  (t('примерок'), '${u['tryons_total'] ?? 0}'),
                  (t('сегодня'), limit > 0 ? '${u['tryons_24h'] ?? 0}/$limit' : '${u['tryons_24h'] ?? 0}'),
                  (t('луков'), '${u['looks'] ?? 0}'),
                  (t('вещей'), '${u['catalog'] ?? 0}'),
                ])
                  Expanded(
                    child: Column(
                      children: [
                        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(label, style: TextStyle(color: FitColors.muted, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (user.isAdmin) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminScreen())),
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: Text(t('Админ-панель')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _manualAddress() async {
    final ctrl = TextEditingController(text: ServerConfig.manualUrl ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('Адрес сервера')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'https://....pinggy.link'),
            ),
            const SizedBox(height: 8),
            HintText(
              t('Обычно не нужно: приложение само находит ноутбук. '
                  'Оставьте пустым, чтобы вернуть автопоиск.'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, ctrl.text),
            child: Text(t('Сохранить')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (value == null || !mounted) return;
    ServerConfig.setManualUrl(value);
    final found = await ServerConfig.discover();
    if (!mounted) return;
    showMessage(
      context,
      found
          ? t('Подключено: {route}', {'route': t(ServerConfig.routeLabel())})
          : t('Сервер по этому адресу не найден'),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        ScreenTitle(t('Профиль'), subtitle: t('Аккаунт и настройки')),
        _accountCard(),
        const SizedBox(height: 14),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(icon: Icons.palette_outlined, title: t('Оформление')),
              const SizedBox(height: 14),
              Text(t('Тема'), style: TextStyle(color: FitColors.soft, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                      label: Text(t('Авто')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode_outlined, size: 18),
                      label: Text(t('Светлая')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode_outlined, size: 18),
                      label: Text(t('Тёмная')),
                    ),
                  ],
                  selected: {AppSettings.themeMode},
                  onSelectionChanged: (s) => AppSettings.themeMode = s.first,
                ),
              ),
              const SizedBox(height: 16),
              Text(t('Язык'), style: TextStyle(color: FitColors.soft, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppLang>(
                  showSelectedIcon: false,
                  segments: [
                    for (final lang in AppLang.values)
                      ButtonSegment(value: lang, label: Text(lang.title)),
                  ],
                  selected: {AppSettings.lang},
                  onSelectionChanged: (s) => AppSettings.lang = s.first,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SectionCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.accessibility_new),
                title: Text(t('Мой аватар')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Avatar2DScreen())),
              ),
              ListTile(
                leading: const Icon(Icons.password),
                title: Text(t('Сменить пароль')),
                trailing: const Icon(Icons.chevron_right),
                onTap: _changePassword,
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(t('Выйти из аккаунта')),
                onTap: _logout,
              ),
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: FitColors.danger),
                title: Text(t('Удалить аккаунт'), style: TextStyle(color: FitColors.danger)),
                onTap: Session.user.value?.isOwner == true ? null : _deleteAccount,
                subtitle: Session.user.value?.isOwner == true ? Text(t('Аккаунт создателя удалить нельзя')) : null,
              ),
            ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            t('Подключение'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        const ServerStatusCard(),
        const SizedBox(height: 10),
        ValueListenableBuilder<String>(
          valueListenable: ServerConfig.baseUrlNotifier,
          builder: (context, url, _) => SectionCard(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, color: FitColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: FitColors.soft, fontSize: 12),
                  ),
                ),
                TextButton(onPressed: _manualAddress, child: Text(t('Изменить'))),
              ],
            ),
          ),
        ),
        if (!kIsWeb) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: HintText(
              t('Дома телефон подключается к ноутбуку по Wi-Fi, вне дома — через интернет-туннель. '
                  'Ноутбук должен быть включён с запущенным START_LOCAL_GPU.bat.'),
            ),
          ),
        ],
      ],
    );
  }
}
