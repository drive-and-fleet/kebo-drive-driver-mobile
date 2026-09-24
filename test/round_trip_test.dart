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
  test('a várakozó megállóba érkező szakasz a körfuvar odaútja', () {
    final leg = DriverLeg.fromJson(_leg(seq: 1, from: 'PICKUP', to: 'WAIT'));
    expect(leg.isOutbound, isTrue);
    expect(leg.isReturn, isFalse);
  });

  test('a várakozó megállóból induló szakasz a visszaút', () {
    final leg = DriverLeg.fromJson(_leg(seq: 2, from: 'WAIT', to: 'DROPOFF'));
    expect(leg.isReturn, isTrue);
    expect(leg.isOutbound, isFalse);
  });

  test('sima fuvar és régi (típus nélküli) adat nem körfuvar', () {
    expect(DriverLeg.fromJson(_leg(seq: 1, from: 'PICKUP', to: 'DROPOFF')).isOutbound, isFalse);
    final old = DriverLeg.fromJson(_leg(seq: 1));
    expect(old.isOutbound || old.isReturn, isFalse);
  });

  test('a megállótípus megmarad a helyi gyorsítótárban és az állapotváltáskor', () {
    final leg = DriverLeg.fromJson(_leg(seq: 1, from: 'PICKUP', to: 'WAIT'));
    final cached = DriverLeg.fromCacheMap(leg.toCacheMap());
    expect(cached.toStopType, 'WAIT');
    expect(cached.copyWithStatus('IN_PROGRESS').isOutbound, isTrue);
  });
}
