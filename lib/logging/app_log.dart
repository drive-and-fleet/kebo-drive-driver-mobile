import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Az alkalmazás naplója: minden üzleti lépés és hiba egy sorban, időbélyeggel.
///
/// A telefonon fájlba kerül (két, egyenként legfeljebb [maxFileBytes] méretű
/// fájl váltja egymást, együtt kb. 2 MB), így egy hibajelentés a hibát megelőző munkát is
/// tartalmazza, akkor is, ha az app közben újraindult. Jelszó, token, fotó nem
/// kerülhet bele: a hívók azonosítókat és állapotokat naplóznak, nem tartalmat.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// Két fájl váltja egymást, így kb. 2 MB (több napnyi munka) marad meg.
  static const maxFileBytes = 1024 * 1024;
  static const _memoryLines = 400;

  File? _current;
  File? _previous;
  final _memory = ListQueue<String>();
  final _pending = <String>[];
  Future<void> _writing = Future.value();
  Timer? _flushTimer;

  /// Egyszer, induláskor. Hiba esetén a napló csak memóriában él tovább.
  Future<void> init() async {
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));
      await dir.create(recursive: true);
      _current = File(p.join(dir.path, 'app.log'));
      _previous = File(p.join(dir.path, 'app.1.log'));
    } catch (e) {
      debugPrint('AppLog: a naplófájl nem használható: $e');
    }
  }

  void debug(String tag, String message) => _add('D', tag, message);
  void info(String tag, String message) => _add('I', tag, message);
  void warn(String tag, String message, [Object? error]) => _add('W', tag, error == null ? message : '$message — $error');
  void error(String tag, String message, [Object? error, StackTrace? stack]) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(' — $error');
    if (stack != null) buffer.write('\n${_trim(stack)}');
    _add('E', tag, buffer.toString());
  }

  static String _trim(StackTrace stack) => stack.toString().split('\n').take(12).join('\n');

  void _add(String level, String tag, String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} $level ${tag.padRight(8)} $message';
    if (kDebugMode) debugPrint(line);
    _memory.addLast(line);
    while (_memory.length > _memoryLines) {
      _memory.removeFirst();
    }
    if (_current == null) return;
    _pending.add(line);
    // Kötegelve ír, így egy gyors műveletsor sem terheli a lemezt soronként.
    _flushTimer ??= Timer(const Duration(milliseconds: 400), flush);
    if (level == 'E') flush();
  }

  /// A függő sorok kiírása; a hívások sorba állnak, így a sorrend megmarad.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty || _current == null) return _writing;
    final chunk = '${_pending.join('\n')}\n';
    _pending.clear();
    _writing = _writing.then((_) async {
      try {
        final current = _current!;
        if (await current.exists() && await current.length() > maxFileBytes) {
          if (await _previous!.exists()) await _previous!.delete();
          await current.rename(_previous!.path);
        }
        await current.writeAsString(chunk, mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('AppLog: írási hiba: $e');
      }
    });
    return _writing;
  }

  /// A teljes elérhető napló (régebbi fájl + aktuális), a hibajelentéshez.
  Future<String> collect() async {
    await flush();
    final parts = <String>[];
    for (final file in [_previous, _current]) {
      if (file != null && await file.exists()) parts.add(await file.readAsString());
    }
    // Ha a fájl nem használható, legalább a memóriában tartott sorok menjenek.
    return parts.isEmpty ? '${_memory.join('\n')}\n' : parts.join();
  }
}

/// Rövid hozzáférés: `log.info('sync', '...')`.
AppLog get log => AppLog.instance;
