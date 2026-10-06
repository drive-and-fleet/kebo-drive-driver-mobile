import 'package:flutter/material.dart';

import '../logging/app_log.dart';
import '../models/models.dart';
import '../services/app_services.dart';

/// „Adatok módosítása”: az autó (rendszám, gyártó, modell, szín), a használó, és az út két
/// megállójának kapcsolattartója (ki adja át, ki veszi át). Előtte megerősítés. A telefonon
/// azonnal érvényes, a szinkron viszi fel; minden változás naplózva, az iroda a fuvar
/// oldalán egy helyen látja. Igazat ad, ha változott valami.
Future<bool> editLegData(BuildContext context, AppServices services, DriverLeg leg) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Adatok módosítása'),
      content: Text('Biztosan módosítani szeretnéd a fuvar adatait (${leg.startsMidRoute ? '' : 'rendszám, autó, '}használó, kapcsolattartó)? '
          'Minden módosítás naplózva van, az iroda látja.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Igen, módosítom')),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;

  final fields = <String, TextEditingController>{
    'plate': TextEditingController(text: leg.registrationNumber),
    'make': TextEditingController(text: leg.make ?? ''),
    'model': TextEditingController(text: leg.model ?? ''),
    'color': TextEditingController(text: leg.color ?? ''),
    'fromContactName': TextEditingController(text: leg.fromContactName ?? ''),
    'fromContactPhone': TextEditingController(text: leg.fromContactPhone ?? ''),
    'toContactName': TextEditingController(text: leg.toContactName ?? ''),
    'toContactPhone': TextEditingController(text: leg.toContactPhone ?? ''),
    'userName': TextEditingController(text: leg.vehicleUserName ?? ''),
    'userPhone': TextEditingController(text: leg.vehicleUserPhone ?? ''),
    'userEmail': TextEditingController(text: leg.vehicleUserEmail ?? ''),
    'extraEmail': TextEditingController(text: leg.vehicleExtraEmail ?? ''),
  };
  final form = GlobalKey<FormState>();
  String? email(String? v) =>
      v == null || v.trim().isEmpty || RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim()) ? null : 'Érvénytelen e-mail-cím';
  // Egy korábbi út után (pl. körfuvar visszaútja) az autó már ugyanaz: a rendszám, gyártó,
  // modell és szín itt nem módosítható (a szerver sem engedi), csak az első úton.
  final carLocked = leg.startsMidRoute;
  Widget field(String key, String label, {TextInputType? keyboard, String? Function(String?)? validator, bool upper = false, bool locked = false}) => TextFormField(
        controller: fields[key],
        readOnly: locked,
        enabled: !locked,
        decoration: InputDecoration(labelText: label, suffixIcon: locked ? const Icon(Icons.lock_outline, size: 18) : null),
        keyboardType: keyboard,
        textCapitalization: upper ? TextCapitalization.characters : TextCapitalization.sentences,
        validator: validator,
      );
  Widget section(String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 2),
        child: Align(alignment: Alignment.centerLeft, child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700))),
      );
  final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (pageContext) => Scaffold(
      appBar: AppBar(title: const Text('Adatok módosítása'), actions: [
        TextButton(
          onPressed: () { if (form.currentState?.validate() ?? false) Navigator.pop(pageContext, true); },
          child: const Text('Mentés'),
        ),
      ]),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            section('Autó'),
            if (carLocked)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Ez az út egy korábbi folytatása: az autó adatai itt nem módosíthatók, csak az első úton.',
                    style: TextStyle(fontSize: 13, color: Colors.black54)),
              ),
            field('plate', 'Rendszám', upper: true, locked: carLocked, validator: (v) => v == null || v.trim().isEmpty ? 'Kötelező' : null),
            field('make', 'Gyártó', locked: carLocked),
            field('model', 'Modell (típus)', locked: carLocked),
            field('color', 'Szín', locked: carLocked),
            section('Átadó – ${leg.fromPlace}'),
            field('fromContactName', 'Kapcsolattartó neve'),
            field('fromContactPhone', 'Kapcsolattartó telefonja', keyboard: TextInputType.phone),
            section('Átvevő – ${leg.toPlace}'),
            field('toContactName', 'Kapcsolattartó neve'),
            field('toContactPhone', 'Kapcsolattartó telefonja', keyboard: TextInputType.phone),
            section('Használó'),
            field('userName', 'Használó neve'),
            field('userPhone', 'Használó telefonja', keyboard: TextInputType.phone),
            field('userEmail', 'Használó e-mail', keyboard: TextInputType.emailAddress, validator: email),
            field('extraEmail', 'További e-mail a jegyzőkönyvekhez', keyboard: TextInputType.emailAddress, validator: email),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () { if (form.currentState?.validate() ?? false) Navigator.pop(pageContext, true); },
              icon: const Icon(Icons.save_outlined),
              label: const Text('Mentés'),
            ),
          ]),
        ),
      ),
    ),
  ));
  var changed = false;
  if (ok == true) {
    String t(String key) => fields[key]!.text.trim();
    try {
      changed = await services.work.updateLegVehicle(leg,
          registrationNumber: carLocked ? null : t('plate').toUpperCase(),
          make: carLocked ? null : t('make'), model: carLocked ? null : t('model'), color: carLocked ? null : t('color'),
          userName: t('userName'), userPhone: t('userPhone'),
          userEmail: t('userEmail'), extraEmail: t('extraEmail'),
          fromContactName: t('fromContactName'), fromContactPhone: t('fromContactPhone'),
          toContactName: t('toContactName'), toContactPhone: t('toContactPhone'));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed ? 'Mentve – az iroda naplózva látja.' : 'Nem volt változás.')));
      }
    } catch (e) {
      log.warn('work', 'Az adatok módosítása nem sikerült: ${leg.legKey}', e);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nem sikerült: $e')));
    }
  }
  for (final c in fields.values) {
    c.dispose();
  }
  return changed;
}
