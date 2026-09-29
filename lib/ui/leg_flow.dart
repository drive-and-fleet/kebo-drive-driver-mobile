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
/// nélkül), a lezárt jegyzőkönyv megtekintése és a fuvar leadása.

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
  if (phase == 'PICKUP') {
    final allowed = await _mayStart(context, services, leg);
    if (!allowed || !context.mounted) return;
    // Az időpont-módosítás után a friss adattal megy tovább.
    leg = await services.local.cachedLeg(leg.legKey) ?? leg;
    if (!context.mounted) return;
  }
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
  // A leadás lezárása után a szerkesztő a „Kész” képernyőre vált (körfuvarnál ott a várakozás).
  await openInspection(context, services, leg, phase, copy: copy);
}

/// Átveheti-e most az autót. Ha nem, megmondja miért, és a megoldást is felkínálja:
/// a futó fuvar megnyitását, vagy későbbi napra tervezett útnál az időpont módosítását.
Future<bool> _mayStart(BuildContext context, AppServices services, DriverLeg leg) async {
  final blocker = await services.work.startBlocker(leg);
  if (blocker == null) return true;
  log.info('work', 'Indítás nem engedélyezett: ${leg.legKey} – ${blocker.message}');
  if (!context.mounted) return false;
  final running = blocker.running;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.block, color: AppColors.signalRed, size: 36),
      title: Text(running != null ? 'Már úton vagy egy autóval' : 'Ez a fuvar még nem mára szól'),
      content: Text(blocker.laterDay ? '${blocker.message}\nHa mégis ma kell elvinni, módosítsd a felvétel időpontját.' : blocker.message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Rendben')),
        if (running != null)
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'open'), child: Text('${running.registrationNumber} megnyitása')),
        if (blocker.laterDay)
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'reschedule'), child: const Text('Időpont módosítása')),
      ],
    ),
  );
  if (!context.mounted) return false;
  if (action == 'open' && running != null) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegDetailScreen(services: services, legKey: running.legKey)));
    return false;
  }
  if (action == 'reschedule') {
    final changed = await rescheduleDialog(context, services, leg);
    if (!changed || !context.mounted) return false;
    final fresh = await services.local.cachedLeg(leg.legKey) ?? leg;
    return await services.work.startBlocker(fresh) == null;
  }
  return false;
}

/// A felvétel időpontjának módosítása (még el nem indított útnál): nap, óra, és
/// nem kötelező indok. A módosítás naplózva megy fel, az iroda látja.
Future<bool> rescheduleDialog(BuildContext context, AppServices services, DriverLeg leg) async {
  var at = (leg.plannedStart ?? DateTime.now()).toLocal();
  final reason = TextEditingController();
  String two(int v) => v.toString().padLeft(2, '0');
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialog) => AlertDialog(
        title: const Text('Felvétel időpontja'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${leg.registrationNumber} · ${leg.fromPlace}'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today),
                  label: Text('${at.year}.${two(at.month)}.${two(at.day)}.'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final first = DateTime(now.year, now.month, now.day);
                    final day = await showDatePicker(context: dialogContext, initialDate: at.isBefore(first) ? first : at, firstDate: first, lastDate: DateTime(now.year + 1, 12, 31));
                    if (day != null) setDialog(() => at = DateTime(day.year, day.month, day.day, at.hour, at.minute));
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text('${two(at.hour)}:${two(at.minute)}'),
                  onPressed: () async {
                    final time = await showTimePicker(context: dialogContext, initialTime: TimeOfDay.fromDateTime(at));
                    if (time != null) setDialog(() => at = DateTime(at.year, at.month, at.day, time.hour, time.minute));
                  },
                ),
              ),
            ]),
            TextButton(onPressed: () => setDialog(() => at = DateTime.now()), child: const Text('Most')),
            TextField(controller: reason, maxLength: 300, decoration: const InputDecoration(labelText: 'Indok (nem kötelező)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Mégse')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Mentés')),
        ],
      ),
    ),
  );
  final text = reason.text;
  reason.dispose();
  if (ok != true) return false;
  try {
    await services.work.rescheduleLeg(leg, at, reason: text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Új felvételi időpont: ${at.year}.${two(at.month)}.${two(at.day)}. ${two(at.hour)}:${two(at.minute)}')));
    }
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nem sikerült: $e')));
    return false;
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

/// Leadható-e az út a telefonról: kiosztott, még el nem indított, a szerveren is létező,
/// és nincs rajta megkezdett jegyzőkönyv.
Future<bool> canRelease(AppServices services, DriverLeg leg) async {
  if (leg.status != 'ASSIGNED') return false;
  // Az elkezdett, de le nem zárt (fel sem küldött) jegyzőkönyv nem akadály: leadáskor törlődik.
  final pickup = await services.local.inspectionForLeg(leg.legKey, 'PICKUP');
  return pickup == null || pickup.status == 'DRAFT';
}

/// „Leadom ezt a fuvart”: megerősítés, nem kötelező indok, és csak hálózattal.
/// Igazat ad, ha az út lekerült a sofőrről.
Future<bool> releaseLeg(BuildContext context, AppServices services, DriverLeg leg) async {
  final draft = await services.local.inspectionForLeg(leg.legKey, 'PICKUP');
  if (!context.mounted) return false;
  final reason = TextEditingController();
  final onlyHere = LocalRepository.isLocalLeg(leg.legKey);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leadod ezt a fuvart?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${leg.registrationNumber} · ${leg.fromPlace} → ${leg.toPlace}'
              '${leg.plannedStart == null ? '' : '\n${shortTime(leg.plannedStart)}'}'),
          const SizedBox(height: 12),
          Text(
              onlyHere
                  ? 'Ezt a fuvart te vetted fel, és még nem ment fel a szerverre: a telefonról törlődik.'
                  : 'A fuvar lekerül rólad, és újra szabad lesz: az iroda vagy egy másik sofőr veheti fel.',
              style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
          if (draft != null) ...[
            const SizedBox(height: 8),
            const Text('Az elkezdett átvételi jegyzőkönyv törlődik (még nem ment fel).',
                style: TextStyle(fontSize: AppText.secondary, fontWeight: FontWeight.w600, color: AppColors.signalAmber)),
          ],
          const SizedBox(height: 12),
          if (!onlyHere) TextField(
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
