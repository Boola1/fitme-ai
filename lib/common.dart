import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'i18n.dart';

/// The website's link to the Android app; stays hidden until the APK is part of the site.
class AppDownloadCard extends StatefulWidget {
  const AppDownloadCard({super.key});

  @override
  State<AppDownloadCard> createState() => _AppDownloadCardState();
}

class _AppDownloadCardState extends State<AppDownloadCard> {
  final Uri _apk = Uri.base.resolve('downloads/FitMe.apk');
  bool _available = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) _check();
  }

  Future<void> _check() async {
    try {
      final response = await http.head(_apk);
      if (mounted && response.statusCode == 200) setState(() => _available = true);
    } catch (_) {
      // No link is better than a broken one.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: SectionCard(
        child: Row(
          children: [
            Icon(Icons.android, color: FitColors.ok, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('Приложение для Android'), style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  HintText(t('Установите FitMe на телефон. После скачивания разрешите установку из этого источника.')),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => launchUrl(_apk, webOnlyWindowName: '_self'),
              icon: const Icon(Icons.download_rounded),
              label: Text(t('Скачать')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps a phone-sized column readable in a wide browser window.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, this.maxWidth = 720, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Shared colours. They follow the current theme: FitMeApp sets [dark] before
/// the screens are built and rebuilds the whole tree when it changes.
class FitColors {
  FitColors._();

  static bool dark = true;

  static Color get background => dark ? const Color(0xFF0E0F14) : const Color(0xFFF4F3F9);
  static Color get card => dark ? const Color(0xFF181920) : const Color(0xFFFFFFFF);
  static Color get cardHigh => dark ? const Color(0xFF22232C) : const Color(0xFFEEECF6);
  static Color get accent => dark ? const Color(0xFF8B7CF6) : const Color(0xFF6C5CE7);
  static Color get accentSoft => dark ? const Color(0xFFB9AEFF) : const Color(0xFF5B4BD6);
  static Color get ok => dark ? const Color(0xFF5FD39A) : const Color(0xFF1E9E63);
  static Color get warn => dark ? const Color(0xFFF2B35B) : const Color(0xFFC07A12);
  static Color get danger => dark ? const Color(0xFFFF6B6B) : const Color(0xFFD63B3B);

  /// Text and lines.
  static Color get text => dark ? const Color(0xFFF2F1F7) : const Color(0xFF17161D);
  static Color get soft => dark ? const Color(0xB3FFFFFF) : const Color(0xB3000000);
  static Color get muted => dark ? const Color(0x94FFFFFF) : const Color(0x8F000000);
  static Color get faint => dark ? const Color(0x66FFFFFF) : const Color(0x6B000000);
  static Color get line => dark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  static Color get line2 => dark ? const Color(0x33FFFFFF) : const Color(0x29000000);

  /// Soft accent wash used behind section icons and the top of every screen.
  static Color get tint => accent.withValues(alpha: dark ? .16 : .10);
}

/// Shop page titles make poor item names ("Купить Анорак NAPAPIJRI голубой в Астане –
/// Магазин на Kaspi.kz"). Keeps only the product part for display.
String cleanProductName(String raw) {
  final original = raw.trim();
  var s = original;
  s = s.replaceFirst(RegExp(r'^(купить|buy)\s+', caseSensitive: false), '');
  // "... в Астане – Магазин на Kaspi.kz", "... | Wildberries", "... — купить в интернет-магазине"
  // The city starts with a capital letter, so "Рубашка в клетку – Магазин" keeps "в клетку".
  s = s.replaceFirst(
    RegExp(r'\s+в\s+[А-ЯЁ][A-Za-zА-Яа-яЁё-]*\s*[–—|-]\s*([Ии]нтернет-)?[Мм]агазин.*$'),
    '',
  );
  s = s.replaceFirst(
    RegExp(
      r'(\s*[–—|]\s*|\s+-\s+)((интернет-)?магазин|купить|kaspi|wildberries|ozon|lamoda).*$',
      caseSensitive: false,
    ),
    '',
  );
  s = s.trim();
  if (s.isEmpty) return original;
  return s[0].toUpperCase() + s.substring(1);
}

/// '#RRGGBB' -> Color (grey when the text is not a colour).
Color hexColor(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return value == null ? const Color(0xFF888888) : Color(0xFF000000 | value);
}

/// Russian key of an account role for t().
String roleLabel(String role) => switch (role) {
  'owner' => 'Создатель',
  'admin' => 'Администратор',
  _ => 'Клиент',
};

String categoryRu(String value) {
  switch (value) {
    case 'lower_body':
      return t('Низ');
    case 'dresses':
      return t('Платье');
    default:
      return t('Верх');
  }
}

class GarmentTypeChoice {
  const GarmentTypeChoice(this.label, this.aiCategory);

  final String label;
  final String aiCategory;
}

const garmentTypeChoices = <GarmentTypeChoice>[
  GarmentTypeChoice('Футболка', 'upper_body'),
  GarmentTypeChoice('Топ', 'upper_body'),
  GarmentTypeChoice('Рубашка', 'upper_body'),
  GarmentTypeChoice('Блузка', 'upper_body'),
  GarmentTypeChoice('Худи', 'upper_body'),
  GarmentTypeChoice('Свитер', 'upper_body'),
  GarmentTypeChoice('Куртка', 'upper_body'),
  GarmentTypeChoice('Пиджак', 'upper_body'),
  GarmentTypeChoice('Пальто', 'upper_body'),
  GarmentTypeChoice('Джинсы', 'lower_body'),
  GarmentTypeChoice('Брюки', 'lower_body'),
  GarmentTypeChoice('Шорты', 'lower_body'),
  GarmentTypeChoice('Юбка', 'lower_body'),
  GarmentTypeChoice('Платье', 'dresses'),
];

String garmentTypeFor(String text, String aiCategory) {
  final q = text.toLowerCase();

  // Order matters: 'sweatshirt' contains 'tshirt' and 'shirt'; 't-shirt' must win over 'shirt'.
  const keywords = <String, String>{
    'sweatshirt': 'Свитер',
    'свитшот': 'Свитер',
    'футбол': 'Футболка',
    't-shirt': 'Футболка',
    'tshirt': 'Футболка',
    'shirt': 'Рубашка',
    'рубаш': 'Рубашка',
    'hood': 'Худи',
    'худи': 'Худи',
    'sweater': 'Свитер',
    'свит': 'Свитер',
    'jacket': 'Куртка',
    'куртк': 'Куртка',
    'blazer': 'Пиджак',
    'пидж': 'Пиджак',
    'coat': 'Пальто',
    'пальто': 'Пальто',
    'jean': 'Джинсы',
    'джинс': 'Джинсы',
    'trouser': 'Брюки',
    'pant': 'Брюки',
    'брюк': 'Брюки',
    'short': 'Шорты',
    'шорт': 'Шорты',
    'skirt': 'Юбка',
    'юбк': 'Юбка',
    'dress': 'Платье',
    'плать': 'Платье',
  };

  for (final entry in keywords.entries) {
    if (q.contains(entry.key)) return entry.value;
  }

  switch (aiCategory) {
    case 'lower_body':
      return 'Брюки';
    case 'dresses':
      return 'Платье';
    default:
      return 'Футболка';
  }
}

GarmentTypeChoice garmentChoiceFor(String label) {
  return garmentTypeChoices.firstWhere(
    (c) => c.label == label,
    orElse: () => garmentTypeChoices.first,
  );
}

Future<GarmentTypeChoice?> showGarmentTypePicker(
  BuildContext context, {
  required String selectedLabel,
}) {
  return showModalBottomSheet<GarmentTypeChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: FitColors.card,
    builder: (sheetContext) {
      var query = '';

      return StatefulBuilder(
        builder: (context, setLocalState) {
          final items = garmentTypeChoices
              .where(
                (item) =>
                    t(item.label).toLowerCase().contains(query.toLowerCase()) ||
                    item.label.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                18,
                18 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .58,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Что это за вещь?'),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      onChanged: (value) {
                        setLocalState(() => query = value.trim());
                      },
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: t('Например: джинсы'),
                        isDense: true,
                      ),
                    ),
                    SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: FitColors.line),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final selected = item.label == selectedLabel;
                          return ListTile(
                            dense: true,
                            title: Text(t(item.label)),
                            subtitle: Text(
                              categoryRu(item.aiCategory),
                              style: TextStyle(color: FitColors.faint),
                            ),
                            trailing: selected
                                ? Icon(
                                    Icons.check_circle,
                                    color: FitColors.accentSoft,
                                  )
                                : null,
                            onTap: () => Navigator.pop(sheetContext, item),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class CompactGarmentTypeField extends StatelessWidget {
  const CompactGarmentTypeField({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(Icons.search, size: 19),
        label: Row(
          children: [
            Expanded(
              child: Text(
                t(label),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: FitColors.text,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down),
          ],
        ),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(horizontal: 13),
          side: BorderSide(color: FitColors.line2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.highlight = false,
  });

  final Widget child;
  final EdgeInsets padding;

  /// Accent border + glow for the card that matters most on the screen.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final dark = FitColors.dark;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: FitColors.card,
        gradient: dark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(FitColors.card, Colors.white, .035)!, FitColors.card],
              )
            : null,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: highlight ? FitColors.accent.withValues(alpha: .55) : FitColors.line,
        ),
        boxShadow: [
          if (!dark)
            BoxShadow(
              color: const Color(0xFF2A2350).withValues(alpha: .07),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          if (highlight)
            BoxShadow(
              color: FitColors.accent.withValues(alpha: dark ? .22 : .16),
              blurRadius: 26,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: child,
    );
  }
}

/// Icon in a soft accent square + bold title, used at the top of cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: FitColors.tint,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: FitColors.accentSoft),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.6,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: TextStyle(color: FitColors.muted, height: 1.3)),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small grey explanation under a control.
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(color: FitColors.faint, fontSize: 12, height: 1.35));
  }
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  String? confirm,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(t('Отмена')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirm ?? t('Удалить')),
        ),
      ],
    ),
  );
  return result ?? false;
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<void> openProductSource(BuildContext context, String rawUrl) async {
  var value = rawUrl.trim();
  if (value.isEmpty) return;
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'https://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null ||
      !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (!context.mounted) return;
    showMessage(context, t('Не удалось открыть ссылку товара'));
  }
}

/// Before/after comparison: drag anywhere on the picture to move the divider.
/// Both pictures should have the same aspect (FASHN keeps the original photo size).
class BeforeAfterView extends StatefulWidget {
  const BeforeAfterView({super.key, required this.before, required this.after});

  final Widget before;
  final Widget after;

  @override
  State<BeforeAfterView> createState() => _BeforeAfterViewState();
}

class _BeforeAfterViewState extends State<BeforeAfterView> {
  double split = 0.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        void move(double dx) => setState(() => split = (dx / w).clamp(0.0, 1.0));
        Widget tag(String text) => Container(
          padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => move(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => move(d.localPosition.dx),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.after,
              ClipRect(clipper: _LeftPart(split), child: widget.before),
              Positioned(
                left: split * w - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.white),
              ),
              Positioned(
                left: split * w - 18,
                top: box.maxHeight / 2 - 18,
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white,
                  child: Icon(Icons.compare_arrows, color: Colors.black87, size: 20),
                ),
              ),
              if (split > .12) Positioned(left: 10, top: 10, child: tag(t('До'))),
              if (split < .88) Positioned(right: 10, top: 10, child: tag(t('После'))),
            ],
          ),
        );
      },
    );
  }
}

class _LeftPart extends CustomClipper<Rect> {
  const _LeftPart(this.split);

  final double split;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * split, size.height);

  @override
  bool shouldReclip(_LeftPart oldClipper) => oldClipper.split != split;
}

/// Fullscreen zoomable image (pinch to zoom).
void openZoom(BuildContext context, Widget image, {String? title}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: title == null ? null : Text(title),
        ),
        body: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(child: image),
        ),
      ),
    ),
  );
}
