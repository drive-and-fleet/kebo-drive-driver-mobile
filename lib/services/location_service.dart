import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../api/driver_api.dart';
import '../api/http_api.dart';
import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../models/models.dart';
import 'work_service.dart';

/// Egy mért pont a lezáráshoz (hol volt a telefon).
typedef Fix = ({double latitude, double longitude, double? accuracy});

/// Helyzetmegosztás fuvar közben, akkumulátorkímélően.
///
/// Csak akkor fut, ha a telefonon van folyamatban lévő út (átvételtől leadásig),
/// az iroda engedélyezte a megosztást, és a sofőr megadta a helyengedélyt.
/// Alapmódban közepes pontosság (mobilhálózat/Wi-Fi alapú, ~100 m), 250 m-es
/// távolságszűrő, és 3 percenként egy kötegelt feltöltés. Élő módba csak akkor
/// vált (nagy pontosság, 30 m, 20 s), ha valaki éppen nézi az utat – ezt a
/// szerver a feltöltés válaszában vagy egy csendes pushban jelzi –, és 10 perc
/// után magától visszavált. A pontok előbb a telefonra kerülnek (local-first),
/// térerő nélkül sem vesznek el.
class LocationService extends ChangeNotifier {
  LocationService(this.api, this.local, this.work);
  final DriverApi api;
  final LocalRepository local;
  final WorkService work;

  static const _normalUpload = Duration(minutes: 3);
  static const _liveUpload = Duration(seconds: 20);
  static const _liveWindow = Duration(minutes: 10);

  StreamSubscription<Position>? _sub;
  Timer? _timer;
  String? _legKey;
  bool _live = false;
  DateTime? _liveUntil;
  Duration _uploadEvery = _normalUpload;
  DateTime _lastUpload = DateTime.fromMillisecondsSinceEpoch(0);
  bool _uploading = false;
  bool _evaluating = false;

  /// Az út, amelynek a helyzetét most megosztjuk (a felület ezt jelzi), vagy null.
  String? get sharingLegKey => _sub == null ? null : _legKey;
  bool get isLive => _live;

  void initialize() {
    work.addListener(() => unawaited(evaluate()));
    work.positionProvider = currentFix;
    unawaited(evaluate());
  }

  /// Megnézi, kell-e most követni: van-e megosztható, folyamatban lévő út ezen a telefonon.
  Future<void> evaluate() async {
    if (_evaluating) return;
    _evaluating = true;
    try {
      final legs = (await local.cachedLegs()).where((l) => l.status == 'IN_PROGRESS' && l.locationSharing).toList()
        ..sort((a, b) => (b.plannedStart ?? DateTime(2000)).compareTo(a.plannedStart ?? DateTime(2000)));
      if (legs.isEmpty) {
        await stop();
        return;
      }
      if (!await _permitted()) {
        log.info('loc', 'Helyzetmegosztás kellene (${legs.first.legKey}), de nincs helyengedély');
        return;
      }
      await _start(legs.first.legKey);
    } catch (e) {
      log.warn('loc', 'Helyzetmegosztás ellenőrzése nem sikerült', e);
    } finally {
      _evaluating = false;
    }
  }

  /// A felület kérdezi: megvan-e már a helyengedély (előre engedélyezhető, még indulás előtt).
  Future<bool> permitted() => _permitted();

