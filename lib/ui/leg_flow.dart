import 'package:flutter/material.dart';

import '../local/local_repository.dart';
import '../logging/app_log.dart';
import '../models/models.dart';
import '../services/app_services.dart';
import 'screens/inspection_editor_screen.dart';
import 'screens/leg_detail_screen.dart';
import 'theme.dart';

/// A fuvar lépései egy helyen, hogy a „Most” képernyő és a fuvar adatlapja
/// ugyanúgy működjön: jegyzőkönyv indítása közvetlenül (külön Jegyzőkönyv oldal
/// nélkül), a lezárt jegyzőkönyv megtekintése, a körfuvar várakozása és a leadás.

/// Van-e mit másolni ennek a fázisnak a jegyzőkönyvébe (az autó közvetlenül előző jegyzőkönyve).
Future<bool> canCopyInto(AppServices services, DriverLeg leg, String phase) async {
  if (await services.local.inspectionForLeg(leg.legKey, phase) != null) return false;
  return await services.local.copySourceFor(leg, phase) != null;
}

/// Az út következő lépése: átvétel (ASSIGNED) vagy leadás (IN_PROGRESS).
String? nextPhase(DriverLeg leg) => switch (leg.status) {
      'ASSIGNED' => 'PICKUP',
      'IN_PROGRESS' => 'DROPOFF',
      _ => null,
    };

/// Megnyitja a fázis jegyzőkönyvét: a meglévőt folytatja (vagy csak megmutatja, ha
/// már lezárt), különben újat kezd a szolgálat aktív típusával. A másolás alapból
/// be van kapcsolva ([copy]); ha nincs mit másolni, üresen indul.
/// A fuvar indítását / lezárását a jegyzőkönyv lezárása végzi (egy lokális tranzakció).
Future<void> runPhase(BuildContext context, AppServices services, DriverLeg leg, String phase, {bool copy = true}) async {
  log.info('work', '${phase == 'PICKUP' ? 'Fuvar indítása' : 'Fuvar lezárása'}: ${leg.legKey} (${leg.status}), másolás: ${copy ? 'be' : 'ki'}');
  final existing = await services.local.inspectionForLeg(leg.legKey, phase);
  if (existing != null && existing.status != 'DRAFT') {
    // A jegyzőkönyv már lezárt, csak az állapotváltás maradt el (korábbi appverzió):
    // nem nyitjuk újra, csak a hiányzó lépést végezzük el.
    if (phase == 'PICKUP') {
      await services.work.startLeg(leg);
    } else {
      await services.work.completeLeg(leg);
    }
    return;
  }
  if (!context.mounted) return;
  await openInspection(context, services, leg, phase, copy: copy);
  // Körfuvar: a leadás után a sofőr nem mehet el — megvárja az autót, és visszaviszi.
  // Csak ha a visszaút is az övé: ha másnak osztották ki, neki nincs mire várnia.
  if (phase == 'DROPOFF' && leg.isOutbound && await services.local.returnLegFor(leg) != null) {
    final closed = await services.local.inspectionForLeg(leg.legKey, 'DROPOFF');
    if (closed != null && closed.status != 'DRAFT' && context.mounted) await showWaitDialog(context, services, leg);
  }
}

/// A fázis jegyzőkönyve: a meglévő (lezártnál csak megtekintés), vagy új.
Future<void> openInspection(BuildContext context, AppServices services, DriverLeg leg, String phase, {bool copy = true}) async {
  final existing = await services.local.inspectionForLeg(leg.legKey, phase);
  if (existing != null) {
    final form = (await services.work.formsFor(leg)).where((f) => f.id == existing.formTypeId).firstOrNull;
    if (form == null) {
      throw StateError('A jegyzőkönyv űrlapja nincs a telefonon. Frissítsd a munkalistát hálózat mellett.');
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionEditorScreen(services: services, leg: leg, draftId: existing.localId, form: form),
    ));
    return;
  }
  // A sofőr nem választ: a szolgálat aktív jegyzőkönyv-típusát kapja.
  final forms = await services.work.formsFor(leg, activeOnly: true);
  if (forms.isEmpty) {
    throw StateError('Nincs aktív jegyzőkönyv-típus a telefonon. Frissítsd a Munkáim listát hálózat mellett; '
        'ha így sem jelenik meg, a sofőrszolgálat még nem állította be.');
  }
  final form = forms.first;
  final source = copy ? await services.local.copySourceFor(leg, phase) : null;
  final draft = await services.work.openInspection(
    leg: leg,
    phase: phase,
    formTypeId: form.id,
    copyFromServerId: source?.serverId,
    copyFromLocalId: source?.localId,
  );
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => InspectionEditorScreen(services: services, leg: leg, draftId: draft.localId, form: form),
  ));
}

String shortTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.month)}.${two(l.day)}. ${two(l.hour)}:${two(l.minute)}';
}

Future<void> showWaitDialog(BuildContext context, AppServices services, DriverLeg outbound) async {
  final back = await services.local.returnLegFor(outbound);
  log.info('work', 'Körfuvar: várakozás a leadás után (${outbound.legKey}), visszaút: ${back?.legKey ?? 'nincs a sofőrnél'}');
  if (!context.mounted) return;
  final open = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.hourglass_top, color: AppColors.signalAmber, size: 36),
      title: const Text('Körfuvar – várakozás'),
      content: Text(back == null
          ? 'Ne menj el! Várd meg az autót itt: ${outbound.toAddress}.\n\nA visszaút még nincs kiosztva neked – szólj az irodának.'
          : 'Ne menj el! Várd meg, amíg az autó elkészül itt: ${outbound.toAddress}.\n\n'
              'Utána vidd vissza ide: ${back.toAddress}'
              '${back.plannedStart == null ? '' : '\nTervezett visszaindulás: ${shortTime(back.plannedStart)}'}.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Rendben')),
        if (back != null)
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Visszaút megnyitása')),
      ],
    ),
  );
  if (open == true && back != null && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LegDetailScreen(services: services, legKey: back.legKey),
    ));
  }
}

/// Leadható-e az út a telefonról: kiosztott, még el nem indított, a szerveren is létező,
/// és nincs rajta megkezdett jegyzőkönyv.
Future<bool> canRelease(AppServices services, DriverLeg leg) async {
  if (leg.status != 'ASSIGNED' || LocalRepository.isLocalLeg(leg.legKey)) return false;
  return await services.local.inspectionForLeg(leg.legKey, 'PICKUP') == null;
}

/// „Leadom ezt a fuvart”: megerősítés, nem kötelező indok, és csak hálózattal.
/// Igazat ad, ha az út lekerült a sofőrről.
Future<bool> releaseLeg(BuildContext context, AppServices services, DriverLeg leg) async {
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leadod ezt a fuvart?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${leg.registrationNumber} · ${leg.fromPlace} → ${leg.toPlace}'
              '${leg.plannedStart == null ? '' : '\n${shortTime(leg.plannedStart)}'}'),
          const SizedBox(height: 12),
          const Text('A fuvar lekerül rólad, és újra szabad lesz: az iroda vagy egy másik sofőr veheti fel.',
              style: TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
          const SizedBox(height: 12),
          TextField(
            controller: reason,
            maxLines: 3,
            minLines: 2,
            maxLength: 400,
            decoration: const InputDecoration(labelText: 'Indok (nem kötelező)', hintText: 'pl. megbetegedtem'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.signalRed),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Leadom'),
        ),
      ],
    ),
  );
  final text = reason.text;
  reason.dispose();
  if (ok != true) return false;
  try {
    await services.work.releaseLeg(leg, reason: text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A fuvart leadtad, lekerült rólad.')));
    }
    return true;
  } catch (e) {
    log.warn('work', 'A fuvar leadása nem sikerült: ${leg.legKey}', e);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('A leadás nem sikerült (internet kell hozzá): $e'),
        duration: const Duration(seconds: 6),
      ));
    }
    return false;
  }
}
