import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../logging/app_log.dart';

/// Az app saját kamerája. A fotó az appon belül készül, nem kell külön kamera-alkalmazásra
/// váltani – így az Android nem állítja le közben az appot (kevés memóriánál ezt tette).
/// Visszaadja a kép útvonalát; null, ha a sofőr kilépett. Ha a kamera nem indítható,
/// [CameraUnavailable]-t dob: ilyenkor a hívó a telefon kamera-alkalmazásával próbálja.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.title = 'Fotó'});
  final String title;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class CameraUnavailable implements Exception {
  const CameraUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'A kamera nem indítható: $reason';
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;
  XFile? _shot;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Háttérbe kerülve a kamera felszabadul, visszatérve újraindul.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller = null;
      controller?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && controller == null && _shot == null) {
      _start();
    }
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw const CameraUnavailable('nincs kamera az eszközön');
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final controller = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() { _controller = controller; _error = null; });
    } catch (e) {
      log.warn('insp', 'Az app kamerája nem indult', e);
      if (!mounted) return;
      // Engedély megtagadva vagy nincs kamera: a hívó a telefon kamera-alkalmazásával próbálja.
      Navigator.of(context).pop(e is CameraUnavailable ? e : CameraUnavailable('$e'));
    }
  }

  Future<void> _take() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      if (mounted) setState(() => _shot = shot);
    } catch (e) {
      log.warn('insp', 'A fotó nem készült el', e);
      if (mounted) setState(() => _error = 'A fotó nem készült el, próbáld újra.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFlash() async {
    final next = switch (_flash) { FlashMode.off => FlashMode.auto, FlashMode.auto => FlashMode.always, _ => FlashMode.off };
    try {
      await _controller?.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
    } catch (_) {/* nincs vaku */}
  }

  IconData get _flashIcon => switch (_flash) { FlashMode.auto => Icons.flash_auto, FlashMode.always => Icons.flash_on, _ => Icons.flash_off };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final shot = _shot;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          if (shot == null) IconButton(onPressed: _toggleFlash, icon: Icon(_flashIcon), tooltip: 'Vaku'),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: shot != null
                  ? Image.file(File(shot.path), fit: BoxFit.contain)
                  : controller != null && controller.value.isInitialized
                      ? CameraPreview(controller)
                      : const CircularProgressIndicator(color: Colors.white),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.white))),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: shot != null
                ? Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white), minimumSize: const Size.fromHeight(52)),
                      onPressed: () { setState(() => _shot = null); if (_controller == null) _start(); },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Újra'),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () => Navigator.of(context).pop(shot),
                      icon: const Icon(Icons.check),
                      label: const Text('Megtartom'),
                    )),
                  ])
                : Center(
                    child: Semantics(
                      button: true,
                      label: 'Fotó készítése',
                      child: GestureDetector(
                        onTap: _take,
                        child: Container(
                          width: 78,
                          height: 78,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 5), color: _busy ? Colors.white38 : Colors.white24),
                        ),
                      ),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
