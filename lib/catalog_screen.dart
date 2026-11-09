import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'common.dart';
import 'i18n.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.onTryOn});

  /// Adds the item to the outfit on the try-on screen.
  final ValueChanged<CatalogItem> onTryOn;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final ImagePicker picker = ImagePicker();
  bool loading = true;
  bool working = false;
  String? error;
  String filter = 'all';
  String query = '';
  List<CatalogItem> items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getCatalog();
      if (!mounted) return;
      setState(() {
        items = result;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _addItem() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: FitColors.card,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t('Добавить вещь'),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              SizedBox(height: 12),
              ListTile(
                leading: Icon(Icons.link),
                title: Text(t('По ссылке на товар')),
                subtitle: Text(t('FitMe сам найдёт фото товара')),
                onTap: () => Navigator.pop(sheetContext, 'url'),
              ),
              ListTile(
                leading: Icon(Icons.photo_library_outlined),
                title: Text(t('Из галереи')),
                subtitle: Text(t('Выбрать фото одежды')),
                onTap: () => Navigator.pop(sheetContext, 'photo'),
              ),
              ListTile(
                leading: Icon(Icons.photo_camera_outlined),
                title: Text(t('Сфотографировать')),
                subtitle: Text(t('Снять вещь камерой')),
                onTap: () => Navigator.pop(sheetContext, 'camera'),
              ),
            ],
          ),
        ),
      ),
    );

    if (mode == null || !mounted) return;
    if (mode == 'url') {
      await _addFromUrl();
    } else {
      await _addFromPhoto(
        mode == 'camera' ? ImageSource.camera : ImageSource.gallery,
      );
    }
  }

  Future<void> _addFromUrl() async {
    final urlCtrl = TextEditingController();
    var category = 'upper_body';
    var garmentType = 'Футболка';

    final urlData = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(t('Добавить по ссылке')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: t('Ссылка на товар'),
                    hintText: 'https://...',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                SizedBox(height: 12),
                CompactGarmentTypeField(
                  label: garmentType,
                  enabled: true,
                  onTap: () async {
                    final selected = await showGarmentTypePicker(
                      context,
                      selectedLabel: garmentType,
                    );
                    if (selected == null) return;
                    setLocal(() {
                      garmentType = selected.label;
                      category = selected.aiCategory;
                    });
                  },
                ),
                SizedBox(height: 10),
                Text(
                  t('Если магазин не отдаёт фото, добавьте его вручную из галереи.'),
                  style: TextStyle(color: FitColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('Отмена')),
            ),
            FilledButton(
              onPressed: () {
                if (urlCtrl.text.trim().isEmpty) return;
                Navigator.pop(context, {
                  'url': urlCtrl.text.trim(),
                  'category': category,
                });
              },
              child: Text(t('Найти фото')),
            ),
          ],
        ),
      ),
    );
    urlCtrl.dispose();
    if (urlData == null || !mounted) return;

    setState(() => working = true);
    try {
      final item = await FitMeApi.importCatalogItemFromUrl(
        sourceUrl: urlData['url']!,
        category: urlData['category']!,
      );
      await _load();
      if (!mounted) return;
      showMessage(context, t('Добавлено: {name}', {'name': item.displayName}));
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Не удалось взять фото по ссылке: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _addFromPhoto(ImageSource source) async {
    final photo = await picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1800,
    );
    if (photo == null || !mounted) return;

    final nameCtrl = TextEditingController();
    final sourceNameCtrl = TextEditingController();
    final sourceUrlCtrl = TextEditingController();
    var category = 'upper_body';
    var garmentType = 'Футболка';

    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(t('Добавить вещь')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: t('Название'),
                    hintText: t('Синие джинсы'),
                  ),
                ),
                SizedBox(height: 12),
                CompactGarmentTypeField(
                  label: garmentType,
                  enabled: true,
                  onTap: () async {
                    final selected = await showGarmentTypePicker(
                      context,
                      selectedLabel: garmentType,
                    );
                    if (selected == null) return;
                    setLocal(() {
                      garmentType = selected.label;
                      category = selected.aiCategory;
                    });
                  },
                ),
                SizedBox(height: 12),
                TextField(
                  controller: sourceNameCtrl,
                  decoration: InputDecoration(
                    labelText: t('Магазин (необязательно)'),
                    hintText: 'Zara / Wildberries / Kaspi',
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: sourceUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: t('Ссылка (необязательно)'),
                    hintText: 'https://...',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('Отмена')),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim().isEmpty
                    ? garmentType
                    : nameCtrl.text.trim();
                Navigator.pop(context, {
                  'name': name,
                  'category': category,
                  'description': name,
                  'source_name': sourceNameCtrl.text.trim(),
                  'source_url': sourceUrlCtrl.text.trim(),
                });
              },
              child: Text(t('Добавить')),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    sourceNameCtrl.dispose();
    sourceUrlCtrl.dispose();
    if (data == null || !mounted) return;

    setState(() => working = true);
    try {
      await FitMeApi.uploadCatalogItem(
        garmentPhoto: photo,
        name: data['name']!,
        category: data['category']!,
        description: data['description']!,
        sourceName: data['source_name'] ?? '',
        sourceUrl: data['source_url'] ?? '',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Ошибка каталога: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _delete(CatalogItem item) async {
    final ok = await confirmAction(
      context,
      title: t('Удалить «{name}»?', {'name': item.displayName}),
      message: t('Вещь пропадёт из каталога.'),
    );
    if (!ok || !mounted) return;
    try {
      await FitMeApi.deleteCatalogItem(item.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Не удалось удалить: {e}', {'e': e}));
    }
  }

  List<CatalogItem> get _visible {
    final q = query.trim().toLowerCase();
    return [
      for (final item in items)
        if ((filter == 'all' || item.category == filter) &&
            (q.isEmpty || item.displayName.toLowerCase().contains(q)))
          item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          ScreenTitle(
            t('Каталог'),
            subtitle: t('Ваши вещи — добавляйте в образ одним нажатием'),
            trailing: working
                ? const SizedBox(
                    width: 40,
                    height: 40,
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filled(
                    tooltip: t('Добавить вещь'),
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                  ),
          ),
          if (!loading && error == null && items.isNotEmpty) ...[
            TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: t('Поиск по названию'),
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (value, label) in const [
                    ('all', 'Все'),
                    ('upper_body', 'Верх'),
                    ('lower_body', 'Низ'),
                    ('dresses', 'Платья'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: Text(
                          '${t(label)} ${value == 'all' ? items.length : items.where((i) => i.category == value).length}',
                        ),
                        selected: filter == value,
                        onSelected: (_) => setState(() => filter = value),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            SectionCard(
              child: Column(
                children: [
                  Text(error!, style: TextStyle(color: FitColors.danger)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => loading = true);
                      _load();
                    },
                    icon: const Icon(Icons.refresh),
                    label: Text(t('Повторить')),
                  ),
                ],
              ),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(color: FitColors.tint, shape: BoxShape.circle),
                    child: Icon(Icons.checkroom, size: 54, color: FitColors.accentSoft),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    t('Каталог пуст'),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('Нажмите + и добавьте фото одежды.'),
                    style: TextStyle(color: FitColors.muted),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: Text(t('Добавить вещь')),
                  ),
                ],
              ),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(
                child: Text(t('Ничего не найдено'), style: TextStyle(color: FitColors.muted)),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visible.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.6,
              ),
              itemBuilder: (context, index) => _CatalogTile(
                item: visible[index],
                onTryOn: () => widget.onTryOn(visible[index]),
                onDelete: () => _delete(visible[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.item,
    required this.onTryOn,
    required this.onDelete,
  });

  final CatalogItem item;
  final VoidCallback onTryOn;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: FitColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: FitColors.line),
        boxShadow: [
          if (!FitColors.dark)
            BoxShadow(
              color: const Color(0xFF2A2350).withValues(alpha: .07),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: () => openZoom(
                    context,
                    NetImage(item.imageUrl, fit: BoxFit.contain),
                    title: item.displayName,
                  ),
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(6),
                    child: NetImage(item.imageUrl, fit: BoxFit.contain),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      categoryRu(item.category),
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: .45)),
                    tooltip: t('Удалить'),
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, height: 1.2),
                  ),
                ),
                if (item.sourceUrl.isNotEmpty)
                  InkWell(
                    onTap: () => openProductSource(context, item.sourceUrl),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.open_in_new, size: 16, color: FitColors.accentSoft),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: onTryOn,
              icon: const Icon(Icons.add, size: 18),
              label: Text(t('В образ')),
            ),
          ),
        ],
      ),
    );
  }
}
