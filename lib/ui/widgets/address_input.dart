import 'dart:async';

import 'package:flutter/material.dart';

/// Címmező gépelés közbeni ajánlással. Az ajánlás csak segítség: amit a sofőr
/// beír, az marad (térerő nélkül is), egy ajánlatra koppintva az kerül a mezőbe.
class AddressInput extends StatefulWidget {
  const AddressInput({super.key, required this.controller, required this.label, required this.suggest, this.validator});

  final TextEditingController controller;
  final String label;
  final Future<({List<String> labels, bool geoapify})> Function(String query) suggest;
  final String? Function(String?)? validator;

  @override
  State<AddressInput> createState() => _AddressInputState();
}

class _AddressInputState extends State<AddressInput> {
  final _focus = FocusNode();
  Timer? _debounce;
  Completer<void>? _waiting;
  String _lastQuery = '';
  List<String> _lastResult = const [];
  /// A listában Geoapify-találat is van: a nevét alul feltüntetjük (az ingyenes csomag feltétele).
  bool _geoapify = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Fél másodperc szünet után kérdez (nem minden betűnél); hálózat nélkül üres a lista.
  Future<List<String>> _options(String text) async {
    final query = text.trim();
    if (query.length < 4) return const [];
    if (query == _lastQuery) return _lastResult;
    // Az előző várakozás azonnal véget ér (üres listával), ez vár tovább.
    _debounce?.cancel();
    if (!(_waiting?.isCompleted ?? true)) _waiting!.complete();
    final done = _waiting = Completer<void>();
    _debounce = Timer(const Duration(milliseconds: 450), () { if (!done.isCompleted) done.complete(); });
    await done.future;
    if (query != widget.controller.text.trim()) return const [];
    try {
      final result = await widget.suggest(query);
      _lastQuery = query;
      _lastResult = result.labels;
      _geoapify = result.geoapify;
      return result.labels;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RawAutocomplete<String>(
        textEditingController: widget.controller,
        focusNode: _focus,
        optionsBuilder: (value) => _options(value.text),
        onSelected: (choice) {
          // „Név – cím” találatnál csak a cím kerül a mezőbe.
          final parts = choice.split(' – ');
          widget.controller.text = parts.last;
          widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextFormField(
          controller: controller,
          focusNode: focusNode,
          validator: widget.validator,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: widget.label, suffixIcon: const Icon(Icons.search)),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 520),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(option),
                      onTap: () => onSelected(option),
                    ),
                  if (_geoapify)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text('Powered by Geoapify', style: TextStyle(fontSize: 12, color: Color(0xFF4A5F6B))),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
