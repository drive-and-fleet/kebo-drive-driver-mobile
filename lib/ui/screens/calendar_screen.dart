import 'package:flutter/material.dart';

import '../../logging/app_log.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import 'leg_detail_screen.dart';

const _months = ['január', 'február', 'március', 'április', 'május', 'június', 'július', 'augusztus', 'szeptember', 'október', 'november', 'december'];
const _weekdays = ['hétfő', 'kedd', 'szerda', 'csütörtök', 'péntek', 'szombat', 'vasárnap'];
const _weekdaysShort = ['H', 'K', 'Sze', 'Cs', 'P', 'Szo', 'V'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

String _hm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// „Előjegyzés”: áttekintés hétre vagy hónapra – naponként hány fuvar és mikor.
/// Egy napra koppintva a nap fuvarjai nyílnak meg, onnan a fuvar adatlapja.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<CalendarScreen> createState() => CalendarScreenState();
}

class CalendarScreenState extends State<CalendarScreen> {
  bool _month = false;
  DateTime _anchor = DateTime.now();
  List<DriverLeg> _legs = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.services.work.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    widget.services.work.removeListener(_reload);
    super.dispose();
  }

  Future<void> refresh() => _load();

  Future<void> _reload() async {
    final legs = await widget.services.local.cachedLegs();
    if (mounted) setState(() => _legs = legs);
  }

  /// A telefonon lévő munka; múltbeli időszaknál a teljesítettek is letöltődnek (ha van hálózat).
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (from, _) = _range();
      if (from.isBefore(DateTime.now())) {
        final days = DateTime.now().difference(from).inDays + 1;
        await widget.services.work.completedWork(days.clamp(1, 366));
      }
    } catch (_) {
      // Offline: a telefonon lévő látszik.
    }
    await _reload();
    if (mounted) setState(() => _loading = false);
  }

  (DateTime, DateTime) _range() {
    final a = _day(_anchor);
    if (_month) return (DateTime(a.year, a.month), DateTime(a.year, a.month + 1));
    final from = a.subtract(Duration(days: a.weekday - 1));
    return (from, from.add(const Duration(days: 7)));
  }

  void _step(int direction) {
    setState(() => _anchor = _month ? DateTime(_anchor.year, _anchor.month + direction, 1) : _anchor.add(Duration(days: 7 * direction)));
    _load();
  }

  String _title() {
    final (from, to) = _range();
    if (_month) return '${from.year}. ${_months[from.month - 1]}';
    final last = to.subtract(const Duration(days: 1));
    return '${_months[from.month - 1]} ${from.day}. – ${from.month == last.month ? '' : '${_months[last.month - 1]} '}${last.day}.';
  }

  List<DriverLeg> _on(DateTime day) {
    final list = _legs.where((l) => l.status != 'REVOKED' && l.plannedStart != null && _day(l.plannedStart!.toLocal()) == day).toList()
      ..sort((a, b) => a.plannedStart!.compareTo(b.plannedStart!));
    return list;
  }

  /// A sofőr fuvarjai a hét / hónap napjain (a lemondottak és a már nem az övéi nélkül).
  List<DriverLeg> _inRange(DateTime from, DateTime to) => _legs.where((l) {
        if (l.status == 'REVOKED' || l.status == 'CANCELLED' || l.plannedStart == null) return false;
        final d = _day(l.plannedStart!.toLocal());
        return !d.isBefore(from) && d.isBefore(to);
      }).toList();

  Future<void> _openDay(DateTime day) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DayScreen(services: widget.services, day: day)));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final (from, to) = _range();
    final today = _day(DateTime.now());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Row(children: [
            Expanded(
              child: SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('Hét')), ButtonSegment(value: true, label: Text('Hónap'))],
                selected: {_month},
                onSelectionChanged: (s) {
                  setState(() => _month = s.first);
                  _load();
                },
              ),
            ),
            const SizedBox(width: 8),
            // A mai nap fuvarjai (és a naptár is visszaugrik a mai hétre / hónapra).
            OutlinedButton(
              onPressed: () {
                setState(() => _anchor = DateTime.now());
                _load();
                _openDay(_day(DateTime.now()));
              },
              child: const Text('Ma'),
            ),
          ]),
          Row(children: [
            IconButton(onPressed: () => _step(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Előző'),
            Expanded(child: Text(_title(), textAlign: TextAlign.center, style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700))),
            IconButton(onPressed: () => _step(1), icon: const Icon(Icons.chevron_right), tooltip: 'Következő'),
          ]),
          if (_loading) const LinearProgressIndicator(),
          _PeriodSummary(legs: _inRange(from, to), month: _month),
          if (!_month)
            for (var d = from; d.isBefore(to); d = d.add(const Duration(days: 1))) _WeekRow(day: d, today: d == today, legs: _on(d), onTap: () => _openDay(d))
          else
            _MonthGrid(from: from, to: to, today: today, legsOn: _on, onTap: _openDay),
        ],
      ),
    );
  }
}

