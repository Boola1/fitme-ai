import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'avatar_2d.dart';
import 'common.dart';
import 'i18n.dart';
import 'platform/local_files.dart';

const int kMaxOutfitItems = 3;

/// Rough FASHN speed on the RTX 4060 laptop: seconds per diffusion step,
/// plus fixed work per garment (upload, pose, parsing, upscale, paste-back).
const double kSecondsPerStep = 1.8; // v5 lab: 20 steps 44 s, 30 steps 62 s of GPU time
const double kSecondsPerGarment = 20;

/// Quality presets: diffusion steps sent to the server.
/// Labels are Russian keys for t().
// v5 lab: 15 steps sometimes paints trousers as a flat black block; 20 is the fastest safe setting.
const kQualityPresets = <(int, String)>[(20, 'Быстро'), (30, 'Баланс'), (50, 'Максимум')];

/// Keeps the photo chosen for try-on (separate from the avatar, which it must not overwrite).
class PersonPhotoStore {
  PersonPhotoStore._();

  /// Per account: someone else signing in on this phone must not get this photo.
  static String get _account =>
      (Session.user.value?.id ?? 'guest').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String get _key => 'person_path_$_account';

  static Future<XFile?> loadPhoto() async {
    final saved = SettingsStore.get<String>(_key);
    if (saved != null) {
      // Older versions saved the full path; the folder is always the same.
      final photo = await LocalFiles.open(saved.split(RegExp(r'[\\/]')).last);
      if (photo != null) return photo;
    }
    return AvatarPhotoStore.loadPhoto();
  }

  static void remember(String name) => SettingsStore.set(_key, name);

  /// Copies a picked photo under a new unique name and removes the previous copy.
  static Future<XFile> save(XFile image) async {
    final lower = image.name.toLowerCase();
    final ext = lower.endsWith('.png') ? '.png' : '.jpg';
    final prefix = 'tryon_person_${_account}_';
    final name = '$prefix${DateTime.now().millisecondsSinceEpoch}$ext';
    await LocalFiles.writeBytes(name, await image.readAsBytes());
    try {
      for (final old in await LocalFiles.list(prefix)) {
        if (old != name) await LocalFiles.delete(old);
      }
    } catch (_) {
      // Old copies are only a few MB; never fail the pick because of cleanup.
    }
    remember(name);
    return (await LocalFiles.open(name))!;
  }
}

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key});

  @override
  State<TryOnScreen> createState() => TryOnScreenState();
}

class TryOnScreenState extends State<TryOnScreen> {
  final picker = ImagePicker();
  final _scroll = ScrollController();
  final _resultKey = GlobalKey();

  XFile? personPhoto;
  final List<OutfitItem> outfit = [];

  String size = 'M';
  String fit = 'Regular';
  int quality = SettingsStore.get<int>('quality') ?? 20;
  int seed = 42;
  bool pickingPerson = false;

  List<TryOnModel> models = const [TryOnModel.fallback];
  String modelId = SettingsStore.get<String>('model') ?? 'fashn';
  bool modelsLoading = false;

  bool busy = false;
  String status = 'idle';
  String? jobId;
  int step = 0;
  int totalSteps = 1;
  String? stepLabel;
  DateTime? startedAt;
  Duration elapsed = Duration.zero;
  Timer? _ticker;

  String? resultUrl;
  String? error;
  int queueAhead = 0;

  // Re-colouring of the finished picture (no new generation needed).
  String? shownUrl; // the result on screen
  final Set<String> savedUrls = {};

  bool get saved => shownUrl != null && savedUrls.contains(shownUrl);

  @override
  void initState() {
    super.initState();
    if (!kQualityPresets.any((p) => p.$1 == quality)) quality = 20;
    _loadPerson();
    _loadModels();
  }

  TryOnModel get model =>
      models.firstWhere((m) => m.id == modelId, orElse: () => models.first);

