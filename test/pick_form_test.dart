import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/models/models.dart';
import 'package:fleet_driver_app/ui/leg_flow.dart';

FormTypeConfig _form(String id, {bool isDefault = false}) =>
    FormTypeConfig(id: id, serviceOrgId: '2', code: 'F$id', name: 'Űrlap $id', fields: const [], photoRequirements: const [], isDefault: isDefault);

void main() {
  final forms = [_form('1'), _form('2', isDefault: true), _form('3')];

  test('a megrendelés jegyzőkönyv-típusa nyer', () {
    expect(pickForm(forms, '3').id, '3');
  });

  test('ha a megrendelés nem mond semmit (vagy nincs a telefonon), az alapértelmezett', () {
    expect(pickForm(forms, null).id, '2');
    expect(pickForm(forms, '9').id, '2');
  });

  test('alapértelmezett nélkül az első', () {
    expect(pickForm([_form('1'), _form('3')], null).id, '1');
  });

  test('a régi gyorsítótárból (form_type_id nélkül) is visszaolvasható az út', () {
    final leg = DriverLeg.fromCacheMap({
      'leg_key': 'k', 'status': 'ASSIGNED', 'sequence_no': 1, 'order_vehicle_id': 'ov', 'registration_number': 'ABC123',
      'order_no': 'O', 'service_org_id': '2', 'from_address': 'A', 'to_address': 'B',
    });
    expect(leg.formTypeId, isNull);
    expect(DriverLeg.fromJson({
      'legKey': 'k', 'status': 'ASSIGNED', 'sequenceNo': 1, 'orderVehicleId': 'ov', 'registrationNumber': 'ABC123',
      'orderNo': 'O', 'serviceOrgId': '2', 'fromAddress': 'A', 'toAddress': 'B', 'formTypeId': 7,
    }).toCacheMap()['form_type_id'], '7');
  });
}
