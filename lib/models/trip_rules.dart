import 'models.dart';

/// A sofőr napja: mit csinálhat most, és mi vár rá. Tiszta függvények (tesztelhetők),
/// a „Ma” képernyő és az indítás tiltása is ezekből dolgozik.

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// Későbbi napra tervezett út: ma még nem vehető át (előbb az időpontját kell módosítani).
bool plannedForLaterDay(DateTime? plannedStart, DateTime now) =>
    plannedStart != null && _day(plannedStart.toLocal()).isAfter(_day(now));

/// Korábbi napra tervezett, de még át nem vett út (lekésett): ma is elvihető.
bool isOverdue(DriverLeg leg, DateTime now) =>
    leg.status == 'ASSIGNED' && leg.plannedStart != null && _day(leg.plannedStart!.toLocal()).isBefore(_day(now));

/// Az az út, amelyikkel a sofőr éppen úton van (egyszerre legfeljebb egy lehet).
DriverLeg? runningLeg(Iterable<DriverLeg> legs, {String? except}) {
  for (final leg in legs) {
    if (leg.status == 'IN_PROGRESS' && leg.legKey != except) return leg;
  }
  return null;
}

int _byStart(DriverLeg a, DriverLeg b) {
  final x = a.plannedStart, y = b.plannedStart;
  if (x == null && y == null) return a.sequenceNo.compareTo(b.sequenceNo);
  if (x == null) return 1;
  if (y == null) return -1;
  final c = x.compareTo(y);
  return c != 0 ? c : a.sequenceNo.compareTo(b.sequenceNo);
}

/// A mai teendő utak időrendben: ami fut, a mára tervezett, a lekésett és az
/// időpont nélküli. Későbbi napra tervezett és kész út nincs benne.
List<DriverLeg> todaysWork(Iterable<DriverLeg> legs, DateTime now) {
  final list = legs.where((l) {
    if (l.status == 'IN_PROGRESS') return true;
    if (l.status != 'ASSIGNED') return false;
    return !plannedForLaterDay(l.plannedStart, now);
  }).toList()
    // Ami fut, az mindig elöl; utána időrendben.
    ..sort((a, b) {
      final running = (a.status == 'IN_PROGRESS' ? 0 : 1).compareTo(b.status == 'IN_PROGRESS' ? 0 : 1);
      return running != 0 ? running : _byStart(a, b);
    });
  return list;
}

/// A következő, későbbi napra tervezett út (a „Ma” alján: mikor lesz a következő munka).
DriverLeg? nextLaterTrip(Iterable<DriverLeg> legs, DateTime now) {
  final later = legs.where((l) => l.status == 'ASSIGNED' && plannedForLaterDay(l.plannedStart, now)).toList()..sort(_byStart);
  return later.isEmpty ? null : later.first;
}
