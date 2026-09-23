import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/api/http_api.dart';
import 'package:fleet_driver_app/local/local_repository.dart';
import 'package:fleet_driver_app/services/inspection_validator.dart';
import 'package:fleet_driver_app/services/sync_service.dart';

void main() {
  group('inspectionValuesPayload', () {
    test('a false boolean felmegy, nem vész el', () {
      final payload = inspectionValuesPayload({
        'f1': {'value_boolean': 0, 'option_ids': <String>[]},
      }, const {});
      expect(payload, [
        {'fieldDefinitionId': 'f1', 'valueBoolean': false},
      ]);
    });

    test('a más fázisba tartozó mező nem megy fel', () {
      final payload = inspectionValuesPayload({
        'pickupOnly': {'value_boolean': 1, 'option_ids': <String>[]},
        'both': {'value_text': 'ok', 'option_ids': <String>[]},
      }, {'both'});
      expect(payload.map((v) => v['fieldDefinitionId']), ['both']);
    });

    test('üres szám és üres többválasztós nem megy fel, a tizedesvessző pont lesz', () {
      final payload = inspectionValuesPayload({
        'emptyNumber': {'value_number': '', 'option_ids': <String>[]},
        'emptyMulti': {'option_ids': <String>[]},
        'number': {'value_number': '12,5', 'option_ids': <String>[]},
      }, const {});
      expect(payload, [
        {'fieldDefinitionId': 'number', 'valueNumber': '12.5'},
      ]);
    });
  });

  group('isInspectionClosed', () {
    test('a stabil hibakódot felismeri', () {
      expect(isInspectionClosed(const ApiException(409, 'x', body: {'code': 'INSPECTION_CLOSED'})), isTrue);
    });

    test('a régi szerver üzenetét is felismeri', () {
      expect(isInspectionClosed(const ApiException(409, 'inspection closed')), isTrue);
    });

    test('más ütközést nem tekint lezártnak', () {
      expect(isInspectionClosed(const ApiException(409, 'leg cannot start')), isFalse);
      expect(isInspectionClosed(const ApiException(400, 'inspection closed')), isFalse);
    });
  });

  group('értékszabályok', () {
    test('az üres érték sor-törlésnek számít, a false nem', () {
      expect(LocalRepository.isEmptyValue({'value_number': ' '}, const []), isTrue);
      expect(LocalRepository.isEmptyValue(const {}, const []), isTrue);
      expect(LocalRepository.isEmptyValue({'value_boolean': false}, const []), isFalse);
      expect(LocalRepository.isEmptyValue(const {}, const ['o1']), isFalse);
    });

    test('a szám ugyanazt a szabályt követi, mint a szerver', () {
      expect(InspectionValidator.isValidNumber('12,5'), isTrue);
      expect(InspectionValidator.isValidNumber('-3'), isTrue);
      expect(InspectionValidator.isValidNumber('12.'), isFalse);
      expect(InspectionValidator.isValidNumber('abc'), isFalse);
      expect(InspectionValidator.isValidNumber(''), isFalse);
    });
  });
}
