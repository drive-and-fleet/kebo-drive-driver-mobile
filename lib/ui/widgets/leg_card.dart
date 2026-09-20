import 'package:flutter/material.dart';

import '../../models/models.dart';

class LegCard extends StatelessWidget {
  const LegCard({super.key, required this.leg, required this.onTap, this.trailing});
  final DriverLeg leg;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(child: Text('${leg.sequenceNo}')),
        title: Text('${leg.registrationNumber} • ${leg.fromAddress} → ${leg.toAddress}'),
        subtitle: Text('${leg.orderNo} • ${_status(leg.status)}${leg.plannedStart == null ? '' : '\n${_date(leg.plannedStart!)}'}'),
        isThreeLine: leg.plannedStart != null,
        trailing: trailing ?? const Icon(Icons.chevron_right),
      ),
    );
  }

  String _status(String value) => switch (value) {
        'PLANNED' => 'Tervezett',
        'ASSIGNED' => 'Kiosztva',
        'IN_PROGRESS' => 'Folyamatban',
        'COMPLETED_PENDING_SYNC' => 'Lezárva, szinkronra vár',
        'COMPLETED' => 'Teljesítve',
        'CANCELLED' => 'Lemondva',
        _ => value,
      };

  String _date(DateTime value) {
    final d = value.toLocal();
    return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
