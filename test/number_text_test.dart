import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/ui/widgets/dynamic_field.dart';

void main() {
  test('a szám visszatöltve is úgy látszik, ahogy beírták', () {
    expect(numberText(12.0), '12');
    expect(numberText('12.000'), '12');
    expect(numberText(12.5), '12.5');
    expect(numberText('12.500'), '12.5');
    expect(numberText('125000'), '125000');
    expect(numberText(null), '');
    expect(numberText(''), '');
    expect(numberText('abc'), 'abc');
  });
}