/// Egy nap a héten: a dátum, a fuvarok száma és az időpontok rendszámmal.
class _WeekRow extends StatelessWidget {
  const _WeekRow({required this.day, required this.today, required this.legs, required this.onTap});
  final DateTime day;
  final bool today;
  final List<DriverLeg> legs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: today ? AppColors.tintBlue : null,
      shape: RoundedRectangleBorder(side: BorderSide(color: today ? AppColors.signalBlue : AppColors.rule), borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 64,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_weekdays[day.weekday - 1], style: const TextStyle(fontSize: 13, color: AppColors.ink600)),
                Text('${day.month}.${day.day}.', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ]),
            ),
            Expanded(
              child: legs.isEmpty
                  ? const Padding(padding: EdgeInsets.only(top: 10), child: Text('Nincs fuvar', style: TextStyle(color: AppColors.ink400)))
                  : Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final leg in legs)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: AppColors.sheet000, border: Border.all(color: AppColors.ruleFirm), borderRadius: BorderRadius.circular(4)),
                          child: Text('${_hm(leg.plannedStart!)} ${leg.registrationNumber}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                    ]),
            ),
            if (legs.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6, top: 8), child: Text('${legs.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.signalBlue))),
          ]),
        ),
      ),
    );
  }
}

/// A hónap rácsban: minden napon a fuvarok száma.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.from, required this.to, required this.today, required this.legsOn, required this.onTap});
  final DateTime from;
  final DateTime to;
  final DateTime today;
  final List<DriverLeg> Function(DateTime) legsOn;
  final void Function(DateTime) onTap;

  @override
  Widget build(BuildContext context) {
    final lead = from.weekday - 1;
    final days = to.difference(from).inDays;
    final cells = lead + days;
    return Column(children: [
      Row(children: [for (final w in _weekdaysShort) Expanded(child: Center(child: Text(w, style: const TextStyle(fontSize: 13, color: AppColors.ink600))))]),
      const SizedBox(height: 4),
      GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (var i = 0; i < cells; i++)
            if (i < lead)
              const SizedBox.shrink()
            else
              _MonthCell(day: from.add(Duration(days: i - lead)), today: today, count: legsOn(from.add(Duration(days: i - lead))).length, onTap: onTap),
        ],
      ),
    ]);
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({required this.day, required this.today, required this.count, required this.onTap});
  final DateTime day;
  final DateTime today;
  final int count;
  final void Function(DateTime) onTap;

  @override
  Widget build(BuildContext context) {
    final isToday = day == today;
    return Material(
      color: isToday ? AppColors.tintBlue : AppColors.sheet000,
      shape: RoundedRectangleBorder(side: BorderSide(color: isToday ? AppColors.signalBlue : AppColors.rule), borderRadius: BorderRadius.circular(6)),
      child: InkWell(
        onTap: () => onTap(day),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('${day.day}', style: TextStyle(fontWeight: isToday ? FontWeight.w700 : FontWeight.w500)),
          if (count > 0)
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: AppColors.signalBlue, borderRadius: BorderRadius.circular(8)),
              child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
    );
  }
}

/// Egy nap fuvarjai időrendben; egy fuvarra koppintva az adatlap nyílik.
class DayScreen extends StatefulWidget {
  const DayScreen({super.key, required this.services, required this.day});
  final AppServices services;
  final DateTime day;

  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  List<DriverLeg> _legs = const [];
  Map<String, LegSyncState> _states = const {};

  @override
  void initState() {
    super.initState();
    final d = widget.day;
    log.info('ui', 'Képernyő: Előjegyzés – ${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}. fuvarjai');
    _load();
  }

  Future<void> _load() async {
    final day = _day(widget.day);
    final legs = (await widget.services.local.cachedLegs())
        .where((l) => l.status != 'REVOKED' && l.plannedStart != null && _day(l.plannedStart!.toLocal()) == day)
        .toList()
      ..sort((a, b) => a.plannedStart!.compareTo(b.plannedStart!));
    final states = await widget.services.local.legSyncStates();
    if (mounted) setState(() { _legs = legs; _states = states; });
  }

