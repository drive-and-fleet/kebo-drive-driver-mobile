import 'package:flutter/material.dart';

import '../../logging/app_log.dart';
import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../models/trip_rules.dart';
import '../../services/app_services.dart';
import '../leg_flow.dart';
import '../theme.dart';
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
    // Nincs mára fuvar: egy görgethető (lehúzással frissíthető) oldal.
    if (current == null) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            for (final request in _requests) _TransferRequest(request: request, onAnswer: (accept) => _answer(request, accept)),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
            _Empty(onBrowseFree: widget.onBrowseFree, next: later, onOpenNext: later == null ? null : () => _open(later)),
          ],
        ),
      );
    }
    // Fent rögzítve a mostani fuvar (nem görget el); alatta, vastag elválasztó után,
    // más háttéren a többi mai fuvar – csak ez a rész görget.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ConstrainedBox(
        // Kis képernyőn (vagy sok átadási kéréssel) se lógjon ki: ott a felső rész is görgethető.
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final request in _requests) _TransferRequest(request: request, onAnswer: (accept) => _answer(request, accept)),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: AppColors.signalRed))),
          _CurrentTrip(
            leg: current,
            overdue: isOverdue(current, now),
            waitingCount: today.where((l) => l.status != 'IN_PROGRESS').length,
            syncState: _syncStates[current.legKey],
            busy: _busy,
            onOpen: () => _open(current),
            onAct: () => _act(current),
          ),
        ]),
        ),
      ),
      Container(height: 4, color: AppColors.ruleFirm),
      Expanded(
        child: Container(
          color: AppColors.sheet100,
          child: RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                _Heading(rest.isEmpty ? 'Mára nincs több fuvarod' : 'További mai fuvarok (${rest.length})'),
                if (rest.isNotEmpty)
                  // Felvételi idő szerint, tömören: ne vonja el a figyelmet a fenti kártyáról.
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(children: [
                      for (var i = 0; i < rest.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _LaterTodayRow(leg: rest[i], onTap: () => _open(rest[i])),
                      ],
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ),
    ]);
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

/// Egy további mai fuvar egy sorban: idő és rendszám nagyban, a két hely kisebben.
class _LaterTodayRow extends StatelessWidget {
  const _LaterTodayRow({required this.leg, required this.onTap});
  final DriverLeg leg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = leg.plannedStart?.toLocal();
    final time = t == null ? '––:––' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    const small = TextStyle(fontSize: 14, color: AppColors.ink600);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 58, child: Text(time, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink900))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(leg.registrationNumber, style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink900)),
              Text('Felvétel: ${leg.fromPlace}', maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              Text('Leadás: ${leg.toPlace}', maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.ink400),
        ]),
      ),
    );
  }
}

/// A mostani fuvar: nagy, egyértelmű kártya, alatta a teendő egyetlen gombja.
/// Úton: pirosas; a mai következő: zöld; a lekésett: narancs.
class _CurrentTrip extends StatelessWidget {
  const _CurrentTrip({
    required this.leg,
    required this.overdue,
    required this.waitingCount,
    required this.syncState,
    required this.busy,
    required this.onOpen,
    required this.onAct,
  });
  final DriverLeg leg;
  final bool overdue;
  /// Hány mára szóló, még át nem vett fuvar van (ezzel együtt).
  final int waitingCount;
  final LegSyncState? syncState;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final running = leg.status == 'IN_PROGRESS';
    final strip = running ? AppColors.signalRed : overdue ? AppColors.signalAmber : AppColors.signalGreen;
    final title = running
        ? 'ÚTON VAGY EZZEL AZ AUTÓVAL'
        : overdue
            ? 'LEKÉSETT – MÉG NEM VETTED ÁT'
            : waitingCount > 1
                ? 'MAI KÖVETKEZŐ FUVAR (MA MÉG $waitingCount)'
                : 'MAI KÖVETKEZŐ FUVAR';
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
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Colors.white, fontSize: 16)),
                ),
                if (leg.plannedStart != null)
                  Text(overdue ? shortTime(leg.plannedStart) : _hm(leg.plannedStart!), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
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
          style: FilledButton.styleFrom(
            backgroundColor: running ? AppColors.signalRed : AppColors.signalGreen,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
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

const _monthNames = ['január', 'február', 'március', 'április', 'május', 'június', 'július', 'augusztus', 'szeptember', 'október', 'november', 'december'];
const _dayNames = ['hétfő', 'kedd', 'szerda', 'csütörtök', 'péntek', 'szombat', 'vasárnap'];

String _hm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// „Holnap, szeptember 29. (kedd)” / „Szeptember 30. (szerda)”.
String _dayLabel(DateTime t, DateTime now) {
  final l = t.toLocal();
  final day = DateTime(l.year, l.month, l.day);
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final name = '${_monthNames[l.month - 1]} ${l.day}. (${_dayNames[l.weekday - 1]})';
  return day == tomorrow ? 'Holnap, $name' : '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Mára nincs több fuvar. Alatta – jól elkülönítve, szürkén – a következő
/// előjegyzett fuvar, amely NEM mára szól: a nap neve nagyban látszik.
class _Empty extends StatelessWidget {
  const _Empty({required this.onBrowseFree, required this.next, required this.onOpenNext});
  final VoidCallback onBrowseFree;
  final DriverLeg? next;
  final VoidCallback? onOpenNext;

  @override
  Widget build(BuildContext context) {
    final leg = next;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.check_circle_outline, size: 64, color: AppColors.signalGreen),
        const SizedBox(height: 8),
        const Text('Mára nincs több fuvarod.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink900)),
        if (leg != null) ...[
          const SizedBox(height: 28),
          Material(
            color: AppColors.sheet050,
            shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.ruleFirm), borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenNext,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  color: AppColors.sheet100,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: const Row(children: [
                    Icon(Icons.event, size: 18, color: AppColors.ink600),
                    SizedBox(width: 8),
                    Text('ELŐJEGYZETT FUVAR – NEM MÁRA SZÓL',
                        style: TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: AppColors.ink600, fontSize: 15)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (leg.plannedStart != null)
                      Text('${_dayLabel(leg.plannedStart!, DateTime.now())} · ${_hm(leg.plannedStart!)}',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink900)),
                    const SizedBox(height: 4),
                    Text(leg.registrationNumber, style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink600)),
                    Text('Felvétel: ${leg.fromPlace}', style: const TextStyle(fontSize: 14, color: AppColors.ink600)),
                    Text('Leadás: ${leg.toPlace}', style: const TextStyle(fontSize: 14, color: AppColors.ink600)),
                  ]),
                ),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Center(child: OutlinedButton.icon(onPressed: onBrowseFree, icon: const Icon(Icons.playlist_add_check), label: const Text('Szabad fuvarok'))),
      ]),
    );
  }
}
