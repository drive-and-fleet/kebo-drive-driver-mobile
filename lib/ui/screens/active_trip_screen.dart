import 'package:flutter/material.dart';

import '../../logging/app_log.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../leg_flow.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';

/// „Most”: a sofőr mindig látja, melyik fuvarban van éppen. Középen a folyamatban
/// lévő út (vagy ha nincs, a következő kiosztott), egy gombbal a teendő
/// (átvétel / leadás), alatta a mai többi fuvar. Minden a telefonról jön
/// (local-first), a háttérszinkron frissíti.
class ActiveTripScreen extends StatefulWidget {
  const ActiveTripScreen({super.key, required this.services, required this.onBrowseFree});
  final AppServices services;
  final VoidCallback onBrowseFree;

  @override
  State<ActiveTripScreen> createState() => ActiveTripScreenState();
}

class ActiveTripScreenState extends State<ActiveTripScreen> {
  List<DriverLeg> _legs = const [];
  Map<String, LegSyncState> _syncStates = const {};
  bool _copy = true;
  bool _copyAvailable = false;
  bool _pickupExists = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Most');
    widget.services.sync.addListener(_reload);
    widget.services.work.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_reload);
    widget.services.work.removeListener(_reload);
    super.dispose();
  }

  /// A kézi frissítés (fejléc gomb, lehúzás): a szerverről is.
  Future<void> refresh() async {
    try {
      await widget.services.work.myWork(refreshOnline: true);
    } catch (_) {
      // Offline: a telefonon lévő munka látszik.
    }
    await _reload();
  }

  Future<void> _reload() async {
    final legs = await widget.services.local.cachedLegs();
    final states = await widget.services.local.legSyncStates();
    final current = _pick(legs);
    final phase = current == null ? null : nextPhase(current);
    final copyAvailable = current != null && phase != null && await canCopyInto(widget.services, current, phase);
    final pickup = current == null ? null : await widget.services.local.inspectionForLeg(current.legKey, 'PICKUP');
    if (!mounted) return;
    setState(() {
      _legs = legs;
      _syncStates = states;
      _copyAvailable = copyAvailable;
      _pickupExists = pickup != null;
    });
  }

  static int _byStart(DriverLeg a, DriverLeg b) {
    final x = a.plannedStart, y = b.plannedStart;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  /// A folyamatban lévő út; ha nincs, a legkorábbi kiosztott.
  static DriverLeg? _pick(List<DriverLeg> legs) {
    final running = legs.where((l) => l.status == 'IN_PROGRESS').toList()..sort(_byStart);
    if (running.isNotEmpty) return running.first;
    final next = legs.where((l) => l.status == 'ASSIGNED').toList()..sort(_byStart);
    return next.isEmpty ? null : next.first;
  }

  static bool _isToday(DateTime? t) {
    if (t == null) return false;
    final l = t.toLocal(), n = DateTime.now();
    return l.year == n.year && l.month == n.month && l.day == n.day;
  }

  Future<void> _run(DriverLeg leg) async {
    final phase = nextPhase(leg);
    if (phase == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await runPhase(context, widget.services, leg, phase, copy: _copy);
    } catch (e, stack) {
      log.error('work', 'A „Most” képernyő művelete nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _open(DriverLeg leg) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final current = _pick(_legs);
    final others = _legs
        .where((l) => l.legKey != current?.legKey && const {'ASSIGNED', 'IN_PROGRESS'}.contains(l.status) && _isToday(l.plannedStart))
        .toList()
      ..sort(_byStart);
    final doneToday = _legs.where((l) => const {'COMPLETED', 'COMPLETED_PENDING_SYNC'}.contains(l.status) && _isToday(l.plannedStart)).length;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
          if (current == null)
            _Empty(onBrowseFree: widget.onBrowseFree)
          else ...[
            _Headline(leg: current),
            const SizedBox(height: 8),
            LegCard(leg: current, syncState: _syncStates[current.legKey], onTap: () => _open(current)),
            if (current.status == 'IN_PROGRESS' && current.isOutbound)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 4),
                child: Text('Körfuvar: a leadás után várd meg az autót, és vidd vissza.',
                    style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.signalAmber)),
              ),
            const SizedBox(height: 8),
            if (_copyAvailable)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _copy,
                onChanged: _busy ? null : (v) => setState(() => _copy = v),
                title: const Text('Másolás az előző jegyzőkönyvből'),
                subtitle: const Text('Kikapcsolva üres jegyzőkönyv indul.'),
              ),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : () => _run(current),
              icon: Icon(current.status == 'IN_PROGRESS' ? Icons.done_all : Icons.play_arrow),
              label: Text(current.status == 'IN_PROGRESS' ? 'Leadás – leadási jegyzőkönyv' : 'Átvétel – átvételi jegyzőkönyv'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              if (_pickupExists)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await openInspection(context, widget.services, current, 'PICKUP');
                      } catch (e) {
                        if (mounted) setState(() => _error = '$e');
                      }
                      await _reload();
                    },
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Átvételi jkv.'),
                  ),
                ),
              if (_pickupExists) const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _open(current),
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Részletek'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 20),
          Text(others.isEmpty ? 'Ma nincs több fuvarod.' : 'Ma még ${others.length} fuvarod van',
              style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.ink900)),
          if (doneToday > 0)
            Text('Ma teljesítve: $doneToday', style: const TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
          const SizedBox(height: 6),
          for (final leg in others) LegCard(leg: leg, syncState: _syncStates[leg.legKey], onTap: () => _open(leg)),
        ],
      ),
    );
  }
}

/// A sáv, amely kimondja: most ebben vagy / ez a következő.
class _Headline extends StatelessWidget {
  const _Headline({required this.leg});
  final DriverLeg leg;

  @override
  Widget build(BuildContext context) {
    final running = leg.status == 'IN_PROGRESS';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: running ? AppColors.signalBlue : AppColors.panel800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(running ? Icons.directions_car : Icons.schedule, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(running ? 'MOST EBBEN A FUVARBAN VAGY' : 'KÖVETKEZŐ FUVAROD',
                style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Colors.white, fontSize: 15)),
            Text(
              running
                  ? 'Úton: ${leg.registrationNumber} → ${leg.toPlace}'
                  : '${leg.registrationNumber}${leg.plannedStart == null ? '' : ' · indulás: ${shortTime(leg.plannedStart)}'}',
              style: const TextStyle(color: Colors.white, fontSize: AppText.secondary),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onBrowseFree});
  final VoidCallback onBrowseFree;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(children: [
        const Icon(Icons.local_taxi_outlined, size: 64, color: AppColors.ink600),
        const SizedBox(height: 12),
        const Text('Most nincs folyamatban lévő vagy kiosztott fuvarod.', textAlign: TextAlign.center, style: TextStyle(fontSize: AppText.body)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onBrowseFree, icon: const Icon(Icons.playlist_add_check), label: const Text('Szabad fuvarok')),
      ]),
    );
  }
}
