import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'i18n.dart';

class LooksScreen extends StatefulWidget {
  const LooksScreen({super.key});

  @override
  State<LooksScreen> createState() => _LooksScreenState();
}

class _LooksScreenState extends State<LooksScreen> {
  bool loading = true;
  List<Map<String, dynamic>> looks = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getLooks();
      if (!mounted) return;
      setState(() {
        looks = result;
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

  Future<void> _delete(Map<String, dynamic> look) async {
    final id = look['look_id']?.toString() ?? '';
    if (id.isEmpty) return;
    final ok = await confirmAction(
      context,
      title: t('Удалить образ?'),
      message: look['title']?.toString(),
    );
    if (!ok || !mounted) return;
    try {
      await FitMeApi.deleteLook(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, t('Не удалось удалить: {e}', {'e': e}));
    }
  }

  String _date(String? value) {
    final dt = value == null ? null : DateTime.tryParse(value)?.toLocal();
    if (dt == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)} • ${two(dt.hour)}:${two(dt.minute)}';
  }

  void _open(Map<String, dynamic> look) {
    final url = look['result_url']?.toString();
    if (url == null || url.isEmpty) return;
    final items = (look['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final sourceUrl = look['source_url']?.toString() ?? '';
    final sourceName = look['source_name']?.toString() ?? '';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(look['title']?.toString() ?? t('Образ'))),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: Colors.black,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(child: NetImage(url, fit: BoxFit.contain)),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(18, 14, 18, 18),
                  color: FitColors.card,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in items)
                            Chip(label: Text(item['label']?.toString() ?? '')),
                          if ((look['engine']?.toString() ?? '').isNotEmpty)
                            Chip(
                              avatar: Icon(Icons.auto_awesome, size: 16),
                              label: Text(
                                look['num_timesteps'] == null
                                    ? look['engine'].toString()
                                    : '${look['engine']} • ${t('{n} шагов', {'n': look['num_timesteps']})}',
                              ),
                            ),
                          for (final key in ['size', 'fit', 'color'])
                            if ((look[key]?.toString() ?? '').isNotEmpty)
                              Chip(
                                label: Text(
                                  key == 'size'
                                      ? t('Размер {s}', {'s': look[key]})
                                      : t(look[key].toString()),
                                ),
                              ),
                        ],
                      ),
                      if (sourceUrl.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => openProductSource(context, sourceUrl),
                          icon: Icon(Icons.open_in_new),
                          label: Text(sourceName.isEmpty ? t('Открыть товар') : sourceName),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          ScreenTitle(
            t('Мои луки'),
            subtitle: t('Сохранённые результаты примерок'),
            trailing: IconButton(
              onPressed: () {
                setState(() => loading = true);
                _load();
              },
              icon: Icon(Icons.refresh),
            ),
          ),
          if (loading)
            Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            SectionCard(
              child: Column(
                children: [
                  Text(error!, style: TextStyle(color: FitColors.danger)),
                  SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => loading = true);
                      _load();
                    },
                    icon: Icon(Icons.refresh),
                    label: Text(t('Повторить')),
                  ),
                ],
              ),
            )
          else if (looks.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 110),
              child: Column(
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(color: FitColors.tint, shape: BoxShape.circle),
                    child: Icon(Icons.favorite_border, size: 52, color: FitColors.accentSoft),
                  ),
                  SizedBox(height: 14),
                  Text(
                    t('Пока нет сохранённых луков'),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 6),
                  Text(
                    t('Сделайте примерку и нажмите «Сохранить»'),
                    style: TextStyle(color: FitColors.muted),
                  ),
                ],
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: looks.length,
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.58,
              ),
              itemBuilder: (context, index) {
                final look = looks[index];
                final url = look['result_url']?.toString();
                final itemsCount = (look['total_steps'] as num?)?.toInt() ?? 1;
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
                        child: GestureDetector(
                          onTap: () => _open(look),
                          child: Container(
                            color: Colors.black,
                            child: url == null
                                ? SizedBox()
                                : NetImage(url, fit: BoxFit.cover, alignment: Alignment.topCenter),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(12, 10, 4, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    look['title']?.toString() ?? t('Образ'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '${itemsCount > 1 ? '${t('{n} вещи', {'n': itemsCount})} • ' : ''}'
                                    '${_date(look['created_at']?.toString())}',
                                    style: TextStyle(color: FitColors.muted, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _delete(look),
                              icon: Icon(Icons.delete_outline, size: 20),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
