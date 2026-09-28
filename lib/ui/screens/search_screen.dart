import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../models/trip_rules.dart';
import '../../services/app_services.dart';
import '../theme.dart';
import '../widgets/leg_card.dart';
import 'leg_detail_screen.dart';
import '../../logging/app_log.dart';

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

  /// A most felvett utak: a kártyán „Felvetted” jelzés, nem nyílik meg az adatlap.
  final Set<String> _claimed = {};

  /// „Szabad” (felvehető utak) vagy „Nyitott” (minden nyitott út, és hogy kinél van).
  bool _board = false;
  List<OpenLeg> _open = const [];

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
    if (_board) return _loadBoard();
    log.info('work', 'Szabad fuvarok lekérése');
    setState(() { _loading = true; _message = null; });
    try {
      final results = await widget.services.work.availableLegs(plate: '');
      log.info('work', 'Szabad fuvarok: ${results.length}');
      // Egy autó útjai egymás után (körfuvarnál az odaút elöl), az autók indulás szerint.
      final grouped = groupByVehicle(results, (a, b) {
        final x = a.plannedStart, y = b.plannedStart;
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return x.compareTo(y);
      });
      if (mounted) setState(() => _results = grouped);
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

  Future<void> _loadBoard() async {
    setState(() { _loading = true; _message = null; });
    try {
      final rows = await widget.services.work.openLegs();
      if (mounted) setState(() => _open = rows);
    } catch (e) {
      log.warn('work', 'A nyitott fuvarok nem töltődtek be', e);
      if (mounted) setState(() => _message = 'A nyitott fuvarok listája internetkapcsolatot igényel. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// „Átveszem”: megerősítés után, hálózattal. A másik sofőr értesítést kap.
  Future<void> _takeOver(OpenLeg row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Átveszed ezt a fuvart?'),
        content: Text('${row.leg.registrationNumber} · ${row.leg.fromPlace} → ${row.leg.toPlace}\n\n'
            'Most ${row.driverName ?? 'egy másik sofőr'} viszi. Ha átveszed, lekerül róla (értesítést kap), és a tiéd lesz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Átveszem')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() { _busy = true; _message = 'Offline munkacsomag letöltése…'; });
    try {
      await widget.services.work.takeOverAndDownload(row.leg);
      widget.onClaimed?.call();
      if (!mounted) return;
      setState(() { _message = null; _claimed.add(row.leg.legKey); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Átvetted: a fuvar a Munkáid között van.')));
    } catch (e) {
      log.warn('work', 'Az átvétel nem sikerült: ${row.leg.legKey}', e);
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A nyitott fuvar sora: jól látható, hogy van-e már sofőrje (és kié), és mit tehetsz vele.
  Widget _boardTrailing(OpenLeg row) {
    if (_claimed.contains(row.leg.legKey) || row.mine) {
      return const _AssignChip(text: 'A TIÉD', color: AppColors.signalGreen, filled: true);
    }
    final assigned = row.driverName != null;
    return Flexible(
      child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 6, children: [
        assigned
            ? _AssignChip(text: 'KIOSZTVA: ${row.driverName}', color: AppColors.signalBlue)
            : const _AssignChip(text: 'NINCS SOFŐRJE', color: AppColors.signalAmber),
        if (row.canTakeOver) OutlinedButton(onPressed: _busy ? null : () => _takeOver(row), child: const Text('Átveszem')),
        if (!assigned && row.canClaim) FilledButton(onPressed: _busy ? null : () => _claim(row.leg), child: const Text('Felveszem')),
      ]),
    );
  }

  /// A rendszám-szűrő (gépelés közben): kötőjel, szóköz, kis-nagybetű nem számít.
  bool _matches(DriverLeg leg) {
    final plate = _plate.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return plate.isEmpty || leg.registrationNumber.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').contains(plate);
  }

  Widget _freeCard(DriverLeg leg, {Color? color}) => LegCard(
        leg: leg,
        color: _mineColor(leg, _claimed.contains(leg.legKey)) ?? color,
        borderColor: _mineBorder(leg, _claimed.contains(leg.legKey)),
        // A felvett fuvar innen is megnyílik (és indítható); a még szabad nem a sofőré.
        onTap: _claimed.contains(leg.legKey) ? () => _openDetail(leg) : () {},
        showStatus: false,
        // Az utak sorban mennek: az előző út teljesülése előtt ez nem vehető fel.
        trailing: _claimed.contains(leg.legKey)
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

  /// A sofőr saját fuvarjai színnel: amivel éppen úton van piros, ami rá van osztva zöld.
  Color? _mineColor(DriverLeg leg, bool mine) {
    if (!mine) return null;
    return leg.status == 'IN_PROGRESS' ? AppColors.tintRed : AppColors.tintGreen;
  }

  Color? _mineBorder(DriverLeg leg, bool mine) {
    if (!mine) return null;
    return leg.status == 'IN_PROGRESS' ? AppColors.signalRed : AppColors.signalGreen;
  }

  Widget _boardCard(OpenLeg row, {Color? color}) => LegCard(
        leg: row.leg,
        color: _mineColor(row.leg, row.mine || _claimed.contains(row.leg.legKey)) ?? color,
        borderColor: _mineBorder(row.leg, row.mine || _claimed.contains(row.leg.legKey)),
        onTap: (row.mine || _claimed.contains(row.leg.legKey)) ? () => _openDetail(row.leg) : () {},
        trailing: _boardTrailing(row),
      );

  /// Mai (és lekésett) fuvarok elöl; a későbbi napra szólók külön, színes elválasztó alatt, szürke kártyán.
  List<Widget> _sections<T>(List<T> items, DriverLeg Function(T) legOf, Widget Function(T, {Color? color}) card) {
    final now = DateTime.now();
    final today = items.where((i) => !plannedForLaterDay(legOf(i).plannedStart, now)).toList();
    final later = items.where((i) => plannedForLaterDay(legOf(i).plannedStart, now)).toList();
    return [
      if (today.isNotEmpty) ...[
        _SectionBand(text: 'MAI FUVAROK (${today.length})', color: AppColors.signalGreen),
        for (final item in today) card(item),
      ],
      if (later.isNotEmpty) ...[
        _SectionBand(text: 'ELŐJEGYZETT – NEM MAI FUVAROK (${later.length})', color: AppColors.ink600),
        for (final item in later) card(item, color: AppColors.sheet100),
      ],
    ];
  }

  Future<void> _claim(DriverLeg leg) async {
    setState(() { _busy = true; _message = 'Offline munkacsomag letöltése…'; });
    try {
      await widget.services.work.claimAndDownload(leg);
      widget.onClaimed?.call();
      if (!mounted) return;
      setState(() { _message = null; _claimed.add(leg.legKey); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Felvetted: a fuvar a Munkáid között van, offline is elérhető.')));
    } catch (e) {
      log.warn('work', 'Fuvar felvétele nem sikerült: ${leg.legKey}', e);
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.playlist_add_check), label: Text('Szabad')),
                ButtonSegment(value: true, icon: Icon(Icons.groups_outlined), label: Text('Nyitott fuvarok')),
              ],
              selected: {_board},
              onSelectionChanged: (selection) {
                setState(() => _board = selection.first);
                _load();
              },
            ),
          ),
          const _ColorLegend(),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!, style: const TextStyle(color: AppColors.signalRed)),
            ),
          if (_board) ...[
            if (!_loading && _message == null && _open.where((r) => _matches(r.leg)).isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Text(_open.isEmpty ? 'Nincs nyitott fuvar a sofőrszolgálatodnál.' : 'Erre a rendszámra nincs találat.', textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
              ),
            ..._sections<OpenLeg>(_open.where((r) => _matches(r.leg)).toList(), (r) => r.leg, _boardCard),
          ],
          if (!_board && !_loading && _message == null && _results.isNotEmpty && _results.where(_matches).isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text('Erre a rendszámra nincs találat.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
            ),
          if (!_board && !_loading && _message == null && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text(
                'Nincs jelenleg felvehető szabad fuvar. Ez azt is jelentheti, hogy a sofőrszolgálatod még nem engedélyezte a sofőr önkiosztást — kérdezd meg az ügyintézőt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
              ),
            ),
          if (!_board) ..._sections<DriverLeg>(_results.where(_matches).toList(), (l) => l, _freeCard),
        ],
      ),
    );
  }
}

/// Színes elválasztó sáv a lista szakaszai fölött (mai / nem mai).
class _SectionBand extends StatelessWidget {
  const _SectionBand({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 16, bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Colors.white, fontSize: 15)),
      );
}

/// „KIOSZTVA: Név” / „NINCS SOFŐRJE” / „A TIÉD”: a fuvar gazdája egy pillantásra.
class _AssignChip extends StatelessWidget {
  const _AssignChip({required this.text, required this.color, this.filled = false});
  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: filled ? color : Colors.white,
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 14, color: filled ? Colors.white : color)),
      );
}

/// A kártyák színeinek magyarázata a lista tetején.
class _ColorLegend extends StatelessWidget {
  const _ColorLegend();

  static Widget _item(Color fill, Color border, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 18, height: 18, decoration: BoxDecoration(color: fill, border: Border.all(color: border, width: 1.5), borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 13, color: AppColors.ink900)),
      ]);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(spacing: 14, runSpacing: 8, children: [
          _item(AppColors.tintRed, AppColors.signalRed, 'Éppen úton vagy vele'),
          _item(AppColors.tintGreen, AppColors.signalGreen, 'Rád van osztva'),
          _item(AppColors.sheet000, AppColors.ruleFirm, 'Mai, nem a tiéd'),
          _item(AppColors.sheet100, AppColors.ruleFirm, 'Nem mai, nem a tiéd'),
        ]),
      );
}
