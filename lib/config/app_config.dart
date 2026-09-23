import 'dart:io';

import 'package:firebase_core/firebase_core.dart';

class AppConfig {
  static const driverApiBaseUrl = String.fromEnvironment(
    'DRIVER_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3002',
  );
  // Alapértelmezésben csak a Driver API kell: e-mail/jelszó regisztráció és
  // belépés Firebase projekt nélkül is működik. A Google/Facebook/Apple
  // belépés kódja megmarad, csak ezzel a kapcsolóval érhető el.
  static const socialLoginEnabled = bool.fromEnvironment('SOCIAL_LOGIN_ENABLED');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const firebaseAndroidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  static const firebaseIosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const firebaseIosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
  static const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  static void validate() {
    if (!socialLoginEnabled) return;
    final required = <String, String>{
      'FIREBASE_PROJECT_ID': firebaseProjectId,
      'FIREBASE_API_KEY': firebaseApiKey,
      'FIREBASE_MESSAGING_SENDER_ID': firebaseMessagingSenderId,
      Platform.isIOS ? 'FIREBASE_IOS_APP_ID' : 'FIREBASE_ANDROID_APP_ID':
          Platform.isIOS ? firebaseIosAppId : firebaseAndroidAppId,
    };
    final missing = required.entries.where((entry) => entry.value.isEmpty).map((entry) => entry.key).toList();
    if (missing.isNotEmpty) {
      throw StateError('Missing build configuration: ${missing.join(', ')}');
    }
  }

  static FirebaseOptions get firebaseOptions {
    validate();
    return FirebaseOptions(
      apiKey: firebaseApiKey,
      appId: Platform.isIOS ? firebaseIosAppId : firebaseAndroidAppId,
      messagingSenderId: firebaseMessagingSenderId,
      projectId: firebaseProjectId,
      iosBundleId: Platform.isIOS && firebaseIosBundleId.isNotEmpty ? firebaseIosBundleId : null,
    );
  }
}
