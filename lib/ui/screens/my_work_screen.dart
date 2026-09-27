import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';
import '../../logging/app_log.dart';

/// Munkáim, három nézetben:
/// - **Ma**: a mai munka – ami most folyik, ami még hátravan, és ami már kész;
/// - **Időszak**: nap / hét / hónap lapozva, mint a webes Előjegyzések, napok szerint;
/// - **Teljesített**: az elmúlt 30 / 90 / 365 nap teljesített fuvarjai.
/// A lista mindig a telefonról jön (local-first); a frissítés a szerverről tölti.
class MyWorkScreen extends StatefulWidget {
  const MyWorkScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<MyWorkScreen> createState() => MyWorkScreenState();
}

enum _WorkView { today, period, completed }

enum _Span { day, week, month }

class MyWorkScreenState extends State<MyWorkScreen> {
  /// A fejléc frissítés gombja hívja.
  Future<void> refresh() => _load(refresh: true);

  List<DriverLeg> _legs = const [];
  List<DriverLeg> _completed = const [];
  Map<String, LegSyncState> _syncStates = const {};
  bool _loading = true;
  String? _message;

  _WorkView _view = _WorkView.today;
  _Span _span = _Span.week;
  DateTime _anchor = DateTime.now();
  int _days = 30;
  bool _completedFromServer = true;

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Munkáim');
    widget.services.sync.addListener(_refreshLocal);
    widget.services.work.addListener(_refreshLocal);
    _load();
  }

  @override
  void dispose() {
    widget.services.sync.removeListener(_refreshLocal);
    widget.services.work.removeListener(_refreshLocal);
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final legs = await widget.services.local.cachedLegs();
    final states = await widget.services.local.legSyncStates();
    if (mounted) setState(() { _legs = legs; _syncStates = states; });
  }

  Future<void> _load({bool refresh = true}) async {
    setState(() => _loading = true);
    try {
      if (_view == _WorkView.completed) {
        final result = await widget.services.work.completedWork(_days);
        if (mounted) setState(() { _completed = result.legs; _completedFromServer = result.fromServer; });
      } else {
        if (refresh) log.info('ui', 'Munkáim frissítése');
        final legs = await widget.services.work.myWork(refreshOnline: refresh);
        if (mounted) setState(() => _legs = legs);
        // Múltbeli időszaknál a teljesítettek is kellenek (a telefonra töltve).
        final range = _range();
        if (_view == _WorkView.period && range.$1.isBefore(DateTime.now())) {
          final days = DateTime.now().difference(range.$1).inDays + 1;
          await widget.services.work.completedWork(days.clamp(1, 400));
          await _refreshLocal();
        }
      }
      final states = await widget.services.local.legSyncStates();
      if (mounted) setState(() { _syncStates = states; _message = null; });
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── időszak ──

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  /// [from, to) a választott nézetben; a hét hétfőn kezdődik.
  (DateTime, DateTime) _range() {
    final a = _day(_anchor);
    switch (_span) {
      case _Span.day:
        return (a, a.add(const Duration(days: 1)));
      case _Span.week:
        final from = a.subtract(Duration(days: a.weekday - 1));
        return (from, from.add(const Duration(days: 7)));
      case _Span.month:
        return (DateTime(a.year, a.month), DateTime(a.year, a.month + 1));
    }
  }

  void _step(int direction) {
    setState(() {
      _anchor = switch (_span) {
        _Span.day => _anchor.add(Duration(days: direction)),
        _Span.week => _anchor.add(Duration(days: 7 * direction)),
        _Span.month => DateTime(_anchor.year, _anchor.month + direction, 1),
      };
    });
    _load(refresh: false);
  }

  static const _months = ['január', 'február', 'március', 'április', 'május', 'június', 'július', 'augusztus', 'szeptember', 'október', 'november', 'december'];
  static const _weekdays = ['hétfő', 'kedd', 'szerda', 'csütörtök', 'péntek', 'szombat', 'vasárnap'];

  String _rangeLabel() {
    final (from, to) = _range();
    switch (_span) {
      case _Span.day:
        return '${from.year}. ${_months[from.month - 1]} ${from.day}., ${_weekdays[from.weekday - 1]}';
      case _Span.week:
        final last = to.subtract(const Duration(days: 1));
        return '${_months[from.month - 1]} ${from.day}. – ${from.month == last.month ? '' : '${_months[last.month - 1]} '}${last.day}.';
      case _Span.month:
        return '${from.year}. ${_months[from.month - 1]}';
    }
  }

  static int _byStart(DriverLeg a, DriverLeg b) {
    final x = a.plannedStart, y = b.plannedStart;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  static const _done = {'COMPLETED', 'COMPLETED_PENDING_SYNC'};

  bool _inRange(DriverLeg leg, DateTime from, DateTime to) {
    final t = leg.plannedStart?.toLocal();
    return t != null && !t.isBefore(from) && t.isBefore(to);
  }

  Future<void> _open(DriverLeg leg) async {
    log.info('ui', 'Fuvar megnyitva: ${leg.legKey} (${leg.orderNo} #${leg.sequenceNo}, ${leg.status})');
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
    await _load(refresh: false);
  }

  Widget _card(DriverLeg leg) => LegCard(leg: leg, syncState: _syncStates[leg.legKey], onTap: () => _open(leg));

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(text, style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.ink900)),
      );

  List<Widget> _todayView() {
    final today = _day(DateTime.now());
    final tomorrow = today.add(const Duration(days: 1));
    final running = _legs.where((l) => l.status == 'IN_PROGRESS').toList()..sort(_byStart);
    final open = _legs.where((l) => l.status == 'ASSIGNED' && _inRange(l, today, tomorrow)).toList()..sort(_byStart);
    final undated = _legs.where((l) => l.status == 'ASSIGNED' && l.plannedStart == null).toList();
    final overdue = _legs.where((l) => l.status == 'ASSIGNED' && l.plannedStart != null && l.plannedStart!.toLocal().isBefore(today)).toList()..sort(_byStart);
    final done = _legs.where((l) => _done.contains(l.status) && _inRange(l, today, tomorrow)).toList()..sort(_byStart);
    if (running.isEmpty && open.isEmpty && undated.isEmpty && overdue.isEmpty && done.isEmpty) {
      return [_empty(Icons.today, 'Mára nincs fuvarod. Az „Időszak” nézetben látod a következő napokat.')];
    }
    return [
      if (running.isNotEmpty) ...[_heading('Folyamatban'), ...running.map(_card)],
      if (overdue.isNotEmpty) ...[_heading('Korábbra tervezve, még el nem indítva'), ...overdue.map(_card)],
      if (open.isNotEmpty) ...[_heading('Ma még hátravan (${open.length})'), ...open.map(_card)],
      if (undated.isNotEmpty) ...[_heading('Időpont nélkül'), ...undated.map(_card)],
      if (done.isNotEmpty) ...[_heading('Ma teljesítve (${done.length})'), ...done.map(_card)],
    ];
  }

  List<Widget> _periodView() {
    final (from, to) = _range();
    final legs = _legs.where((l) => l.status != 'REVOKED' && _inRange(l, from, to)).toList()..sort(_byStart);
    final out = <Widget>[
      Row(children: [
        IconButton(onPressed: () => _step(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Előző'),
        Expanded(child: Text(_rangeLabel(), textAlign: TextAlign.center, style: const TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w600))),
        IconButton(onPressed: () => _step(1), icon: const Icon(Icons.chevron_right), tooltip: 'Következő'),
      ]),
      Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
        for (final span in _Span.values)
          ChoiceChip(
            label: Text(switch (span) { _Span.day => 'Nap', _Span.week => 'Hét', _Span.month => 'Hónap' }),
            selected: _span == span,
            onSelected: (_) {
              setState(() => _span = span);
              _load(refresh: false);
            },
          ),
        ActionChip(
          label: const Text('Ma'),
          onPressed: () {
            setState(() => _anchor = DateTime.now());
            _load(refresh: false);
          },
        ),
      ]),
    ];
    if (legs.isEmpty) return [...out, _empty(Icons.event_available, 'Ebben az időszakban nincs fuvarod.')];
    DateTime? current;
    for (final leg in legs) {
      final d = _day(leg.plannedStart!.toLocal());
      if (current != d) {
        current = d;
        out.add(_heading('${_months[d.month - 1]} ${d.day}., ${_weekdays[d.weekday - 1]}'));
      }
      out.add(_card(leg));
    }
    return out;
  }

  List<Widget> _completedView() => [
        Wrap(spacing: 8, children: [
          for (final days in const [30, 90, 365])
            ChoiceChip(
              label: Text(days == 365 ? 'Elmúlt 1 év' : 'Elmúlt $days nap'),
              selected: _days == days,
              onSelected: (_) {
                if (days == _days) return;
                setState(() => _days = days);
                _load();
              },
            ),
        ]),
        if (!_loading && !_completedFromServer)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Nincs kapcsolat a szerverrel: csak a telefonon tárolt teljesített fuvarok látszanak.'),
          ),
        const SizedBox(height: 8),
        if (!_loading && _completed.isEmpty) _empty(Icons.task_alt, 'Ebben az időszakban nincs teljesített fuvarod.'),
        ..._completed.map(_card),
      ];

  Widget _empty(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 20),
        child: Column(children: [
          Icon(icon, size: 56, color: AppColors.ink600),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_message != null) Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SegmentedButton<_WorkView>(
              segments: const [
                ButtonSegment(value: _WorkView.today, icon: Icon(Icons.today), label: Text('Ma')),
                ButtonSegment(value: _WorkView.period, icon: Icon(Icons.date_range), label: Text('Időszak')),
                ButtonSegment(value: _WorkView.completed, icon: Icon(Icons.task_alt), label: Text('Teljesített')),
              ],
              selected: {_view},
              onSelectionChanged: (selection) {
                final view = selection.first;
                if (view == _view) return;
                log.info('ui', 'Munkáim nézet: ${view.name}');
                setState(() => _view = view);
                _load(refresh: false);
              },
            ),
          ),
          ...switch (_view) {
            _WorkView.today => _todayView(),
            _WorkView.period => _periodView(),
            _WorkView.completed => _completedView(),
          },
        ],
      ),
    );
  }
}
