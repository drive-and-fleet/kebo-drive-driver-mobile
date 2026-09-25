import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/models/models.dart';

Map<String, dynamic> _leg({required int seq, String? from, String? to}) => {
      'legKey': 'LK-$seq',
      'status': 'ASSIGNED',
      'sequenceNo': seq,
      'orderVehicleId': 'ov1',
      'registrationNumber': 'ABC-123',
      'orderNo': 'FO-1',
      'serviceOrgId': '2',
      'fromAddress': 'A',
      'toAddress': 'B',
      'fromStopType': from,
      'toStopType': to,
    };

void main() {
  test('a várakozó megállóba érkező út a körfuvar odaútja', () {
    final leg = DriverLeg.fromJson(_leg(seq: 1, from: 'PICKUP', to: 'WAIT'));
    expect(leg.isOutbound, isTrue);
    expect(leg.isReturn, isFalse);
  });

  test('a várakozó megállóból induló út a visszaút', () {
    final leg = DriverLeg.fromJson(_leg(seq: 2, from: 'WAIT', to: 'DROPOFF'));
    expect(leg.isReturn, isTrue);
    expect(leg.isOutbound, isFalse);
  });

  test('sima fuvar és régi (típus nélküli) adat nem körfuvar', () {
    expect(DriverLeg.fromJson(_leg(seq: 1, from: 'PICKUP', to: 'DROPOFF')).isOutbound, isFalse);
    final old = DriverLeg.fromJson(_leg(seq: 1));
    expect(old.isOutbound || old.isReturn, isFalse);
  });

  test('a megállótípus és a neve megmarad a helyi gyorsítótárban és az állapotváltáskor', () {
    final leg = DriverLeg.fromJson({..._leg(seq: 1, from: 'PICKUP', to: 'WAIT'), 'toStopTypeName': 'Szerviz (várakozással)'});
    final cached = DriverLeg.fromCacheMap(leg.toCacheMap());
    expect(cached.toStopType, 'WAIT');
    expect(cached.toStopTypeName, 'Szerviz (várakozással)');
    expect(cached.copyWithStatus('IN_PROGRESS').isOutbound, isTrue);
  });

  test('a Beállításokban megadott viselkedés jelzője dönt, nem a kód', () {
    final custom = DriverLeg.fromJson({..._leg(seq: 1, from: 'PICKUP', to: 'B_1A2B3C4D'), 'toStopWaits': 1, 'fromStopWaits': 0});
    expect(custom.isOutbound, isTrue);
    expect(custom.isReturn, isFalse);
    final notWaiting = DriverLeg.fromJson({..._leg(seq: 2, from: 'WAIT', to: 'DROPOFF'), 'fromStopWaits': false});
    expect(notWaiting.isReturn, isFalse);
    final cached = DriverLeg.fromCacheMap(custom.toCacheMap());
    expect(cached.toStopWaits, isTrue);
    expect(cached.copyWithStatus('IN_PROGRESS').isOutbound, isTrue);
  });

  test('egy autó útjai egymás után, sorszám szerint (a felvétel elöl); az autók a rendezés szerint', () {
    DriverLeg leg(String key, String vehicle, int seq, String start) => DriverLeg.fromJson({
          ..._leg(seq: seq),
          'legKey': key,
          'orderVehicleId': vehicle,
          'plannedStart': start,
        });
    // A visszaút (2.) korábbi tervezett időpontot kapott, mint egy másik autó útja, és előbb jön a listában.
    final legs = [
      leg('B1', 'car-b', 1, '2026-09-26T08:00:00Z'),
      leg('A2', 'car-a', 2, '2026-09-26T06:00:00Z'),
      leg('A1', 'car-a', 1, '2026-09-26T07:00:00Z'),
    ];
    final ordered = groupByVehicle(legs, (a, b) => a.plannedStart!.compareTo(b.plannedStart!));
    expect(ordered.map((l) => l.legKey), ['A1', 'A2', 'B1']);
  });
}
