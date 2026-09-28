import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/models/models.dart';
import 'package:fleet_driver_app/models/trip_rules.dart';

DriverLeg _leg(String key, String status, DateTime? start) => DriverLeg.fromJson({
      'legKey': key,
      'status': status,
      'sequenceNo': 1,
      'orderVehicleId': 'ov-$key',
      'registrationNumber': 'ABC-$key',
      'orderNo': 'FO-1',
      'serviceOrgId': '2',
      'fromAddress': 'A',
      'toAddress': 'B',
      'plannedStart': start?.toUtc().toIso8601String(),
    });

void main() {
  final now = DateTime(2026, 9, 28, 9, 0);

  test('későbbi napra tervezett út ma nem indítható; ma este és a lekésett igen', () {
    expect(plannedForLaterDay(DateTime(2026, 9, 30, 8), now), isTrue);
    expect(plannedForLaterDay(DateTime(2026, 9, 29, 0, 5), now), isTrue);
    expect(plannedForLaterDay(DateTime(2026, 9, 28, 23, 30), now), isFalse);
    expect(plannedForLaterDay(DateTime(2026, 9, 27, 8), now), isFalse);
    expect(plannedForLaterDay(null, now), isFalse);
  });

  test('a mai munka: ami fut elöl, aztán időrendben a mai és a lekésett; holnapi és kész nincs benne', () {
    final legs = [
      _leg('holnap', 'ASSIGNED', DateTime(2026, 9, 29, 8)),
      _leg('delutan', 'ASSIGNED', DateTime(2026, 9, 28, 15)),
      _leg('lekesett', 'ASSIGNED', DateTime(2026, 9, 27, 10)),
      _leg('kesz', 'COMPLETED', DateTime(2026, 9, 28, 7)),
      _leg('uton', 'IN_PROGRESS', DateTime(2026, 9, 28, 16)),
    ];
    expect(todaysWork(legs, now).map((l) => l.legKey), ['uton', 'lekesett', 'delutan']);
    expect(nextLaterTrip(legs, now)?.legKey, 'holnap');
    expect(isOverdue(legs[2], now), isTrue);
    expect(isOverdue(legs[1], now), isFalse);
  });

  test('egyszerre egy út fut: a másik indítását ez tiltja', () {
    final legs = [_leg('a', 'IN_PROGRESS', null), _leg('b', 'ASSIGNED', null)];
    expect(runningLeg(legs, except: 'b')?.legKey, 'a');
    expect(runningLeg(legs, except: 'a'), isNull);
  });
}
