import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'home_screen.dart';
import 'leg_detail_screen.dart';
import '../../logging/app_log.dart';

const _months = ['jan.', 'febr.', 'márc.', 'ápr.', 'máj.', 'jún.', 'júl.', 'aug.', 'szept.', 'okt.', 'nov.', 'dec.'];
const _weekdays = ['hétfő', 'kedd', 'szerda', 'csütörtök', 'péntek', 'szombat', 'vasárnap'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// „Szabad fuvarok”: azok az utak, amelyeket a bejelentkezett sofőr felvehet és elvégezhet –
/// napokra bontva (a mai nap zölden, a későbbiek utána, a már elmúlt napokon el nem végzettek
/// a végén, „lejárt” jelöléssel). Egy autó útjai (pl. körfuvar oda- és visszaútja) egy keretben,
/// egymás alatt. Más sofőrök útjai itt nem látszanak.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.services, this.onClaimed});
  final AppServices services;
  final VoidCallback? onClaimed;

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> {
  /// A home_screen AppBar explicit frissítés gombja hívja.
  Future<void> refresh() => _load();
  final _plate = TextEditingController();
  /// A szerverről letöltött teljes lista; a rendszám-szűrő gépelés közben ebből szűr.
  List<DriverLeg> _results = const [];
  bool _loading = true;
  bool _busy = false;
  String? _message;

  /// A most felvett utak: a kártyán „Felvetted” jelzés, onnan megnyílik az adatlap.
  final Set<String> _claimed = {};

  @override
  void initState() {
    super.initState();
    log.info('ui', 'Képernyő: Szabad fuvarok');
    widget.services.work.addListener(_workChanged);
    _load();
  }

  @override
  void dispose() {
    widget.services.work.removeListener(_workChanged);
    _reloadTimer?.cancel();
    _plate.dispose();
    super.dispose();
  }

  /// Egy fuvar állapota változott (elindult, lezárult, felvetted): a lista magától frissül.
  Timer? _reloadTimer;
  void _workChanged() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && !_busy) _load();
    });
  }

  Future<void> _load() async {
    log.info('work', 'Szabad fuvarok lekérése');
    setState(() { _loading = true; _message = null; });
    try {
      final results = await widget.services.work.availableLegs(plate: '');
      log.info('work', 'Szabad fuvarok: ${results.length}');
      if (mounted) setState(() => _results = results);
    } catch (e) {
      log.warn('work', 'Szabad fuvarok nem töltődtek be', e);
      if (mounted) setState(() => _message = 'A szabad fuvarok listája internetkapcsolatot igényel. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDetail(DriverLeg leg) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: widget.services, legKey: leg.legKey)));
  }

  Future<void> _claim(DriverLeg leg) async {
    setState(() { _busy = true; _message = 'Offline munkacsomag letöltése…'; });
    try {
      await widget.services.work.claimAndDownload(leg);
      widget.onClaimed?.call();
      if (!mounted) return;
      setState(() { _message = null; _claimed.add(leg.legKey); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Felvetted: a fuvar a Fuvarjaim között van, offline is elérhető.')));
      // Sikeres felvétel után a Fuvarjaim nézet jön (ott a felvett fuvar).
      HomeScreen.tabRequest.value = 0;
    } catch (e) {
      log.warn('work', 'Fuvar felvétele nem sikerült: ${leg.legKey}', e);
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A rendszám-szűrő (gépelés közben): kötőjel, szóköz, kis-nagybetű nem számít.
  bool _matches(DriverLeg leg) {
    final plate = _plate.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return plate.isEmpty || leg.registrationNumber.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').contains(plate);
  }

  /// Egy szabad út kártyája: „Felveszem”, vagy ha előbb az előző útnak kell teljesülnie, az.
  Widget _card(DriverLeg leg, {required bool today}) {
    final claimed = _claimed.contains(leg.legKey);
    return LegCard(
      leg: leg,
      color: claimed ? AppColors.tintGreen : (today ? null : AppColors.sheet050),
      borderColor: claimed ? AppColors.signalGreen : null,
      onTap: claimed ? () => _openDetail(leg) : () {},
      showStatus: false,
      trailing: claimed
          ? FilledButton.icon(
              onPressed: () => _openDetail(leg),
              style: FilledButton.styleFrom(backgroundColor: AppColors.signalGreen),
              icon: const Icon(Icons.check_circle),
              label: const Text('Felvetted – megnyitás'),
            )
          : leg.waitsForPreviousLeg
              ? const Flexible(
                  child: Text('Előbb az előző útnak kell teljesülnie',
                      textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: AppColors.ink600)),
                )
              : FilledButton(onPressed: _busy ? null : () => _claim(leg), child: const Text('Felveszem')),
    );
  }

  /// A lista napokra bontva. Egy autó útjai egy csoport (a csoport az első útja napjánál áll);
  /// a mai nap elöl, utána a későbbi napok sorban, végül a már elmúlt napok (legutóbbi elöl).
  List<Widget> _days(List<DriverLeg> legs) {
    final groups = <String, List<DriverLeg>>{};
    for (final leg in legs) {
      groups.putIfAbsent(leg.orderVehicleId, () => []).add(leg);
    }
    final byDay = <DateTime?, List<List<DriverLeg>>>{};
    for (final group in groups.values) {
      group.sort((a, b) => a.sequenceNo.compareTo(b.sequenceNo));
      final start = group.map((l) => l.plannedStart).whereType<DateTime>().fold<DateTime?>(null, (m, t) => m == null || t.isBefore(m) ? t : m);
      byDay.putIfAbsent(start == null ? null : _day(start.toLocal()), () => []).add(group);
    }
    DateTime? firstTime(List<DriverLeg> g) => g.first.plannedStart;
    for (final list in byDay.values) {
      list.sort((a, b) {
        final x = firstTime(a), y = firstTime(b);
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return x.compareTo(y);
      });
    }
    final today = _day(DateTime.now());
    final days = byDay.keys.whereType<DateTime>().toList();
    final upcoming = days.where((d) => !d.isBefore(today)).toList()..sort();
    final past = days.where((d) => d.isBefore(today)).toList()..sort((a, b) => b.compareTo(a));

    List<Widget> section(DateTime? day) {
      final groupsOfDay = byDay[day]!;
      final count = groupsOfDay.fold<int>(0, (n, g) => n + g.length);
      final isToday = day == today;
      final isPast = day != null && day.isBefore(today);
      final title = day == null
          ? 'IDŐPONT NÉLKÜL'
          : isToday
              ? 'MA – ${_label(day)}'
              : isPast
                  ? 'LEJÁRT – ${_label(day)}'
                  : _label(day).toUpperCase();
      return [
        _DayBand(
          text: '$title  ·  $count út',
          color: isToday ? AppColors.signalGreen : isPast ? AppColors.signalAmber : AppColors.ink600,
          note: isPast ? 'Korábbi napra szólt, de senki nem végezte el.' : null,
        ),
        for (final group in groupsOfDay)
          group.length > 1
              ? _VehicleGroup(legs: group, card: (leg) => _card(leg, today: isToday))
              : _card(group.first, today: isToday),
      ];
    }

    return [
      for (final day in upcoming) ...section(day),
      if (byDay.containsKey(null)) ...section(null),
      for (final day in past) ...section(day),
    ];
  }

  static String _label(DateTime day) => '${_months[day.month - 1]} ${day.day}., ${_weekdays[day.weekday - 1]}';

  @override
  Widget build(BuildContext context) {
    final shown = _results.where(_matches).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        // Rövid listánál is le lehessen húzni a frissítéshez.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                // Gépelés közben azonnal szűr (a letöltött listában, hálózat nélkül is).
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Szűrés rendszámra',
                  hintText: 'ABC-123',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _plate.text.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), tooltip: 'Szűrő törlése', onPressed: () => setState(_plate.clear)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.outlined(
              onPressed: _loading || _busy ? null : _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Frissítés',
            ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Ezeket az utakat felveheted magadra; a felvett út a Fuvarjaim között jelenik meg.',
                style: TextStyle(fontSize: 13, color: AppColors.ink600)),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!, style: const TextStyle(color: AppColors.signalRed)),
            ),
          if (!_loading && _message == null && _results.isNotEmpty && shown.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text('Erre a rendszámra nincs találat.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
            ),
          if (!_loading && _message == null && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text(
                'Nincs jelenleg felvehető szabad fuvar. Ez azt is jelentheti, hogy a sofőrszolgálatod még nem engedélyezte a sofőr önkiosztást — kérdezd meg az ügyintézőt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
              ),
            ),
          ..._days(shown),
        ],
      ),
    );
  }
}

/// A nap fejléce: a mai nap zöld, a későbbiek szürke, a lejártak borostyán színű.
class _DayBand extends StatelessWidget {
  const _DayBand({required this.text, required this.color, this.note});
  final String text;
  final Color color;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
            child: Text(text, style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Colors.white, fontSize: 15)),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(note!, style: const TextStyle(fontSize: 13, color: AppColors.ink600)),
            ),
        ]),
      );
}

/// Egy autó egymást követő útjai (pl. körfuvar oda- és visszaútja) egy keretben: bal oldalt
/// egy vonal köti össze őket, fölöttük a rendszám és hogy hány útból áll.
class _VehicleGroup extends StatelessWidget {
  const _VehicleGroup({required this.legs, required this.card});
  final List<DriverLeg> legs;
  final Widget Function(DriverLeg leg) card;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.only(left: 10),
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: AppColors.signalBlue, width: 4))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${legs.first.registrationNumber} · ${legs.any((l) => l.isOutbound || l.isReturn || l.startsMidRoute) ? 'körfuvar' : 'több út'} · ${legs.length} út',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.signalBlue, letterSpacing: 0.3),
            ),
          ),
          for (final leg in legs) card(leg),
        ]),
      );
}
