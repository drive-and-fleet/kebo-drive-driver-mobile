import 'package:flutter/material.dart';

import '../../models/models.dart';
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
    _load();
  }

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_board) return _loadBoard();
    log.info('work', 'Szabad fuvarok lekérése${_plate.text.trim().isEmpty ? '' : ' (rendszám: ${_plate.text.trim()})'}');
    setState(() { _loading = true; _message = null; });
    try {
      final results = await widget.services.work.availableLegs(plate: _plate.text.trim());
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
      final plate = _plate.text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final rows = await widget.services.work.openLegs();
      final shown = plate.isEmpty ? rows : rows.where((r) => r.leg.registrationNumber.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').contains(plate)).toList();
      if (mounted) setState(() => _open = shown);
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

  Widget _boardTrailing(OpenLeg row) {
    const muted = TextStyle(fontSize: 13, color: AppColors.ink600);
    if (_claimed.contains(row.leg.legKey) || row.mine) {
      return const Text('A tiéd', style: TextStyle(color: AppColors.signalGreen, fontWeight: FontWeight.w700));
    }
    if (row.canTakeOver) {
      // A kártya alsó sorában: a név rövidülhet, a gomb mindig teljes.
      return Flexible(
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Flexible(child: Text(row.driverName ?? '', style: muted, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _busy ? null : () => _takeOver(row), child: const Text('Átveszem')),
        ]),
      );
    }
    if (row.canClaim) return FilledButton(onPressed: _busy ? null : () => _claim(row.leg), child: const Text('Felveszem'));
    return Flexible(
      child: Text(row.driverName == null ? 'Szabad' : 'Nála: ${row.driverName}', textAlign: TextAlign.right, style: muted),
    );
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
                decoration: const InputDecoration(labelText: 'Szűrés rendszámra', hintText: 'ABC-123'),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: _busy ? null : _load, child: const Text('Szűrés')),
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
                ButtonSegment(value: true, icon: Icon(Icons.groups_outlined), label: Text('Nyitott (ki viszi)')),
              ],
              selected: {_board},
              onSelectionChanged: (selection) {
                setState(() => _board = selection.first);
                _load();
              },
            ),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!, style: const TextStyle(color: AppColors.signalRed)),
            ),
          if (_board) ...[
            if (!_loading && _message == null && _open.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Text('Nincs nyitott fuvar a sofőrszolgálatodnál.', textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary)),
              ),
            const SizedBox(height: 12),
            for (final row in _open)
              LegCard(leg: row.leg, onTap: (row.mine || _claimed.contains(row.leg.legKey)) ? () => _openDetail(row.leg) : () {}, trailing: _boardTrailing(row)),
          ],
          if (!_board && !_loading && _message == null && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Text(
                'Nincs jelenleg felvehető szabad fuvar. Ez azt is jelentheti, hogy a sofőrszolgálatod még nem engedélyezte a sofőr önkiosztást — kérdezd meg az ügyintézőt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.ink600, fontSize: AppText.secondary),
              ),
            ),
          if (!_board) const SizedBox(height: 12),
          if (!_board)
          for (final leg in _results)
            LegCard(
              leg: leg,
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
            ),
        ],
      ),
    );
  }
}
