import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../api/http_api.dart';
import '../config/app_config.dart';
import '../models/models.dart';

class DriverNotRegisteredException implements Exception {
  const DriverNotRegisteredException();
}

class DriverPendingException implements Exception {
  const DriverPendingException(this.message);
  final String message;
}

class AuthService extends ChangeNotifier {
  AuthService(this._http, {FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'platform_access_token';
  static const _sessionKey = 'driver_session';

  final HttpApi _http;
  final FlutterSecureStorage _storage;
  DriverSession? _session;
  String? _platformToken;
  bool _busy = false;
  bool _googleInitialized = false;

  DriverSession? get session => _session;
  bool get isSignedIn => _session != null;
  bool get busy => _busy;

  Future<void> initialize() async {
    _platformToken = await _storage.read(key: _tokenKey);
    final sessionJson = await _storage.read(key: _sessionKey);
    if (sessionJson != null) {
      try {
        _session = DriverSession.fromJson(jsonDecode(sessionJson) as Map<String, dynamic>);
      } catch (_) {
        await _storage.delete(key: _sessionKey);
      }
    }
    await _initGoogle();
    notifyListeners();
  }

  Future<void> _initGoogle() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize(
      clientId: Platform.isIOS && AppConfig.googleIosClientId.isNotEmpty ? AppConfig.googleIosClientId : null,
      serverClientId: AppConfig.googleServerClientId.isNotEmpty ? AppConfig.googleServerClientId : null,
    );
    _googleInitialized = true;
  }

  Future<void> signInGoogle() async {
    await _run(() async {
      await _initGoogle();
      final googleUser = await GoogleSignIn.instance.authenticate();
      final auth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(idToken: auth.idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
      await _exchangeFirebaseToken();
    });
  }

  Future<void> signInFacebook() async {
    await _run(() async {
      // iOS-on a Limited Login a tracking engedélytől független és nonce-ot igényel.
      // Androidon a klasszikus Facebook access tokennel használjuk a Firebase providert.
      final rawNonce = _randomNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
      final result = await FacebookAuth.instance.login(
        permissions: const ['email', 'public_profile'],
        loginTracking: Platform.isIOS ? LoginTracking.limited : LoginTracking.enabled,
        nonce: Platform.isIOS ? hashedNonce : null,
      );
      final token = result.accessToken;
      if (result.status != LoginStatus.success || token == null) {
        throw StateError(result.message ?? 'Facebook bejelentkezés megszakítva');
      }
      final OAuthCredential credential;
      if (token is LimitedToken) {
        credential = OAuthCredential(
          providerId: 'facebook.com',
          signInMethod: 'oauth',
          idToken: token.tokenString,
          rawNonce: rawNonce,
        );
      } else {
        credential = FacebookAuthProvider.credential(token.tokenString);
      }
      await FirebaseAuth.instance.signInWithCredential(credential);
      await _exchangeFirebaseToken();
    });
  }

  String _randomNonce([int length = 32]) {
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  Future<void> signInApple() async {
    await _run(() async {
      final provider = AppleAuthProvider();
      provider.addScope('email');
      provider.addScope('name');
      await FirebaseAuth.instance.signInWithProvider(provider);
      await _exchangeFirebaseToken();
    });
  }

  Future<void> signInEmail(String email, String password) async {
    await _run(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email.trim(), password: password);
      await _exchangeFirebaseToken();
    });
  }

  Future<void> registerCurrentFirebaseUser({
    required String firstName,
    required String lastName,
    String? phone,
    String? licenseNumber,
  }) async {
    final firebaseToken = await _freshFirebaseToken();
    final result = await _http.post('/api/v1/driver/auth/register', body: {
      'firebaseIdToken': firebaseToken,
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      if (phone?.trim().isNotEmpty == true) 'phone': phone!.trim(),
      if (licenseNumber?.trim().isNotEmpty == true) 'licenseNumber': licenseNumber!.trim(),
    }) as Map<String, dynamic>;
    throw DriverPendingException(
      'A regisztráció rögzítve. System admin jóváhagyás szükséges. '
      'Státusz: ${result['userStatus']}/${result['driverStatus']}',
    );
  }

  Future<String> validPlatformToken() async {
    final token = _platformToken;
    if (token != null && !_isJwtExpiring(token, const Duration(minutes: 2))) return token;
    await _exchangeFirebaseToken();
    return _platformToken!;
  }

  Future<void> refreshOnlineSession() async {
    await _exchangeFirebaseToken();
  }

  Future<void> _exchangeFirebaseToken() async {
    final firebaseToken = await _freshFirebaseToken();
    try {
      final result = await _http.post('/api/v1/driver/auth/exchange', body: {
        'firebaseIdToken': firebaseToken,
      }) as Map<String, dynamic>;
      final accessToken = '${result['accessToken']}';
      final driver = DriverSession.fromJson(Map<String, dynamic>.from(result['driver'] as Map));
      _platformToken = accessToken;
      _session = driver;
      await _storage.write(key: _tokenKey, value: accessToken);
      await _storage.write(key: _sessionKey, value: jsonEncode(driver.toJson()));
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const DriverNotRegisteredException();
      if (e.statusCode == 403) throw DriverPendingException(e.message);
      rethrow;
    }
  }

  Future<String> _freshFirebaseToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Nincs Firebase munkamenet');
    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) throw StateError('Nem sikerült Firebase tokent kérni');
    return token;
  }

  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    try {
      await FacebookAuth.instance.logOut();
    } catch (_) {}
    _platformToken = null;
    _session = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _sessionKey);
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    _busy = true;
    notifyListeners();
    try {
      await action();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  bool _isJwtExpiring(String token, Duration margin) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! num) return true;
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
          .isBefore(DateTime.now().toUtc().add(margin));
    } catch (_) {
      return true;
    }
  }
}
