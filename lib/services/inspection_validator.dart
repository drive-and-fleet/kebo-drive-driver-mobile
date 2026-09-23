import '../local/local_repository.dart';
import '../models/local_models.dart';
import '../models/models.dart';

class InspectionValidationResult {
  const InspectionValidationResult(this.errors);
  final List<String> errors;
  bool get valid => errors.isEmpty;
}

class InspectionValidator {
  const InspectionValidator(this._local);
  final LocalRepository _local;

  Future<InspectionValidationResult> validate(LocalInspectionDraft draft, FormTypeConfig form) async {
    final values = await _local.inspectionValues(draft.localId);
    final photos = await _local.photos(draft.localId);
    final damages = await _local.damages(draft.localId);
    final errors = <String>[];

    final activeFields = form.fields.where((f) => f.phase == 'BOTH' || f.phase == draft.inspectionType).toList();
    for (final field in activeFields) {
      final value = values[field.fieldDefinitionId];
      // A szerver csak pontos tizedes számot fogad el; a hibás érték lezárás
      // után már nem javítható, és a feltöltést véglegesen elakasztaná.
      if (field.dataType == 'NUMBER' && value != null && !isValidNumber(value['value_number'])) {
        errors.add('Érvénytelen szám: ${field.name}');
        continue;
      }
      if (!field.required) continue;
      if (!_hasValue(field, value)) errors.add('Hiányzó mező: ${field.name}');
    }

    final requirements = form.photoRequirements.where((p) => p.phase == 'BOTH' || p.phase == draft.inspectionType);
    for (final requirement in requirements.where((p) => p.required)) {
      final count = photos.where((photo) => photo.damageLocalId == null && photo.photoType == requirement.photoType).length;
      if (count < requirement.minCount) {
        errors.add('Hiányzó kötelező kép: ${requirement.photoType} (${requirement.minCount} db)');
      }
    }

    for (final damage in damages) {
      final count = photos.where((photo) => photo.damageLocalId == damage.localId).length;
      if (count == 0) errors.add('A sérüléshez nincs fotó: ${damage.description}');
    }

    return InspectionValidationResult(errors);
  }

  /// Ugyanaz a szabály, mint a szerver `@IsNumberString` ellenőrzése.
  static bool isValidNumber(Object? raw) {
    final text = LocalRepository.normalizeNumber(raw);
    return text != null && RegExp(r'^[+-]?([0-9]*[.])?[0-9]+$').hasMatch(text);
  }

  bool _hasValue(FormFieldConfig field, Map<String, dynamic>? value) {
    if (value == null) return false;
    switch (field.dataType) {
      case 'TEXT':
        return '${value['value_text'] ?? ''}'.trim().isNotEmpty;
      case 'NUMBER':
        return '${value['value_number'] ?? ''}'.trim().isNotEmpty;
      case 'BOOLEAN':
        return value['value_boolean'] != null;
      case 'DATE':
        return '${value['value_date'] ?? ''}'.isNotEmpty;
      case 'DATETIME':
        return '${value['value_datetime'] ?? ''}'.isNotEmpty;
      case 'SINGLE_SELECT':
      case 'MULTI_SELECT':
        return (value['option_ids'] as List? ?? const []).isNotEmpty;
      default:
        return false;
    }
  }
}
