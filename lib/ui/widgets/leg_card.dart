import 'package:flutter/material.dart';

import '../../models/local_models.dart';
import '../../models/models.dart';
import '../theme.dart';
import 'sync_badge.dart';

class LegCard extends StatelessWidget {
  const LegCard({super.key, required this.leg, required this.onTap, this.trailing, this.syncState});
  final DriverLeg leg;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Csak a telefonon lévő, még fel nem töltött adatnál jelenik meg.
  final LegSyncState? syncState;

  @override
  Widget build(BuildContext context) {
    final vehicle = [leg.make, leg.model].whereType<String>().where((v) => v.isNotEmpty).join(' ');
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    leg.registrationNumber,
                    style: const TextStyle(fontFamily: 'BarlowCondensed', fontSize: AppText.plate, fontWeight: FontWeight.w700, color: AppColors.ink900),
                  ),
                ),
                StatusPlate(leg.status, labelOverride: _statusLabel(leg.status)),
              ]),
              if (vehicle.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(vehicle, style: const TextStyle(fontSize: AppText.secondary, color: AppColors.ink600)),
              ),
              if (leg.isOutbound || leg.isReturn) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _RoundTripTag(outbound: leg.isOutbound),
              ),
              if (syncState != null) Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SyncBadge(syncState),
              ),
              const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1)),
              _AddressLine(icon: Icons.trip_origin, label: leg.fromStopTypeName ?? (leg.isReturn ? 'Visszaindulás' : 'Felvétel'), address: leg.fromAddress, time: leg.plannedStart),
              const SizedBox(height: 6),
              _AddressLine(icon: leg.isOutbound ? Icons.hourglass_top : Icons.flag_outlined, label: leg.toStopTypeName ?? (leg.isOutbound ? 'Várakozás' : 'Leadás'), address: leg.toAddress, time: leg.plannedEnd),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text(
                  'Fuvar: ${leg.orderNo} • Szakasz ${leg.sequenceNo}${leg.legCount == null ? '' : '/${leg.legCount}'}',
                  style: const TextStyle(fontSize: 13, color: AppColors.ink400),
                )),
                if (trailing != null) trailing!,
              ]),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(String value) => switch (value) {
        'PLANNED' => 'Tervezett',
        'ASSIGNED' => 'Kiosztva',
        'IN_PROGRESS' => 'Folyamatban',
        'COMPLETED_PENDING_SYNC' => 'Szinkronra vár',
        'COMPLETED' => 'Teljesítve',
        'CANCELLED' => 'Lemondva',
        _ => value,
      };
}

class _AddressLine extends StatelessWidget {
  const _AddressLine({required this.icon, required this.label, required this.address, this.time});
  final IconData icon;
  final String label;
  final String address;
  final DateTime? time;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 20, color: AppColors.ink600),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label: $address', style: const TextStyle(fontSize: AppText.body)),
          if (time != null) Text(_date(time!), style: const TextStyle(fontSize: 13, color: AppColors.ink600)),
        ]),
      ),
    ]);
  }

  String _date(DateTime value) {
    final d = value.toLocal();
    return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// „Körfuvar · odaút / visszaút” címke a fuvarkártyán.
class _RoundTripTag extends StatelessWidget {
  const _RoundTripTag({required this.outbound});
  final bool outbound;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.tintAmber,
        border: Border.all(color: AppColors.signalAmber),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        outbound ? 'Körfuvar · odaút – leadás után várj, és vidd vissza' : 'Körfuvar · visszaút',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink900),
      ),
    );
  }
}