  Future<bool> _permitted() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse || permission == LocationPermission.always;
  }

  /// Az átvétel lezárása után: ha az út megosztható és még nincs engedély,
  /// elmagyarázza, miért kérjük, és utána kéri az engedélyt.
  Future<void> askIfNeeded(BuildContext context, DriverLeg leg) async {
    if (!leg.locationSharing) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      await evaluate();
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Helyzet megosztása'),
        content: const Text(
          'A sofőrszolgálat kéri, hogy fuvar közben – az átvételtől a leadásig – a telefon megossza a helyzetedet '
          'az irodával és a címzettel, hogy lássák, mikor érkezel.\n\n'
          'Csak az út alatt megy, akkumulátorkímélő módban; leadás után azonnal leáll. '
          'Az engedélyt a telefon beállításaiban bármikor visszavonhatod.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Most nem')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Engedélyezem')),
        ],
      ),
    );
    if (ok != true) {
      log.info('loc', 'A sofőr most nem engedélyezte a helyzetmegosztást');
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    }
    permission = await Geolocator.requestPermission();
    log.info('loc', 'Helyengedély: ${permission.name}');
    await evaluate();
  }

  LocationSettings _settings() {
    final live = _live;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: live ? LocationAccuracy.high : LocationAccuracy.medium,
        distanceFilter: live ? 30 : 250,
        intervalDuration: live ? const Duration(seconds: 10) : const Duration(seconds: 60),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Fuvar folyamatban',
          notificationText: 'A helyzeted az irodával és a címzettel megosztva, amíg le nem adod az autót.',
          enableWakeLock: false,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: live ? LocationAccuracy.high : LocationAccuracy.medium,
        distanceFilter: live ? 30 : 250,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(accuracy: live ? LocationAccuracy.high : LocationAccuracy.medium, distanceFilter: live ? 30 : 250);
  }

  Future<void> _start(String legKey, {bool restart = false}) async {
    if (!restart && _sub != null && _legKey == legKey) return;
    await _sub?.cancel();
    _legKey = legKey;
    _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (Object e) => log.warn('loc', 'Helyzetfolyam hiba', e),
    );
    _schedule();
    log.info('loc', 'Helyzetmegosztás ${restart ? 'módváltás' : 'indul'}: $legKey (${_live ? 'élő' : 'alap'} mód)');
    notifyListeners();
  }

  Future<void> stop() async {
    if (_sub == null && _timer == null) return;
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _live = false;
    _liveUntil = null;
    log.info('loc', 'Helyzetmegosztás leállt${_legKey == null ? '' : ': $_legKey'}');
    _legKey = null;
    notifyListeners();
    unawaited(upload());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_uploadEvery, (_) => unawaited(upload()));
  }

  Future<void> _onPosition(Position p) async {
    final legKey = _legKey;
    if (legKey == null) return;
    await local.addLocationPoint(legKey,
        latitude: p.latitude, longitude: p.longitude, accuracy: p.accuracy, speed: p.speed, heading: p.heading, recordedAt: p.timestamp);
    if (_live && _liveUntil != null && DateTime.now().isAfter(_liveUntil!)) await _setLive(false);
    // iOS-en a háttérben az időzítő alhat: a pont érkezése maga is feltöltést indíthat.
    if (DateTime.now().difference(_lastUpload) >= _uploadEvery) unawaited(upload());
  }

  /// A szerver (csendes push) jelzi: valaki most nézi az utat.
  Future<void> goLive(String? legKey) async {
    if (legKey != null && _legKey != null && legKey != _legKey) return;
    _liveUntil = DateTime.now().add(_liveWindow);
    if (!_live) await _setLive(true);
  }

  Future<void> _setLive(bool live) async {
    if (_live == live) return;
    _live = live;
    if (!live) _liveUntil = null;
    _uploadEvery = live ? _liveUpload : _normalUpload;
    if (_legKey != null) await _start(_legKey!, restart: true);
  }

  /// A telefonon gyűlt pontok feltöltése utanként, 200-as kötegekben.
  Future<void> upload() async {
    if (_uploading) return;
    _uploading = true;
    _lastUpload = DateTime.now();
    try {
      for (final legKey in await local.legsWithPendingLocations()) {
        if (legKey.startsWith('local-')) continue; // a szerveren még nincs meg az út (új fuvar szinkron előtt)
        while (true) {
          final batch = await local.pendingLocationPoints(legKey);
          if (batch.isEmpty) break;
          final ids = [for (final p in batch) p['id'] as int];
          final points = [for (final p in batch) Map<String, dynamic>.from(p)..remove('id')];
          try {
            final answer = await api.uploadLocations(legKey, points);
            await local.deleteLocationPoints(ids);
            if (legKey == _legKey) {
              final live = answer['live'] == true;
              if (live) _liveUntil = DateTime.now().add(_liveWindow);
              if (live != _live) await _setLive(live);
            }
          } on ApiException catch (e) {
            if (e.statusCode == 409 || e.statusCode == 404) {
              // Az út véget ért, lekerült, vagy az iroda kikapcsolta a megosztást: ezeket már nem várja senki.
              log.info('loc', 'A szerver nem fogad több pontot ($legKey): ${e.message}');
              await local.dropLocationPoints(legKey);
              await local.setLegLocationSharing(legKey, false);
              if (legKey == _legKey) await stop();
            } else {
              log.debug('loc', 'Pontok feltöltése most nem sikerült ($legKey): ${e.message}');
            }
            break;
          }
          if (batch.length < 200) break;
        }
      }
    } catch (e) {
      log.debug('loc', 'Pontok feltöltése most nem sikerült: $e');
    } finally {
      _uploading = false;
    }
  }

  /// Hol van most a telefon (a jegyzőkönyv lezárásához) – csak meglévő engedéllyel, legfeljebb 8 másodpercig vár.
  Future<Fix?> currentFix() async {
    try {
      if (!await _permitted()) return null;
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 8)),
      );
      return (latitude: p.latitude, longitude: p.longitude, accuracy: p.accuracy);
    } catch (e) {
      log.debug('loc', 'A lezáráskori helyzet nem mérhető: $e');
      return null;
    }
  }

  /// Kijelentkezéskor: ami még feltölthető, felmegy, a többi a telefonon nem marad.
  Future<void> signOut() async {
    await stop();
    await upload();
    for (final legKey in await local.legsWithPendingLocations()) {
      await local.dropLocationPoints(legKey);
    }
  }
}
