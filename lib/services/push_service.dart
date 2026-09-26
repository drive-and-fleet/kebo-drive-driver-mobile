import 'dart:async';
import 'dart:io';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/driver_api.dart';
import '../config/app_config.dart';
import '../logging/app_log.dart';
import 'location_service.dart';
import 'work_service.dart';

/// Push-értesítés (Firebase Cloud Messaging).
///
/// Az iroda kiosztása, egy út levétele/lemondása és egy átadási kérés értesítést
/// küld, ha a telefonon engedélyezve vannak az értesítések. Az app megnyitásakor
/// az értesítések és a jelvény (badge) nullázódnak. A csendes „élő követés”
/// push a helyzetmegosztást kapcsolja élő módba. Push nélkül (nincs beállítva,
/// vagy iOS Apple-fiók nélkül) az app ugyanúgy működik: az automatikus frissítés
/// hozza az új fuvart.
class PushService {
  PushService(this.api, this.work, this.location);
  final DriverApi api;
  final WorkService work;
  final LocationService location;

  static const channelId = 'fuvarok';
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _started = false;
  String? _token;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _onMessage;
  StreamSubscription<RemoteMessage>? _onOpened;

  /// Egy értesítésre koppintva ezt az utat kell megnyitni (a kezdőképernyő figyeli).
  final ValueNotifier<String?> openLeg = ValueNotifier(null);

  /// Előtérben érkezett értesítés szövege (a kezdőképernyő egy sávban mutatja).
  final ValueNotifier<String?> foregroundMessage = ValueNotifier(null);

  bool get enabled => AppConfig.pushActive;

  /// Bejelentkezés után: engedély (Android 13+ / iOS), token regisztrálása, figyelők.
  Future<void> start(BuildContext context) async {
    if (!enabled || _started) return;
    _started = true;
    try {
      await _notifications.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ));
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(channelId, 'Fuvarok',
              description: 'Új fuvar, lekerült vagy lemondott út, átadási kérés', importance: Importance.high));

      final messaging = FirebaseMessaging.instance;
      var settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined && context.mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Értesítések'),
            content: const Text('Az app értesít, ha az iroda új fuvart oszt ki neked, ha egy utad lekerül vagy lemondják, '
                'és ha egy kolléga átadna neked egy utat. Az értesítéseket a telefon beállításaiban bármikor kikapcsolhatod.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Most nem')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Rendben')),
            ],
          ),
        );
        if (ok == true) settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
      }
      log.info('push', 'Értesítési engedély: ${settings.authorizationStatus.name}');

      _token = await messaging.getToken();
      if (_token != null) await _register(_token!);
      _tokenRefresh = messaging.onTokenRefresh.listen((token) {
        _token = token;
        unawaited(_register(token));
      });
      _onMessage = FirebaseMessaging.onMessage.listen(_handleForeground);
      _onOpened = FirebaseMessaging.onMessageOpenedApp.listen(_handleOpened);
      final initial = await messaging.getInitialMessage();
      if (initial != null) _handleOpened(initial);
      await clear();
    } catch (e) {
      log.warn('push', 'A push-értesítés indítása nem sikerült', e);
    }
  }

  Future<void> _register(String token) async {
    try {
      String? version;
      try {
        final info = await PackageInfo.fromPlatform();
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      await api.registerDevice(token, platform: Platform.isIOS ? 'ios' : 'android', appVersion: version);
      log.info('push', 'Eszköz regisztrálva az értesítésekhez');
    } catch (e) {
      log.warn('push', 'Az eszköz regisztrálása most nem sikerült (később újrapróbálja)', e);
    }
  }

  void _handleForeground(RemoteMessage message) {
    final kind = message.data['kind'];
    log.info('push', 'Értesítés előtérben: $kind');
    if (kind == 'LIVE_TRACKING') {
      unawaited(location.goLive(message.data['legKey']?.toString()));
      return;
    }
    unawaited(work.myWork().then((_) {}, onError: (_) {}));
    final text = [message.notification?.title, message.notification?.body].whereType<String>().join(': ');
    if (text.isNotEmpty) foregroundMessage.value = text;
    unawaited(clear());
  }

  void _handleOpened(RemoteMessage message) {
    log.info('push', 'Értesítésre koppintott: ${message.data['kind']}');
    final legKey = message.data['legKey']?.toString();
    unawaited(work.myWork().then((_) => openLeg.value = legKey, onError: (_) => openLeg.value = legKey));
  }

  /// Az app megnyitásakor: a telefonon lévő értesítések és a jelvény nullázódnak (a szerveren is).
  Future<void> clear() async {
    if (!enabled || !_started) return;
    try {
      await _notifications.cancelAll();
      await AppBadgePlus.updateBadge(0);
      await api.pushSeen();
    } catch (e) {
      log.debug('push', 'Az értesítések nullázása most nem sikerült: $e');
    }
  }

  /// Kijelentkezéskor a telefon többé nem kap értesítést ennek a sofőrnek.
  Future<void> signOut() async {
    if (!enabled || !_started) return;
    try {
      if (_token != null) await api.unregisterDevice(_token!);
      await FirebaseMessaging.instance.deleteToken();
      await _notifications.cancelAll();
      await AppBadgePlus.updateBadge(0);
    } catch (e) {
      log.debug('push', 'Kijelentkezéskor a push leiratkozás nem sikerült: $e');
    }
    await _tokenRefresh?.cancel();
    await _onMessage?.cancel();
    await _onOpened?.cancel();
    _token = null;
    _started = false;
  }
}
