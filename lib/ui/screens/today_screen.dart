import 'package:flutter/material.dart';

import '../../logging/app_log.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../models/trip_rules.dart';
import '../../services/app_services.dart';
import '../leg_flow.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';

/// „Ma”: fent az a fuvar, amelyikkel a sofőr úton van – ha nincs ilyen, a mai
/// legkorábbi, még át nem vett fuvar (a lekésett is) –, egyetlen nagy gombbal a
/// teendőhöz; alatta a mára hátralévő többi fuvar. Későbbi napra tervezett fuvar
/// itt nincs (az az Előjegyzésben van); ha mára nincs több, a következő látszik.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.services, required this.onBrowseFree});
  final AppServices services;
  final VoidCallback onBrowseFree;

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen> {
  List<DriverLeg> _legs = const [];
  Map<String, LegSyncState> _syncStates = const {};
  List<Map<String, dynamic>> _requests = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.services.sync.addListener(_reload);
    widget.services.work.addListener(_reload);
    _reload();
    _loadRequests();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_reload);
    widget.services.work.removeListener(_reload);
    super.dispose();
  }

  /// Lehúzás / fejléc: a szerverről is (ha van hálózat), különben a telefonon lévő munka.
  Future<void> refresh() async {
    try {
      await widget.services.work.myWork(refreshOnline: true);
    } catch (_) {
      // Offline: a telefonon lévő munka látszik.
    }
    await _reload();
    await _loadRequests();
  }

  Future<void> _reload() async {
    final legs = await widget.services.local.cachedLegs();
    final states = await widget.services.local.legSyncStates();
    if (mounted) setState(() { _legs = legs; _syncStates = states; });
  }

  /// A neki szóló, még jóvá nem hagyott átadási kérések (csak hálózattal).
  Future<void> _loadRequests() async {
    final me = widget.services.auth.session?.driverId;
    try {
      final all = await widget.services.api.transfers();
      final mine = all.where((t) => '${t['toDriverId']}' == me && t['status'] == 'PENDING' && t['toApprovedAt'] == null).toList();
      if (mounted) setState(() => _requests = mine);
    } catch (_) {
      // Offline: nincs mit mutatni.
    }
  }

  Future<void> _answer(Map<String, dynamic> request, bool accept) async {
    try {
      if (accept) {
        await widget.services.api.approveTransfer('${request['id']}');
      } else {
        await widget.services.api.rejectTransfer('${request['id']}');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(accept ? 'Átvetted a fuvart.' : 'Elutasítottad.')));
      await refresh();
    } catch (e) {
      log.warn('transfer', 'Átadási kérés megválaszolása nem sikerült', e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nem sikerült (internet kell hozzá): $e')));
    }
  }

  Future<void> _open(DriverLeg leg) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
    await _reload();
  }

  Future<void> _act(DriverLeg leg) async {
    final phase = nextPhase(leg);
    if (phase == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await runPhase(context, widget.services, leg, phase);
    } catch (e, stack) {
      log.error('work', 'A „Ma” képernyő művelete nem sikerült: ${leg.legKey}', e, stack);
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = todaysWork(_legs, now);
    final current = today.isEmpty ? null : today.first;
    final rest = today.skip(1).toList();
    final later = today.isEmpty ? nextLaterTrip(_legs, now) : null;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          for (final request in _requests) _TransferRequest(request: request, onAnswer: (accept) => _answer(request, accept)),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
          if (current == null)
            _Empty(onBrowseFree: widget.onBrowseFree, next: later, onOpenNext: later == null ? null : () => _open(later))
          else
            _CurrentTrip(
              leg: current,
              overdue: isOverdue(current, now),
              syncState: _syncStates[current.legKey],
              busy: _busy,
              onOpen: () => _open(current),
              onAct: () => _act(current),
            ),
          if (rest.isNotEmpty) ...[
            _Heading('Utána még ma (${rest.length})'),
            for (final leg in rest) LegCard(leg: leg, syncState: _syncStates[leg.legKey], onTap: () => _open(leg)),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
        child: Text(text, style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.ink900)),
      );
}

