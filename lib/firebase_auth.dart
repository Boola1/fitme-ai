import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'firebase_options.dart';
import 'i18n.dart';

/// Firebase Authentication over its REST API (no native plugin and no google-services.json).
/// Passwords go only to Google; FitMe's backend gets the short-lived ID token.
class FirebaseAuthApi {
  FirebaseAuthApi._();

  static String apiKey = kFirebaseApiKey;

  static bool get configured => apiKey.isNotEmpty;

  static Future<Map<String, dynamic>> _post(String url, Map<String, Object?> body) async {
    if (!configured) {
      throw FirebaseAuthError('NOT_CONFIGURED', t('Вход ещё не настроен: запустите SETUP_FIREBASE.bat и пересоберите приложение.'));
    }
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              // Letters from Firebase (confirmation, password reset) in the app's language.
              'X-Firebase-Locale': AppSettings.lang.code,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      final text = utf8.decode(response.bodyBytes);
      final data = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        final code = ((data['error'] as Map?)?['message'] ?? 'HTTP_${response.statusCode}').toString();
        throw FirebaseAuthError(code, messageFor(code));
      }
      return data;
    } on http.ClientException {
      throw FirebaseAuthError('NETWORK', t('Нет интернета — проверьте подключение.'));
    } on TimeoutException {
      throw FirebaseAuthError('NETWORK', t('Нет интернета — проверьте подключение.'));
    } finally {
      client.close();
    }
  }

  static String _identity(String method) =>
      'https://identitytoolkit.googleapis.com/v1/accounts:$method?key=$apiKey';

  /// Creates the account and sends the confirmation e-mail.
  static Future<FirebaseTokens> signUp(String email, String password) async {
    final data = await _post(_identity('signUp'), {
      'email': email.trim(),
      'password': password,
      'returnSecureToken': true,
    });
    final tokens = FirebaseTokens.fromSignIn(data);
    await sendVerificationEmail(tokens.idToken);
    return tokens;
  }

  static Future<FirebaseTokens> signIn(String email, String password) async {
    final data = await _post(_identity('signInWithPassword'), {
      'email': email.trim(),
      'password': password,
      'returnSecureToken': true,
    });
    return FirebaseTokens.fromSignIn(data);
  }

  static Future<void> sendVerificationEmail(String idToken) async {
    await _post(_identity('sendOobCode'), {'requestType': 'VERIFY_EMAIL', 'idToken': idToken});
  }

  static Future<void> sendPasswordReset(String email) async {
    await _post(_identity('sendOobCode'), {'requestType': 'PASSWORD_RESET', 'email': email.trim()});
  }

  /// Whether the e-mail link was opened (checked on Google's side).
  static Future<bool> isEmailVerified(String idToken) async {
    final data = await _post(_identity('lookup'), {'idToken': idToken});
    final users = data['users'] as List<dynamic>? ?? const [];
    return users.isNotEmpty && (users.first as Map)['emailVerified'] == true;
  }

  /// New ID token (they live one hour); also picks up a freshly confirmed e-mail.
  static Future<FirebaseTokens> refresh(String refreshToken) async {
    final data = await _post('https://securetoken.googleapis.com/v1/token?key=$apiKey', {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    });
    return FirebaseTokens(
      idToken: data['id_token'].toString(),
      refreshToken: data['refresh_token'].toString(),
      uid: data['user_id'].toString(),
      expiresAt: DateTime.now().add(Duration(seconds: int.tryParse('${data['expires_in']}') ?? 3600)),
    );
  }

  /// Requires a fresh sign-in (call [signIn] with the current password first).
  static Future<FirebaseTokens> changePassword(String idToken, String newPassword) async {
    final data = await _post(_identity('update'), {
      'idToken': idToken,
      'password': newPassword,
      'returnSecureToken': true,
    });
    return FirebaseTokens.fromSignIn(data);
  }

  /// Firebase error codes -> text for people.
  static String messageFor(String code) {
    final c = code.split(':').first.trim();
    return switch (c) {
      'EMAIL_EXISTS' => t('Этот адрес уже зарегистрирован — войдите или восстановите пароль'),
      'EMAIL_NOT_FOUND' || 'INVALID_PASSWORD' || 'INVALID_LOGIN_CREDENTIALS' => t('Неверная почта или пароль'),
      'USER_DISABLED' => t('Аккаунт заблокирован администратором'),
      'TOO_MANY_ATTEMPTS_TRY_LATER' => t('Слишком много попыток. Попробуйте позже.'),
      'WEAK_PASSWORD' => t('Пароль должен быть не короче 8 символов'),
      'INVALID_EMAIL' || 'MISSING_EMAIL' => t('Введите правильный адрес почты'),
      'OPERATION_NOT_ALLOWED' => t('Вход по почте выключен в Firebase (Authentication → Sign-in method).'),
      'TOKEN_EXPIRED' || 'INVALID_ID_TOKEN' || 'INVALID_REFRESH_TOKEN' || 'USER_NOT_FOUND' ||
      'CREDENTIAL_TOO_OLD_LOGIN_AGAIN' => t('Сессия закончилась — войдите снова'),
      _ => t('Ошибка входа: {code}', {'code': code}),
    };
  }
}

class FirebaseAuthError implements Exception {
  FirebaseAuthError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class FirebaseTokens {
  const FirebaseTokens({
    required this.idToken,
    required this.refreshToken,
    required this.uid,
    required this.expiresAt,
  });

  final String idToken;
  final String refreshToken;
  final String uid;
  final DateTime expiresAt;

  factory FirebaseTokens.fromSignIn(Map<String, dynamic> data) => FirebaseTokens(
    idToken: data['idToken'].toString(),
    refreshToken: data['refreshToken'].toString(),
    uid: (data['localId'] ?? '').toString(),
    expiresAt: DateTime.now().add(Duration(seconds: int.tryParse('${data['expiresIn']}') ?? 3600)),
  );
}