  /// A nap utai megrendelésenként, a csoportok az első útjuk ideje szerint.
  List<List<DriverLeg>> _groups() {
    final byOrder = <String, List<DriverLeg>>{};
    for (final leg in _legs) {
      byOrder.putIfAbsent(leg.orderNo, () => []).add(leg);
    }
    return byOrder.values.map((g) => g..sort((a, b) => a.sequenceNo.compareTo(b.sequenceNo))).toList();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.day;
    return Scaffold(
      appBar: AppBar(title: Text('${_months[d.month - 1]} ${d.day}., ${_weekdays[d.weekday - 1]}')),
      body: _legs.isEmpty
          ? const Center(child: Text('Ezen a napon nincs fuvarod.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Megrendelésenként egy csoport: a bal oldali vonal köti össze az egy megrendeléshez
                // tartozó utakat (pl. körfuvar oda- és visszaútja), visszafogott, megrendelésenként azonos színnel.
                for (final (index, group) in _groups().indexed)
                  _OrderGroup(
                    legs: group,
                    color: _groupColors[index % _groupColors.length],
                    states: _states,
                    onOpen: (leg) async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
                      await _load();
                    },
                  ),
              ],
            ),
    );
  }
}

/// Visszafogott színek a megrendelés-csoportok vonalához (nem színes az egész lista).
const _groupColors = [Color(0xFF14547A), Color(0xFF6B7F8C), Color(0xFF2F6F5E), Color(0xFF8A6A3B), Color(0xFF5B4F7A)];

/// Egy megrendelés utai egy napon: bal oldalt egy vonal, alatta tömör sorok.
class _OrderGroup extends StatelessWidget {
  const _OrderGroup({required this.legs, required this.color, required this.states, required this.onOpen});
  final List<DriverLeg> legs;
  final Color color;
  final Map<String, LegSyncState> states;
  final Future<void> Function(DriverLeg leg) onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.sheet000,
        border: Border(left: BorderSide(color: color, width: 4), top: const BorderSide(color: AppColors.rule), right: const BorderSide(color: AppColors.rule), bottom: const BorderSide(color: AppColors.rule)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Text('${legs.first.registrationNumber} · ${legs.first.orderNo}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ),
        for (final (i, leg) in legs.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 10),
          InkWell(
            onTap: () => onOpen(leg),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 46,
                  child: Text(leg.plannedStart == null ? '–' : _hm(leg.plannedStart!),
                      style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${leg.fromPlace} → ${leg.toPlace}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                    Text('${leg.sequenceNo}. út · ${_statusText(leg.status)}${states[leg.legKey] == null ? '' : ' · szinkronra vár'}',
                        style: const TextStyle(fontSize: 13, color: AppColors.ink600)),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: AppColors.ink400),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  static String _statusText(String value) => switch (value) {
        'PLANNED' => 'tervezett',
        'ASSIGNED' => 'kiosztva',
        'IN_PROGRESS' => 'folyamatban',
        'COMPLETED_PENDING_SYNC' => 'kész, szinkronra vár',
        'COMPLETED' => 'teljesítve',
        'CANCELLED' => 'lemondva',
        _ => value,
      };
}

/// A hét / hónap összesítője: hány fuvar, ebből mennyi teljesítve és mennyi van hátra.
class _PeriodSummary extends StatelessWidget {
  const _PeriodSummary({required this.legs, required this.month});
  final List<DriverLeg> legs;
  final bool month;

  @override
  Widget build(BuildContext context) {
    final done = legs.where((l) => l.status == 'COMPLETED' || l.status == 'COMPLETED_PENDING_SYNC').length;
    final left = legs.length - done;
    Widget figure(String value, String label) => Expanded(
          child: Column(children: [
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.ink900)),
            Text(label, style: const TextStyle(fontSize: 13, color: AppColors.ink600)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: AppColors.sheet050, border: Border.all(color: AppColors.rule)),
      child: Column(children: [
        Text(month ? 'Ebben a hónapban' : 'Ezen a héten', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink600)),
        const SizedBox(height: 4),
        Row(children: [figure('${legs.length}', 'fuvar'), figure('$done', 'teljesítve'), figure('$left', 'hátra')]),
      ]),
    );
  }
}
