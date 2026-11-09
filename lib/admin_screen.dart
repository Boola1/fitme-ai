import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'i18n.dart';

String _num(Object? v, [int digits = 0]) {
  if (v == null) return '—';
  final n = (v as num).toDouble();
  return digits == 0 ? n.round().toString() : n.toStringAsFixed(digits);
}

String _ago(Object? ts) {
  if (ts is! num) return '—';
  final s = DateTime.now().millisecondsSinceEpoch / 1000 - ts;
  if (s < 90) return t('сейчас');
  if (s < 3600) return t('{n} мин назад', {'n': (s / 60).round()});
  if (s < 86400) return t('{n} ч назад', {'n': (s / 3600).round()});
  return t('{n} дн назад', {'n': (s / 86400).round()});
}

String _date(Object? ts) {
  if (ts is! num) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Admin panel for admins and the owner: load, users, try-ons, rules.
/// The full table with CSV export is the web page `http://<laptop>:8000/admin`.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  @override
  Widget build(BuildContext context) {
    final owner = Session.user.value?.isOwner ?? false;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('Админ-панель')),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: t('Обзор')),
              Tab(text: t('Пользователи')),
              Tab(text: t('Примерки')),
              Tab(text: owner ? t('Настройки') : t('Правила')),
            ],
          ),
        ),
        body: const PageWidth(
          maxWidth: 1000,
          child: TabBarView(
            children: [_OverviewTab(), _UsersTab(), _JobsTab(), _SettingsTab()],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ overview
class _OverviewTab extends StatefulWidget {
  const _OverviewTab();

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? data;
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await FitMeApi.adminOverview();
      if (!mounted) return;
      setState(() {
        data = d;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final d = data;
    if (d == null) {
      return Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(padding: const EdgeInsets.all(24), child: Text(error!, style: TextStyle(color: FitColors.danger))),
      );
    }
    final s = (d['system'] as Map?) ?? {};
    final u = d['users'] as Map;
    final tr = d['tryons'] as Map;
    final cap = d['capacity'] as Map;
    final storage = d['storage_mb'] as Map;
    final traffic = d['traffic_24h'] as Map;
    final perHour = (tr['per_hour_24h'] as List).map((e) => (e as num).toInt()).toList();
    final gpu = s['gpu_util_pct'];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _Heading(t('Сейчас')),
          _Tiles([
            (t('Онлайн'), _num(u['online_5m']), t('за 5 минут • пик {n}', {'n': _num(u['peak_online_7d'])})),
            (t('Очередь'), _num(s['queued_jobs']), t('в работе: {n}', {'n': _num(s['active_jobs'])})),
            (t('Видеокарта'), gpu == null ? '—' : '${_num(gpu)}%',
                s['vram_used_mb'] == null ? t('нет данных') : t('видеопамять {a} / {b} ГБ', {
                  'a': _num((s['vram_used_mb'] as num) / 1024, 1),
                  'b': _num((s['vram_total_mb'] as num) / 1024, 1),
                })),
            (t('Процессор'), s['cpu_pct'] == null ? '—' : '${_num(s['cpu_pct'])}%',
                t('ОЗУ {a} / {b} ГБ', {
                  'a': _num(((s['ram_used_mb'] as num?) ?? 0) / 1024, 1),
                  'b': _num(((s['ram_total_mb'] as num?) ?? 0) / 1024, 1),
                })),
          ]),
          _Heading(t('За сутки')),
          _Tiles([
            (t('Примерок'), _num(tr['day']), t('ошибок: {n}', {'n': _num(tr['day_failed'])})),
            (t('GPU работал'), t('{n} мин', {'n': _num(tr['day_gpu_minutes'], 1)}),
                t('ожидание в очереди {n} с', {'n': _num(tr['day_avg_wait_s'])})),
            (t('Новых аккаунтов'), _num(u['new_24h']), t('всего: {n}', {'n': _num(u['total'])})),
            (t('Трафик'), t('{n} МБ', {'n': _num((traffic['in_mb'] as num) + (traffic['out_mb'] as num), 1)}),
                t('{n} запросов', {'n': _num(traffic['requests'])})),
          ]),
          const SizedBox(height: 4),
          SectionCard(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Примерки по часам'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                SizedBox(height: 110, child: _HourBars(values: perHour)),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t('24 ч назад'), style: TextStyle(color: FitColors.muted, fontSize: 11)),
                    Text(t('сейчас'), style: TextStyle(color: FitColors.muted, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          _Heading(t('Сколько людей выдержит сервер')),
          SectionCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Tiles([
                  (t('Одна примерка'), t('{n} с', {'n': _num(cap['avg_job_s'])}),
                      (cap['measured_jobs'] as num) > 0 ? t('измерено') : t('оценка')),
                  (t('В час максимум'), _num(cap['per_hour']), t('{n} в сутки', {'n': _num(cap['per_day'])})),
                ], inCard: true),
                const SizedBox(height: 8),
                for (final row in (cap['table'] as List).cast<Map>())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(width: 92, child: Text(t('{n} чел.', {'n': row['users']}))),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: math.min(1, (row['load_pct'] as num) / 100),
                              minHeight: 8,
                              backgroundColor: FitColors.cardHigh,
                              color: row['overloaded'] == true ? FitColors.danger : FitColors.accent,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 104,
                          child: Text(
                            row['overloaded'] == true
                                ? t('перегрузка')
                                : (row['wait_s'] as num) < 1
                                ? t('без очереди')
                                : t('ждать ≈{n} с', {'n': row['wait_s']}),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: row['overloaded'] == true ? FitColors.danger : FitColors.soft,
                              fontWeight: row['overloaded'] == true ? FontWeight.w800 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                HintText(t('Одна видеокарта делает одну картинку за раз. Если каждый активный человек запускает '
                    'примерку раз в {m} мин, без заметного ожидания (до 1 мин) сервер выдержит {n} чел. одновременно.', {
                  'm': _num((cap['think_s'] as num) / 60, 1),
                  'n': cap['users_wait_60s'],
                })),
              ],
            ),
          ),
          _Heading(t('Хранилище')),
          _Tiles([
            (t('Всего'), t('{n} МБ', {'n': _num(storage['total'], 1)}),
                t('≈{n} МБ на пользователя', {'n': _num(d['storage_per_user_mb'], 1)})),
            (t('Свободно на диске'), s['disk_free_gb'] == null ? '—' : t('{n} ГБ', {'n': _num(s['disk_free_gb'])}), ''),
          ]),
          const SizedBox(height: 10),
          HintText(t('Полная таблица пользователей и выгрузка в CSV — на ноутбуке: ADMIN_PANEL.bat (откроет браузер).')),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 16, 2, 10),
    child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
  );
}

class _Tiles extends StatelessWidget {
  const _Tiles(this.items, {this.inCard = false});

  final List<(String, String, String)> items;
  final bool inCard;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = (box.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (label, value, sub) in items)
              Container(
                width: width,
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                decoration: BoxDecoration(
                  color: inCard ? FitColors.cardHigh : FitColors.card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: FitColors.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(color: FitColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                    ),
                    Text(
                      sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: FitColors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _HourBars extends StatelessWidget {
  const _HourBars({required this.values});

  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final max = math.max(1, values.fold<int>(0, math.max));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final v in values)
          Expanded(
            child: Tooltip(
              message: '$v',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  height: v == 0 ? 2 : 4 + 100 * v / max,
                  decoration: BoxDecoration(
                    color: v == 0 ? FitColors.line2 : FitColors.accent,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ users
class _UsersTab extends StatefulWidget {
  const _UsersTab();

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? users;
  String query = '';
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await FitMeApi.adminUsers();
      if (!mounted) return;
      setState(() {
        users = list;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _act(Future<void> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      showMessage(context, done);
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Future<void> _open(Map<String, dynamic> u) async {
    final me = Session.user.value!;
    final id = u['id'].toString();
    final role = u['role'].toString();
    final editable = role != 'owner' && id != me.id;
    final canBlock = editable && (me.isOwner || role == 'user');
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          children: [
            Text(u['email'].toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if ((u['name'] ?? '').toString().isNotEmpty) Text(u['name'].toString(), style: TextStyle(color: FitColors.muted)),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [_RoleChip(role), _StatusChip(u)]),
            const SizedBox(height: 14),
            for (final (label, value) in [
              (t('Регистрация'), _date(u['created_at'])),
              (t('Был в сети'), _ago(u['last_seen_at'])),
              (t('Примерок'), '${_num(u['tryons'])} (${t('за сутки')}: ${_num(u['tryons_24h'])})'),
              (t('Ошибок примерки'), _num(u['tryons_failed'])),
              (t('Время GPU'), t('{n} мин', {'n': _num(u['gpu_minutes'], 1)})),
              (t('Перекрасок'), _num(u['recolors'])),
              (t('Луков / вещей'), '${_num(u['looks'])} / ${_num(u['catalog_items'])}'),
              (t('Хранилище'), t('{n} МБ', {'n': _num(u['storage_mb'], 1)})),
              (t('Запросов / трафик'), '${_num(u['requests'])} / ${t('{n} МБ', {'n': _num(u['traffic_mb'], 1)})}'),
              (t('IP'), (u['last_ip'] ?? '').toString()),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: TextStyle(color: FitColors.muted))),
                    Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (canBlock)
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(sheet, 'block'),
                icon: Icon(u['blocked'] == true ? Icons.lock_open : Icons.block),
                label: Text(u['blocked'] == true ? t('Разблокировать') : t('Заблокировать')),
              ),
            if (editable && me.isOwner) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(sheet, 'role'),
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: Text(role == 'admin' ? t('Сделать клиентом') : t('Сделать администратором')),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pop(sheet, 'delete'),
                style: TextButton.styleFrom(foregroundColor: FitColors.danger),
                icon: const Icon(Icons.delete_outline),
                label: Text(t('Удалить аккаунт')),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'block':
        final block = u['blocked'] != true;
        await _act(() => FitMeApi.adminSetBlocked(id, block), block ? t('Заблокирован') : t('Разблокирован'));
      case 'role':
        await _act(() => FitMeApi.adminSetRole(id, role == 'admin' ? 'user' : 'admin'), t('Роль изменена'));
      case 'delete':
        final ok = await confirmAction(
          context,
          title: t('Удалить {email}?', {'email': u['email']}),
          message: t('Вместе с аккаунтом удалятся его фото, примерки и луки. Это нельзя отменить.'),
        );
        if (ok) await _act(() => FitMeApi.adminDeleteUser(id), t('Аккаунт удалён'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = users;
    if (list == null) {
      return Center(
        child: error == null ? const CircularProgressIndicator() : Text(error!, style: TextStyle(color: FitColors.danger)),
      );
    }
    final q = query.toLowerCase();
    final shown = list
        .where((u) => q.isEmpty || '${u['email']} ${u['name']}'.toLowerCase().contains(q))
        .toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: t('Поиск по почте или имени'),
            ),
          ),
          const SizedBox(height: 6),
          Text(t('{n} из {all}', {'n': shown.length, 'all': list.length}), style: TextStyle(color: FitColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          for (final u in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: FitColors.card,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _open(u),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 19,
                          backgroundColor: FitColors.tint,
                          child: Text(
                            u['email'].toString().substring(0, 1).toUpperCase(),
                            style: TextStyle(color: FitColors.accentSoft, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                u['email'].toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _RoleChip(u['role'].toString()),
                                  if (u['blocked'] == true || u['verified'] != true) _StatusChip(u),
                                  Text(
                                    t('{n} примерок • {m} мин GPU', {
                                      'n': _num(u['tryons']),
                                      'm': _num(u['gpu_minutes'], 1),
                                    }),
                                    style: TextStyle(color: FitColors.muted, fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Text(_ago(u['last_seen_at']), style: TextStyle(color: FitColors.faint, fontSize: 11.5)),
                        Icon(Icons.chevron_right, color: FitColors.faint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip(this.role);

  final String role;

  @override
  Widget build(BuildContext context) {
    final color = role == 'owner' ? FitColors.accentSoft : role == 'admin' ? const Color(0xFF3987E5) : FitColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)),
      child: Text(t(roleLabel(role)), style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.user);

  final Map<String, dynamic> user;

  @override
  Widget build(BuildContext context) {
    final (text, color) = user['blocked'] == true
        ? (t('заблокирован'), FitColors.danger)
        : user['verified'] != true
        ? (t('не подтвердил почту'), FitColors.warn)
        : (t('активен'), FitColors.ok);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );
  }
}

// ------------------------------------------------------------------ try-ons
class _JobsTab extends StatefulWidget {
  const _JobsTab();

  @override
  State<_JobsTab> createState() => _JobsTabState();
}

class _JobsTabState extends State<_JobsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? jobs;
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await FitMeApi.adminJobs();
      if (!mounted) return;
      setState(() {
        jobs = list;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = jobs;
    if (list == null) {
      return Center(
        child: error == null ? const CircularProgressIndicator() : Text(error!, style: TextStyle(color: FitColors.danger)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: list.isEmpty
          ? ListView(children: [
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(child: Text(t('Примерок ещё не было'), style: TextStyle(color: FitColors.muted))),
              ),
            ])
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              itemCount: list.length,
              separatorBuilder: (_, _) => Divider(color: FitColors.line, height: 1),
              itemBuilder: (context, i) {
                final j = list[i];
                final ok = j['status'] == 'completed';
                final failed = j['status'] == 'failed';
                final wait = j['started_at'] is num ? (j['started_at'] as num) - (j['created_at'] as num) : null;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    ok ? Icons.check_circle : failed ? Icons.error : Icons.hourglass_top,
                    color: ok ? FitColors.ok : failed ? FitColors.danger : FitColors.warn,
                  ),
                  title: Text((j['email'] ?? '—').toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      _date(j['created_at']),
                      '${j['model']} • ${t('{n} вещ.', {'n': j['items']})}',
                      t('GPU {n} с', {'n': _num(j['gpu_seconds'])}),
                      if (wait != null) t('очередь {n} с', {'n': _num(wait)}),
                      if (failed && j['error'] != null) j['error'].toString(),
                    ].join(' • '),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: failed ? FitColors.danger : FitColors.muted),
                  ),
                );
              },
            ),
    );
  }
}

// ------------------------------------------------------------------ settings
class _SettingsTab extends StatefulWidget {
  const _SettingsTab();

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  Map<String, dynamic>? data;
  final _limit = TextEditingController();
  bool registrationOpen = true;
  String? error;

  bool get owner => Session.user.value?.isOwner ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await FitMeApi.adminSettings();
      if (!mounted) return;
      final settings = d['settings'] as Map;
      setState(() {
        data = d;
        registrationOpen = settings['registration_open'] == true;
        _limit.text = '${settings['daily_tryon_limit'] ?? 0}';
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _save() async {
    try {
      await FitMeApi.adminSaveSettings(
        registrationOpen: registrationOpen,
        dailyLimit: int.tryParse(_limit.text.trim()) ?? 0,
      );
      if (mounted) showMessage(context, t('Сохранено'));
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) {
      return Center(
        child: error == null ? const CircularProgressIndicator() : Text(error!, style: TextStyle(color: FitColors.danger)),
      );
    }
    final firebase = (d['firebase'] as Map?) ?? const {};
    final fbOk = firebase['configured'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          SectionCard(
            child: Material(
              type: MaterialType.transparency,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(icon: Icons.rule, title: t('Правила')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: registrationOpen,
                  onChanged: owner ? (v) => setState(() => registrationOpen = v) : null,
                  title: Text(t('Регистрация открыта')),
                  subtitle: Text(t('Если выключить, новые люди не смогут создать аккаунт')),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _limit,
                  enabled: owner,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('Лимит примерок клиента в сутки'),
                    helperText: t('0 — без лимита. Админов и создателя не касается.'),
                  ),
                ),
                const SizedBox(height: 12),
                if (owner)
                  FilledButton(onPressed: _save, child: Text(t('Сохранить')))
                else
                  HintText(t('Менять правила может только создатель.')),
              ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            child: Material(
              type: MaterialType.transparency,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(icon: Icons.cloud_done_outlined, title: t('Firebase')),
                const SizedBox(height: 8),
                Text(
                  fbOk
                      ? t('Подключён: проект {p}. Аккаунты, письма подтверждения и сброса пароля — через Firebase.',
                          {'p': firebase['project_id'] ?? ''})
                      : t('Не подключён. Запустите SETUP_FIREBASE.bat на ноутбуке.'),
                  style: TextStyle(color: fbOk ? FitColors.ok : FitColors.warn),
                ),
                const SizedBox(height: 6),
                HintText(t('Данные можно смотреть и править в Firebase Console: Firestore → users, tryons, config.')),
              ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