/// A mostani fuvar: nagy, egyértelmű kártya, alatta a teendő egyetlen gombja.
class _CurrentTrip extends StatelessWidget {
  const _CurrentTrip({required this.leg, required this.overdue, required this.syncState, required this.busy, required this.onOpen, required this.onAct});
  final DriverLeg leg;
  final bool overdue;
  final LegSyncState? syncState;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final running = leg.status == 'IN_PROGRESS';
    final strip = running ? AppColors.signalBlue : overdue ? AppColors.signalAmber : AppColors.panel800;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(
        color: AppColors.sheet000,
        shape: RoundedRectangleBorder(side: BorderSide(color: strip, width: 2), borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: strip,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Text(running ? 'ÚTON' : overdue ? 'LEKÉSETT – MÉG NEM VETTED ÁT' : 'KÖVETKEZŐ FUVAROD',
                    style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Colors.white, fontSize: 16)),
                const Spacer(),
                if (leg.plannedStart != null) Text(shortTime(leg.plannedStart), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(leg.registrationNumber, style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: 32, fontWeight: FontWeight.w700, color: AppColors.ink900)),
                if ([leg.make, leg.model].whereType<String>().isNotEmpty)
                  Text([leg.make, leg.model].whereType<String>().join(' '), style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
                const SizedBox(height: 10),
                _Place(icon: Icons.trip_origin, label: 'Honnan', place: leg.fromPlace, contact: [leg.fromContactName, leg.fromContactPhone].whereType<String>().join(' · ')),
                const SizedBox(height: 8),
                _Place(icon: Icons.flag, label: 'Hova', place: leg.toPlace, contact: [leg.toContactName, leg.toContactPhone].whereType<String>().join(' · ')),
                if (leg.isOutbound) const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('Körfuvar: leadás után várd meg az autót, és vidd vissza.', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.signalAmber)),
                ),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 60,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          onPressed: busy || leg.status == 'REVOKED' ? null : onAct,
          icon: Icon(running ? Icons.flag : Icons.key, size: 26),
          label: Text(running ? 'Autó leadása' : 'Autó átvétele'),
        ),
      ),
    ]);
  }
}

class _Place extends StatelessWidget {
  const _Place({required this.icon, required this.label, required this.place, required this.contact});
  final IconData icon;
  final String label;
  final String place;
  final String contact;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 22, color: AppColors.ink600),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(), style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink600)),
            Text(place, style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600)),
            if (contact.isNotEmpty) Text(contact, style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
          ]),
        ),
      ]);
}

/// „X át akarja adni neked ezt a fuvart” – egy koppintással elfogadható vagy elutasítható.
class _TransferRequest extends StatelessWidget {
  const _TransferRequest({required this.request, required this.onAnswer});
  final Map<String, dynamic> request;
  final void Function(bool accept) onAnswer;

  @override
  Widget build(BuildContext context) {
    final who = '${request['fromDriverName'] ?? 'Egy sofőr'}';
    final route = [request['fromLabel'], request['toLabel']].where((v) => v != null && '$v'.isNotEmpty).join(' → ');
    final when = request['plannedStart'] == null ? '' : shortTime(DateTime.tryParse('${request['plannedStart']}'));
    return Card(
      color: AppColors.tintAmber,
      shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.signalAmber), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$who neked adná ezt a fuvart', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: AppText.body)),
          const SizedBox(height: 4),
          Text('${request['registrationNumber']}${when.isEmpty ? '' : ' · $when'}${route.isEmpty ? '' : '\n$route'}'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => onAnswer(false), child: const Text('Nem kérem'))),
            const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: () => onAnswer(true), child: const Text('Átveszem'))),
          ]),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onBrowseFree, required this.next, required this.onOpenNext});
  final VoidCallback onBrowseFree;
  final DriverLeg? next;
  final VoidCallback? onOpenNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(children: [
        const Icon(Icons.local_taxi_outlined, size: 64, color: AppColors.ink600),
        const SizedBox(height: 12),
        const Text('Mára nincs több fuvarod.', textAlign: TextAlign.center, style: TextStyle(fontSize: AppText.body)),
        if (next != null) ...[
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event),
              title: Text('Következő: ${shortTime(next!.plannedStart)}'),
              subtitle: Text('${next!.registrationNumber} · ${next!.fromPlace}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenNext,
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onBrowseFree, icon: const Icon(Icons.playlist_add_check), label: const Text('Szabad fuvarok')),
      ]),
    );
  }
}
