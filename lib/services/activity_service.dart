import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../api/driver_api.dart';
import '../auth/auth_service.dart';
import '../logging/app_log.dart';

/// Tevékenységnapló (mobil app): a megnyitott képernyők sorba kerülnek, és 20
/// másodpercenként egy csomagban mennek fel. Soha nem vár rá semmi, és soha nem
/// jelez hibát: hálózat nélkül a sor megmarad (legfeljebb 300 bejegyzés), később megy fel.
class ActivityService {
  ActivityService(this.api, this.auth) {
    AppLog.onScreen = screen;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(flush()));
  }

  final DriverApi api;
  final AuthService auth;
  final List<Map<String, String>> _queue = [];
  Timer? _timer;
  bool _sending = false;
  String? _version;

  /// Egy képernyő megnyílt (a naplóból jön).
  void screen(String name) {
    if (!auth.isSignedIn) return;
    final shown = name.trim();
    if (shown.isEmpty) return;
    if (_queue.isNotEmpty && _queue.last['screen'] == shown) return;
    _queue.add({'screen': shown.length > 200 ? shown.substring(0, 200) : shown, 'at': DateTime.now().toUtc().toIso8601String()});
    if (_queue.length > 300) _queue.removeRange(0, _queue.length - 300);
  }

  Future<void> flush() async {
    if (_sending || _queue.isEmpty || !auth.isSignedIn) return;
    _sending = true;
    final batch = List<Map<String, String>>.of(_queue.take(200));
    try {
      _version ??= await _appVersion();
      await api.postActivity(batch, _version);
      _queue.removeRange(0, batch.length);
    } catch (_) {
      // Hálózat nélkül: a sorban marad, a következő körben megy fel.
    } finally {
      _sending = false;
    }
  }

  static Future<String?> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return null;
    }
  }

  void dispose() => _timer?.cancel();
}