  Future<void> _loadModels({bool refresh = false}) async {
    // Also called from initState, where setState is not allowed yet.
    modelsLoading = true;
    if (refresh && mounted) setState(() {});
    try {
      final list = await FitMeApi.models(refresh: refresh);
      if (!mounted) return;
      setState(() => models = list);
    } catch (_) {
      // Keep the laptop model; the status card already explains connection problems.
    } finally {
      if (mounted) setState(() => modelsLoading = false);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ public

  /// Called from the catalog tab ("В образ").
  void addCatalogItem(CatalogItem item) {
    if (busy) {
      showMessage(context, t('Дождитесь окончания текущей примерки'));
      return;
    }
    if (outfit.any((it) => it.catalog?.id == item.id)) {
      showMessage(context, t('«{name}» уже в образе', {'name': item.displayName}));
      return;
    }
    if (outfit.length >= kMaxOutfitItems) {
      showMessage(context, t('В образе максимум {n} вещи', {'n': kMaxOutfitItems}));
      return;
    }
    setState(() {
      outfit.add(
        OutfitItem(
          catalog: item,
          category: item.category,
          label: garmentTypeFor('${item.name} ${item.description}', item.category),
        ),
      );
      _resetResult();
    });
    showMessage(context, t('Добавлено в образ: {name}', {'name': item.displayName}));
  }

  // ------------------------------------------------------------------ person

  Future<void> _loadPerson() async {
    final photo = await PersonPhotoStore.loadPhoto();
    if (!mounted || photo == null || personPhoto != null) return;
    setState(() => personPhoto = photo);
  }

  Future<void> _pickPerson(ImageSource source) async {
    XFile? image;
    try {
      image = await picker.pickImage(
        source: source,
        imageQuality: 95,
        maxWidth: 2200,
        maxHeight: 2200,
      );
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          source == ImageSource.camera
              ? t('Не удалось открыть камеру: {e}', {'e': e})
              : t('Не удалось открыть галерею: {e}', {'e': e}),
        );
      }
      return;
    }
    if (image == null || !mounted) return;
    setState(() => pickingPerson = true);
    try {
      final photo = await PersonPhotoStore.save(image);
      if (!mounted) return;
      setState(() {
        personPhoto = photo;
        _resetResult();
      });
    } catch (e) {
      if (mounted) showMessage(context, t('Не удалось сохранить фото: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => pickingPerson = false);
    }
  }

  Future<void> _useSavedAvatar() async {
    var photo = await AvatarPhotoStore.loadPhoto();
    if (photo == null && mounted) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => Avatar2DScreen()));
      photo = await AvatarPhotoStore.loadPhoto();
    }
    if (!mounted) return;
    if (photo == null) {
      showMessage(context, t('Аватар ещё не создан'));
      return;
    }
    PersonPhotoStore.remember(photo.name);
    setState(() {
      personPhoto = photo;
      _resetResult();
    });
  }

  // ------------------------------------------------------------------ outfit

  Future<void> _addGarment() async {
    if (outfit.length >= kMaxOutfitItems) {
      showMessage(context, t('В образе максимум {n} вещи', {'n': kMaxOutfitItems}));
      return;
    }
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t('Добавить вещь в образ'),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              SizedBox(height: 8),
              for (final option in [
                ('gallery', Icons.photo_library_outlined, t('Фото из галереи')),
                ('camera', Icons.photo_camera_outlined, t('Сфотографировать')),
                ('catalog', Icons.checkroom, t('Из каталога')),
                ('url', Icons.link, t('По ссылке на товар')),
              ])
                ListTile(
                  leading: Icon(option.$2),
                  title: Text(option.$3),
                  onTap: () => Navigator.pop(sheetContext, option.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (mode == null || !mounted) return;
    switch (mode) {
      case 'gallery':
      case 'camera':
        await _addPhotoGarment(
          mode == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
      case 'catalog':
        await _addFromCatalog();
      case 'url':
        await _addFromUrl();
    }
  }

  Future<void> _addPhotoGarment(ImageSource source) async {
    final image = await picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1800,
    );
    if (image == null || !mounted) return;
    final choice = await showGarmentTypePicker(context, selectedLabel: '');
    if (choice == null || !mounted) return;
    setState(() {
      outfit.add(
        OutfitItem(
          photo: image,
          category: choice.aiCategory,
          label: choice.label,
        ),
      );
      _resetResult();
    });
  }

  Future<void> _addFromCatalog() async {
    List<CatalogItem> items;
    try {
      items = await FitMeApi.getCatalog();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Каталог недоступен: {e}', {'e': e}));
      return;
    }
    if (!mounted) return;
    if (items.isEmpty) {
      showMessage(context, t('Каталог пуст — добавьте вещи на вкладке «Каталог»'));
      return;
    }
    final picked = await showModalBottomSheet<CatalogItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .7,
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.72,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return InkWell(
              onTap: () => Navigator.pop(sheetContext, item),
              borderRadius: BorderRadius.circular(14),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: NetImage(item.imageUrl, fit: BoxFit.contain),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    item.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (picked != null && mounted) addCatalogItem(picked);
  }

  Future<void> _addFromUrl() async {
    final urlCtrl = TextEditingController();
    var choice = garmentTypeChoices.first;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: Text(t('Ссылка на товар')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'https://...',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              SizedBox(height: 12),
              CompactGarmentTypeField(
                label: choice.label,
                enabled: true,
                onTap: () async {
                  final selected = await showGarmentTypePicker(
                    dialogContext,
                    selectedLabel: choice.label,
                  );
                  if (selected != null) setLocal(() => choice = selected);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t('Отмена')),
            ),
            FilledButton(
              onPressed: () {
                final value = urlCtrl.text.trim();
                if (value.isNotEmpty) Navigator.pop(dialogContext, value);
              },
              child: Text(t('Найти фото')),
            ),
          ],
        ),
      ),
    );
    urlCtrl.dispose();
    if (result == null || !mounted) return;

    showMessage(context, t('Ищу фото товара...'));
    try {
      final item = await FitMeApi.importCatalogItemFromUrl(
        sourceUrl: result,
        category: choice.aiCategory,
      );
      if (!mounted) return;
      addCatalogItem(item);
    } catch (e) {
      if (!mounted) return;
      showMessage(
        context,
        t('Не удалось найти фото по ссылке. Добавьте фото вручную. ({e})', {'e': e}),
      );
    }
  }

  Future<void> _editGarment(OutfitItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setLocal) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.category_outlined),
                  title: Text(t('Тип: {type}', {'type': t(item.label)})),
                  subtitle: Text(categoryRu(item.category)),
                  trailing: Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(sheetContext, 'type'),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('Как снята вещь'),
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<int>(
                          segments: [
                            ButtonSegment(value: 0, label: Text(t('Авто'))),
                            ButtonSegment(value: 1, label: Text(t('Отдельно'))),
                            ButtonSegment(value: 2, label: Text(t('На человеке'))),
                          ],
                          selected: {
                            item.onModel == null ? 0 : (item.onModel! ? 2 : 1),
                          },
                          onSelectionChanged: (s) {
                            setLocal(() {
                              item.onModel = switch (s.first) {
                                1 => false,
                                2 => true,
                                _ => null,
                              };
                            });
                            setState(_resetResult);
                          },
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        t('Авто — сервер сам увидит, надета ли вещь на человека, и вырежет только её '
                        '(без рук и лица модели).'),
                        style: TextStyle(color: FitColors.faint, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: FitColors.danger),
                  title: Text(t('Убрать из образа')),
                  onTap: () => Navigator.pop(sheetContext, 'remove'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'remove') {
      setState(() {
        outfit.remove(item);
        _resetResult();
      });
    } else if (action == 'type') {
      final choice = await showGarmentTypePicker(
        context,
        selectedLabel: item.label,
      );
      if (choice == null || !mounted) return;
      setState(() {
        item
          ..label = choice.label
          ..category = choice.aiCategory;
        _resetResult();
      });
    }
  }

  // ------------------------------------------------------------------ job

  void _resetResult() {
    status = 'idle';
    jobId = null;
    resultUrl = null;
    error = null;
    step = 0;
    queueAhead = 0;
    shownUrl = null;
    savedUrls.clear();
  }

  int get _etaSeconds {
    final perGarment = model.isLocal
        ? quality * kSecondsPerStep + kSecondsPerGarment
        : 60.0; // free cloud GPUs: queue + model time
    return (perGarment * math.max(1, outfit.length) + 4).round();
  }

  String _formatSeconds(int s) =>
      s < 60
          ? t('{s} с', {'s': s})
          : t('{m} мин {s} с', {'m': s ~/ 60, 's': (s % 60).toString().padLeft(2, '0')});

  Future<void> _start({bool newVariant = false}) async {
    if (personPhoto == null) {
      setState(() => error = t('Сначала выберите фото человека.'));
      return;
    }
    if (outfit.isEmpty) {
      setState(() => error = t('Добавьте в образ хотя бы одну вещь.'));
      return;
    }
    final unsupported = outfit.where((it) => !model.supports(it.category)).toList();
    if (unsupported.isNotEmpty) {
      setState(() => error =
          t('{model} не умеет: {items}. Выберите другую модель или уберите эти вещи.', {
            'model': model.title,
            'items': unsupported.map((it) => t(it.label)).join(', '),
          }));
      return;
    }
    if (!model.available) {
      setState(() => error = t('{model} сейчас недоступна: {why}', {
            'model': model.title,
            'why': t(model.reason ?? 'нет связи'),
          }));
      return;
    }
    if (newVariant) seed = math.Random().nextInt(1 << 30);

    setState(() {
      busy = true;
      status = 'uploading';
      error = null;
      resultUrl = null;
      shownUrl = null;
        savedUrls.clear();
      step = 0;
      queueAhead = 0;
      totalSteps = outfit.length;
      stepLabel = null;
      startedAt = DateTime.now();
      elapsed = Duration.zero;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(Duration(seconds: 1), (_) {
      if (!mounted || startedAt == null) return;
      setState(() => elapsed = DateTime.now().difference(startedAt!));
    });

    try {
      final created = await FitMeApi.uploadOutfit(
        personPhoto: personPhoto!,
        items: List.of(outfit),
        title: outfit.map((it) => it.label).join(' + '),
        selectedSize: size,
        selectedFit: fit,
        numSteps: quality,
        seed: seed,
        model: model.id,
      );
      if (!mounted) return;
      setState(() {
        jobId = created['job_id'] as String;
        status = created['status']?.toString() ?? 'queued';
        totalSteps = (created['total_steps'] as num?)?.toInt() ?? outfit.length;
      });
      await _poll(jobId!);
    } catch (e) {
      _finish(error: e.toString());
    }
  }

  void _finish({String? error, String? result}) {
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      busy = false;
      if (error != null) {
        status = 'failed';
        this.error = error;
      } else {
        status = 'completed';
        resultUrl = result;
        shownUrl = result;
      }
    });
    if (error == null) {
      // Bring the new picture into view (the form above it is long).
      void reveal(bool mayJump) {
        final ctx = _resultKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        } else if (mayJump && _scroll.hasClients) {
          // The list builds only what is near the screen: go to its end so the result exists.
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
          WidgetsBinding.instance.addPostFrameCallback((_) => reveal(false));
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) => reveal(true));
    }
  }

  Future<void> _poll(String id) async {
    var failures = 0;
    final deadline = DateTime.now().add(Duration(minutes: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: 2));
      if (!mounted) return;
      try {
        final job = await FitMeApi.getJob(id);
        failures = 0;
        if (!mounted) return;
        final s = job['status']?.toString() ?? 'unknown';
        setState(() {
          status = s;
          step = (job['step'] as num?)?.toInt() ?? step;
          totalSteps = (job['total_steps'] as num?)?.toInt() ?? totalSteps;
          stepLabel = job['step_label']?.toString() ?? stepLabel;
          queueAhead = (job['queue_position'] as num?)?.toInt() ?? 0;
        });
        if (s == 'completed') {
          _finish(result: job['result_url']?.toString());
          return;
        }
        if (s == 'failed' || s == 'not_found') {
          final raw = job['error']?.toString() ?? '';
          _finish(
            error: s == 'not_found'
                ? t('Сервер перезапускался — запустите примерку ещё раз.')
                : raw.isEmpty
                ? t('AI не смог завершить примерку.')
                : raw,
          );
          return;
        }
      } catch (e) {
        failures++;
        if (failures >= 6) {
          _finish(error: e.toString());
          return;
        }
      }
    }
    _finish(error: t('Превышено время ожидания. Проверьте окно «FitMe GPU» на ноутбуке.'));
  }

  Future<void> _saveLook() async {
    final url = shownUrl;
    if (jobId == null || url == null || saved) return;
    try {
      await FitMeApi.saveLook(
        jobId!,
        title: outfit.map((it) => it.label).join(' + '),
        size: size,
        fit: fit,
        resultUrl: url,
      );
      if (!mounted) return;
      setState(() => savedUrls.add(url));
      showMessage(context, t('Образ сохранён в «Луки»'));
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Ошибка сохранения: {e}', {'e': e}));
    }
  }

  void _newOutfit() {
    setState(() {
      outfit.clear();
      _resetResult();
    });
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            children: [
              ScreenTitle(
                t('Примерка'),
                subtitle: t('Соберите образ до 3 вещей — AI наденет их по очереди'),
              ),
              _personSection(),
              const SizedBox(height: 14),
              _outfitSection(),
              const SizedBox(height: 14),
              _modelSection(),
              const SizedBox(height: 14),
              _qualitySection(),
              const SizedBox(height: 14),
              _extraParameters(),
              if (resultUrl != null && personPhoto != null) ...[
                const SizedBox(height: 22),
                KeyedSubtree(key: _resultKey, child: _resultSection()),
              ],
            ],
          ),
        ),
        _actionBar(),
      ],
    );
  }

  /// Always visible under the form: the "try on" button, or the progress while AI works.
  Widget _actionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: FitColors.card,
        border: Border(top: BorderSide(color: FitColors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null && !busy) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: FitColors.danger, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: FitColors.danger, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (busy) _progressBar() else _generateButton(),
        ],
      ),
    );
  }

  Widget _personSection() {
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(icon: Icons.person_outline, title: t('Кто примеряет')),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: personPhoto == null
                ? null
                : () => openZoom(context, PhotoImage(personPhoto!)),
            child: Container(
              height: 240,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: FitColors.cardHigh,
                borderRadius: BorderRadius.circular(18),
              ),
              child: personPhoto == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_add_alt_1, size: 54, color: FitColors.faint),
                        const SizedBox(height: 8),
                        Text(
                          t('Фото в полный рост, лицом к камере'),
                          style: TextStyle(color: FitColors.muted),
                        ),
                      ],
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        PhotoImage(
                          personPhoto!,
                          fit: BoxFit.contain,
                          alignment: Alignment.topCenter,
                          errorBuilder: (_, _, _) => Center(
                            child: Text(
                              t('Фото не открылось — выберите другое'),
                              style: TextStyle(color: FitColors.muted),
                            ),
                          ),
                        ),
                        if (pickingPerson)
                          const ColoredBox(
                            color: Color(0x88000000),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.photo_library_outlined,
                  label: t('Галерея'),
                  onTap: busy || pickingPerson ? null : () => _pickPerson(ImageSource.gallery),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.photo_camera_outlined,
                  label: t('Камера'),
                  onTap: busy || pickingPerson ? null : () => _pickPerson(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.person,
                  label: t('Аватар'),
                  filled: true,
                  onTap: busy || pickingPerson ? null : _useSavedAvatar,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _outfitSection() {
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.checkroom,
            title: t('Образ • {n}/{max}', {'n': outfit.length, 'max': kMaxOutfitItems}),
            trailing: outfit.isNotEmpty && !busy
                ? TextButton(onPressed: _newOutfit, child: Text(t('Очистить')))
                : null,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final item in outfit)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _GarmentTile(
                      item: item,
                      onTap: busy ? null : () => _editGarment(item),
                    ),
                  ),
                if (outfit.length < kMaxOutfitItems)
                  _AddTile(onTap: busy ? null : _addGarment),
              ],
            ),
          ),
          const SizedBox(height: 10),
          HintText(
            outfit.length > 1
                ? t('Порядок: сначала низ, потом платье, потом верх и верхняя одежда.')
                : t('Например: джинсы + футболка + куртка. Нажмите на вещь, чтобы изменить тип.'),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseModel() async {
    if (models.length <= 1 && !modelsLoading) unawaited(_loadModels(refresh: true));
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * .8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                t('Модель примерки'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                t('Примерки делает ваша видеокарта, а когда запущен блокнот Kaggle — ещё и его видеокарты.'),
                style: TextStyle(color: FitColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final m in models)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: m.available,
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: m.available ? FitColors.tint : FitColors.cardHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      m.isLocal ? Icons.laptop_chromebook : Icons.cloud_outlined,
                      size: 20,
                      color: m.available ? FitColors.accentSoft : FitColors.line2,
                    ),
                  ),
                  title: Text(t(m.title), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    [
                      t(m.where),
                      t(m.limit),
                      if (m.categories.length < 3)
                        t('только {what}', {'what': m.categories.map(categoryRu).join(', ').toLowerCase()}),
                      m.available ? t(m.note) : t(m.reason ?? 'недоступна'),
                      if (m.needsToken && m.available) t('без HF-токена лимит меньше'),
                    ].where((text) => text.isNotEmpty).join(' • '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: m.id == modelId
                      ? Icon(Icons.check_circle, color: FitColors.accentSoft)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, m.id),
                ),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _loadModels(refresh: true);
                },
                icon: const Icon(Icons.refresh),
                label: Text(t('Проверить доступность заново')),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      modelId = picked;
      error = null;
    });
    SettingsStore.set('model', picked);
  }

  Widget _modelSection() {
    final m = model;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : _chooseModel,
        borderRadius: BorderRadius.circular(24),
        child: SectionCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: m.available ? FitColors.tint : FitColors.warn.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  m.isLocal ? Icons.laptop_chromebook : Icons.cloud_outlined,
                  size: 18,
                  color: m.available ? FitColors.accentSoft : FitColors.warn,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Модель: {name}', {'name': t(m.title)}),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
                    ),
                    Text(
                      m.available ? '${t(m.where)} • ${t(m.limit)}' : t(m.reason ?? 'недоступна'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: m.available ? FitColors.muted : FitColors.warn,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (modelsLoading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.chevron_right, color: FitColors.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _qualitySection() {
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.high_quality_outlined,
            title: t('Качество'),
            trailing: Text(
              '≈ ${_formatSeconds(_etaSeconds)}',
              style: TextStyle(color: FitColors.muted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (final preset in kQualityPresets)
                  ButtonSegment(value: preset.$1, label: Text(t(preset.$2))),
              ],
              selected: {quality},
              onSelectionChanged: busy
                  ? null
                  : (s) {
                      setState(() => quality = s.first);
                      SettingsStore.set('quality', s.first);
                    },
            ),
          ),
          const SizedBox(height: 10),
          HintText(
            model.isLocal
                ? t('{n} шагов модели. Лицо и фон остаются из вашего фото в полном разрешении, '
                    'одежда дорисовывается и повышается в чёткости.', {'n': quality})
                : t('Облачная модель: число шагов ограничено самим сервисом, бесплатно несколько примерок в день.'),
          ),
        ],
      ),
    );
  }

  Widget _extraParameters() {
    const sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];
    const fits = ['Slim', 'Regular', 'Oversize'];

    Widget section(String title, List<Widget> children) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(color: FitColors.soft, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: children),
          ],
        ),
      );
    }

    ChoiceChip chip(String value, String current, ValueChanged<String> onPick) {
      return ChoiceChip(
        label: Text(t(value)),
        selected: current == value,
        onSelected: busy ? null : (_) => setState(() => onPick(value)),
      );
    }

    return SectionCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: FitColors.tint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.tune, size: 18, color: FitColors.accentSoft),
          ),
          title: Text(
            t('Размер и посадка'),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
          ),
          subtitle: Text(
            '$size • $fit',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: FitColors.muted, fontSize: 12),
          ),
          children: [
            section(t('Размер'), [for (final s in sizes) chip(s, size, (v) => size = v)]),
            section(t('Посадка'), [for (final f in fits) chip(f, fit, (v) => fit = v)]),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: HintText(
                t('Размер и посадка меняют силуэт приблизительно — это визуальная подсказка, а не размерная '
                    'сетка бренда. Цвет выбирается после примерки, под результатом.'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _generateButton() {
    final ready = personPhoto != null && outfit.isNotEmpty;
    final label = !ready
        ? (personPhoto == null ? t('Выберите фото человека') : t('Добавьте вещь в образ'))
        : outfit.length == 1
        ? t('Примерить')
        : t('Примерить образ ({n} вещи)', {'n': outfit.length});
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: ready
            ? LinearGradient(
                colors: [FitColors.accent, Color.lerp(FitColors.accent, const Color(0xFFE56BD3), .45)!],
              )
            : null,
        color: ready ? null : FitColors.cardHigh,
      ),
      child: FilledButton(
        onPressed: ready ? _start : null,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          disabledForegroundColor: FitColors.faint,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.auto_awesome, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            if (ready) ...[
              const SizedBox(width: 8),
              Text(
                '≈ ${_formatSeconds(_etaSeconds)}',
                style: TextStyle(color: Colors.white.withValues(alpha: .8), fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progressBar() {
    final seconds = elapsed.inSeconds;
    final eta = _etaSeconds;
    final progress = (seconds / math.max(eta, 1)).clamp(0.02, 0.97).toDouble();
    final stepText = status == 'uploading'
        ? t('Отправляю фото на сервер...')
        : status == 'queued' && queueAhead > 0
        ? t('В очереди: перед вами {n}', {'n': queueAhead})
        : status == 'queued' || step == 0
        ? t('В очереди...')
        : totalSteps > 1
        ? t('Шаг {n} из {all}: {what}', {'n': step, 'all': totalSteps, 'what': t(stepLabel ?? '')})
        : t('Надеваю {what}...', {'what': t(stepLabel ?? 'вещь').toLowerCase()});
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                stepText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${_formatSeconds(seconds)} / ≈ ${_formatSeconds(eta)}',
              style: TextStyle(color: FitColors.muted, fontSize: 12.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: FitColors.cardHigh,
          ),
        ),
        const SizedBox(height: 6),
        HintText(t('{model} • можно переключать вкладки — результат не потеряется.', {'model': model.title})),
      ],
    );
  }

  Widget _resultSection() {
    final title = outfit.map((it) => t(it.label)).join(' + ');
    return SectionCard(
      highlight: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.auto_awesome,
            title: t('Результат'),
            trailing: IconButton(
              tooltip: t('Открыть на весь экран'),
              onPressed: () => openZoom(context, NetImage(shownUrl ?? resultUrl!, fit: BoxFit.contain), title: title),
              icon: Icon(Icons.zoom_out_map, color: FitColors.muted),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 480,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: FitColors.cardHigh,
              borderRadius: BorderRadius.circular(18),
            ),
            child: BeforeAfterView(
              before: PhotoImage(personPhoto!),
              after: NetImage(shownUrl ?? resultUrl!, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 6),
          Center(child: HintText(t('Потяните по фото влево-вправо, чтобы сравнить'))),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: saved ? null : _saveLook,
                  icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
                  label: Text(saved ? t('В луках') : t('Сохранить')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _start(newVariant: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(t('Другой вариант')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: busy ? null : _newOutfit,
            icon: const Icon(Icons.add),
            label: Text(t('Новый образ')),
          ),
        ],
      ),
    );
  }
}

class _GarmentTile extends StatelessWidget {
  const _GarmentTile({required this.item, required this.onTap});

  final OutfitItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget image = item.catalog != null
        ? NetImage(item.catalog!.imageUrl, fit: BoxFit.contain)
        : PhotoImage(item.photo!, fit: BoxFit.cover);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 108,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FitColors.accent.withValues(alpha: .6)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                color: Colors.black.withValues(alpha: .62),
                child: Text(
                  item.onModel == true
                      ? '${t(item.label)} • ${t('на человеке')}'
                      : t(item.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: Colors.black54,
                child: Icon(Icons.edit, size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 108,
        decoration: BoxDecoration(
          color: FitColors.cardHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FitColors.line2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 32, color: FitColors.accentSoft),
            SizedBox(height: 6),
            Text(t('Добавить\nвещь'), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _PersonSourceButton extends StatelessWidget {
  const _PersonSourceButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? FitColors.accent.withValues(alpha: enabled ? (FitColors.dark ? .28 : .14) : .08)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: filled ? Colors.transparent : FitColors.line2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: enabled ? FitColors.accentSoft : FitColors.line2),
              SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: enabled ? FitColors.text : FitColors.faint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
