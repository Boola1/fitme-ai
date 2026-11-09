import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'firebase_auth.dart';
import 'i18n.dart';
import 'main.dart' show ServerStatusCard;

enum _Mode { login, register, verify, forgot }

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Client-side check that mirrors the server rules (the server checks again).
String? passwordProblem(String password) {
  if (password.length < 8) return t('Пароль должен быть не короче 8 символов');
  if (!RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(password) || !RegExp(r'\d').hasMatch(password)) {
    return t('В пароле нужны и буквы, и цифры');
  }
  return null;
}

/// Sign in, sign up (Firebase sends a confirmation link) and password reset in one screen.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(text: SettingsStore.get<String>('last_email') ?? '');
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _name = TextEditingController();

  _Mode mode = _Mode.login;
  bool busy = false;
  bool showPassword = false;
  String? error;
  String? info;
  int resendIn = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _password, _password2, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(_Mode next) {
    setState(() {
      mode = next;
      error = null;
      info = null;
    });
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => resendIn = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || resendIn <= 1) timer.cancel();
      if (mounted) setState(() => resendIn--);
    });
  }

  String get _sentNote => t(
    'Мы отправили письмо со ссылкой на {email}. Откройте его, нажмите ссылку и вернитесь сюда. '
    'Если письма нет — проверьте «Спам».',
    {'email': _email.text.trim()},
  );

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    if (!(_form.currentState?.validate() ?? true)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on FitMeApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'not_verified') {
        _go(_Mode.verify);
        setState(() => info = t('Почта ещё не подтверждена. ') + _sentNote);
      } else {
        setState(() => error = e.message);
      }
    } on FirebaseAuthError catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _submit() => _run(() async {
    final email = _email.text.trim();
    SettingsStore.set('last_email', email);
    switch (mode) {
      case _Mode.login:
        await FitMeApi.login(email: email, password: _password.text);
      case _Mode.register:
        await FitMeApi.register(email: email, password: _password.text, name: _name.text);
        if (!mounted) return;
        _go(_Mode.verify);
        _startCooldown();
        setState(() => info = _sentNote);
      case _Mode.verify:
        final ok = await FitMeApi.confirmVerified();
        if (!ok && mounted) setState(() => error = t('Ссылка из письма ещё не открыта. Откройте письмо и нажмите на ссылку.'));
      case _Mode.forgot:
        await FitMeApi.forgotPassword(email);
        if (!mounted) return;
        _go(_Mode.login);
        setState(() => info = t('Ссылка для нового пароля отправлена на {email}. Задайте пароль по ссылке и войдите.', {'email': email}));
    }
  });

  Future<void> _resend() => _run(() async {
    await FitMeApi.resendVerification();
    if (!mounted) return;
    _startCooldown();
    setState(() => info = _sentNote);
  });

  String get _title => switch (mode) {
    _Mode.login => t('Вход'),
    _Mode.register => t('Регистрация'),
    _Mode.verify => t('Подтверждение почты'),
    _Mode.forgot => t('Восстановление пароля'),
  };

  String get _button => switch (mode) {
    _Mode.login => t('Войти'),
    _Mode.register => t('Создать аккаунт'),
    _Mode.verify => t('Я подтвердил почту'),
    _Mode.forgot => t('Отправить ссылку'),
  };

  @override
  Widget build(BuildContext context) {
    final codeMode = mode == _Mode.verify;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [FitColors.tint, FitColors.background],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
                shrinkWrap: true,
                children: [
                  const _Logo(),
                  const SizedBox(height: 26),
                  SectionCard(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              if (mode != _Mode.login && mode != _Mode.register)
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: busy ? null : () => _go(_Mode.login),
                                  icon: const Icon(Icons.arrow_back),
                                ),
                              Expanded(
                                child: Text(_title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                              ),
                            ],
                          ),
                          if (mode == _Mode.login || mode == _Mode.register) ...[
                            const SizedBox(height: 12),
                            SegmentedButton<_Mode>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: _Mode.login, label: Text(t('Вход'))),
                                ButtonSegment(value: _Mode.register, label: Text(t('Регистрация'))),
                              ],
                              selected: {mode},
                              onSelectionChanged: busy ? null : (s) => _go(s.first),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (!FirebaseAuthApi.configured) ...[
                            _Note(
                              text: t('Вход ещё не настроен: запустите SETUP_FIREBASE.bat и пересоберите приложение.'),
                              color: FitColors.warn,
                              icon: Icons.build_circle_outlined,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (info != null) ...[
                            _Note(text: info!, color: FitColors.accentSoft, icon: Icons.mark_email_read_outlined),
                            const SizedBox(height: 12),
                          ],
                          if (mode == _Mode.register) ...[
                            TextFormField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: t('Имя (необязательно)'),
                                prefixIcon: const Icon(Icons.person_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _email,
                            enabled: !codeMode,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: t('Почта'),
                              prefixIcon: const Icon(Icons.alternate_email),
                            ),
                            validator: (v) =>
                                _emailRe.hasMatch((v ?? '').trim()) ? null : t('Введите правильный адрес почты'),
                          ),
                          if (mode == _Mode.login || mode == _Mode.register) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _password,
                              obscureText: !showPassword,
                              autofillHints: [
                                mode == _Mode.login ? AutofillHints.password : AutofillHints.newPassword,
                              ],
                              textInputAction: mode == _Mode.login ? TextInputAction.done : TextInputAction.next,
                              onFieldSubmitted: mode == _Mode.login ? (_) => _submit() : null,
                              decoration: InputDecoration(
                                labelText: t('Пароль'),
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: showPassword ? t('Скрыть пароль') : t('Показать пароль'),
                                  onPressed: () => setState(() => showPassword = !showPassword),
                                  icon: Icon(showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                                ),
                              ),
                              validator: (v) => mode == _Mode.login
                                  ? ((v ?? '').isEmpty ? t('Введите пароль') : null)
                                  : passwordProblem(v ?? ''),
                            ),
                          ],
                          if (mode == _Mode.register) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _password2,
                              obscureText: !showPassword,
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                labelText: t('Повторите пароль'),
                                prefixIcon: const Icon(Icons.lock_outline),
                              ),
                              validator: (v) => v == _password.text ? null : t('Пароли не совпадают'),
                            ),
                            const SizedBox(height: 6),
                            HintText(t('Не короче 8 символов, буквы и цифры. Пароль хранит Google Firebase — FitMe его не видит.')),
                          ],
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            _Note(text: error!, color: FitColors.danger, icon: Icons.error_outline),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: busy ? null : _submit,
                            child: busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_button, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                          ),
                          if (mode == _Mode.login)
                            TextButton(
                              onPressed: busy ? null : () => _go(_Mode.forgot),
                              child: Text(t('Забыли пароль?')),
                            ),
                          if (codeMode)
                            TextButton(
                              onPressed: busy || resendIn > 0 ? null : _resend,
                              child: Text(
                                resendIn > 0
                                    ? t('Отправить письмо ещё раз через {s} с', {'s': resendIn})
                                    : t('Отправить письмо ещё раз'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const ServerStatusCard(),
                  const AppDownloadCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [FitColors.accent, Color.lerp(FitColors.accent, const Color(0xFFE56BD3), .5)!],
            ),
            boxShadow: [
              BoxShadow(color: FitColors.accent.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 10)),
            ],
          ),
          child: const Icon(Icons.checkroom_rounded, color: Colors.white, size: 38),
        ),
        const SizedBox(height: 14),
        const Text('FitMe AI', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -.4)),
        const SizedBox(height: 4),
        Text(t('Виртуальная примерочная'), style: TextStyle(color: FitColors.muted)),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: FitColors.text, fontSize: 13, height: 1.35))),
        ],
      ),
    );
  }
}
