import 'package:flutter/material.dart';

import '../../models/models.dart';

class DynamicField extends StatelessWidget {
  const DynamicField({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final FormFieldConfig field;
  final Map<String, dynamic>? value;
  final bool enabled;
  final Future<void> Function(Map<String, dynamic> value, List<String> optionIds) onChanged;

  @override
  Widget build(BuildContext context) {
    final label = '${field.name}${field.required ? ' *' : ''}';
    switch (field.dataType) {
      case 'BOOLEAN':
        return Card(
          child: SwitchListTile(
            title: Text(label),
            subtitle: field.description == null ? null : Text(field.description!),
            value: value?['value_boolean'] == 1 || value?['value_boolean'] == true,
            onChanged: enabled ? (v) => onChanged({'value_boolean': v}, const []) : null,
          ),
        );
      case 'SINGLE_SELECT':
        final current = (value?['option_ids'] as List? ?? const []).cast<String>();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            value: current.isEmpty ? null : current.first,
            decoration: InputDecoration(labelText: label, helperText: field.description),
            items: field.options.map((o) => DropdownMenuItem(value: o.id, child: Text(o.label))).toList(),
            onChanged: enabled ? (v) => (v == null ? null : onChanged(const {}, [v])) : null,
          ),
        );
      case 'MULTI_SELECT':
        final selected = (value?['option_ids'] as List? ?? const []).cast<String>().toSet();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (field.description != null) Text(field.description!),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: field.options.map((o) => FilterChip(
                  label: Text(o.label),
                  selected: selected.contains(o.id),
                  onSelected: enabled
                      ? (yes) {
                          final next = {...selected};
                          yes ? next.add(o.id) : next.remove(o.id);
                          onChanged(const {}, next.toList());
                        }
                      : null,
                )).toList(),
              ),
            ]),
          ),
        );
      case 'DATE':
      case 'DATETIME':
        final key = field.dataType == 'DATE' ? 'value_date' : 'value_datetime';
        final raw = value?[key]?.toString();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            onTap: !enabled ? null : () async {
              final now = DateTime.now();
              final date = await showDatePicker(context: context, firstDate: DateTime(now.year - 2), lastDate: DateTime(now.year + 5), initialDate: DateTime.tryParse(raw ?? '') ?? now);
              if (date == null || !context.mounted) return;
              if (field.dataType == 'DATE') {
                await onChanged({'value_date': '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'}, const []);
                return;
              }
              final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(DateTime.tryParse(raw ?? '')?.toLocal() ?? now));
              if (time == null) return;
              final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
              await onChanged({'value_datetime': dt.toUtc().toIso8601String()}, const []);
            },
            child: InputDecorator(decoration: InputDecoration(labelText: label, helperText: field.description), child: Text(raw ?? 'Válassz dátumot')),
          ),
        );
      case 'NUMBER':
        return _ScalarTextField(
          label: label,
          helper: field.description,
          initialValue: numberText(value?['value_number']),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          enabled: enabled,
          onChanged: (v) => onChanged({'value_number': v}, const []),
        );
      case 'TEXT':
      default:
        return _ScalarTextField(
          label: label,
          helper: field.description,
          initialValue: value?['value_text']?.toString() ?? '',
          keyboardType: TextInputType.text,
          enabled: enabled,
          onChanged: (v) => onChanged({'value_text': v}, const []),
        );
    }
  }
}

class _ScalarTextField extends StatefulWidget {
  const _ScalarTextField({required this.label, required this.initialValue, required this.keyboardType, required this.onChanged, this.helper, this.enabled = true});
  final bool enabled;
  final String label;
  final String? helper;
  final String initialValue;
  final TextInputType keyboardType;
  final Future<void> Function(String) onChanged;

  @override
  State<_ScalarTextField> createState() => _ScalarTextFieldState();
}

class _ScalarTextFieldState extends State<_ScalarTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controller,
        enabled: widget.enabled,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(labelText: widget.label, helperText: widget.helper),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// A szám úgy, ahogy beírták: 12 és nem 12.0, 12,5 és nem 12.500 (a telefon és a
/// szerver tizedes számként tárolja, visszatöltéskor ezt nem mutatjuk).
String numberText(Object? raw) {
  if (raw == null) return '';
  final text = raw.toString().trim();
  final parsed = raw is num ? raw.toDouble() : double.tryParse(text.replaceAll(',', '.'));
  if (parsed == null || !parsed.isFinite) return text;
  if (parsed == parsed.truncateToDouble()) return parsed.toInt().toString();
  var s = parsed.toString();
  if (s.contains('e') || s.contains('E')) return text;
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
