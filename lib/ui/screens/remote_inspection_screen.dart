import 'package:flutter/material.dart';

import '../theme.dart';

/// Egy lezárt jegyzőkönyv a szerverről, csak olvasásra: amikor a teljesített út
/// jegyzőkönyve már nincs a telefonon. Az adatok, a sérülések fotóval, a fotók,
/// az aláírás és a megjegyzés; fent, hogy ki és mikor rögzítette.
class RemoteInspectionScreen extends StatelessWidget {
  const RemoteInspectionScreen({super.key, required this.inspection, required this.plate});
  final Map<String, dynamic> inspection;
  final String plate;

  static String _when(dynamic value) {
    final t = DateTime.tryParse('${value ?? ''}')?.toLocal();
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}.${two(t.month)}.${two(t.day)}. ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final pickup = inspection['inspectionType'] == 'PICKUP';
    final values = (inspection['values'] as List? ?? const []).cast<Map>();
    final damages = (inspection['damages'] as List? ?? const []).cast<Map>();
    final photos = (inspection['photos'] as List? ?? const []).cast<Map>();
    final signature = inspection['signature'] as Map?;
    final note = '${inspection['generalNote'] ?? ''}'.trim();
    final corrections = (inspection['correctionCount'] as num?)?.toInt() ?? 0;
    const heading = TextStyle(fontFamily: 'BarlowCondensed', fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.ink900);
    return Scaffold(
      appBar: AppBar(title: Text(pickup ? 'Átvételi jegyzőkönyv' : 'Leadási jegyzőkönyv')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(plate, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                'Lezárva: ${_when(inspection['completedAt'])}',
                if (inspection['performedByName'] != null) 'Rögzítette: ${inspection['performedByName']}',
                if (corrections > 0) 'Javítva: $corrections alkalommal',
                'Csak megtekinthető.',
              ].join('\n')),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Adatok', style: heading),
          const SizedBox(height: 6),
          if (values.isEmpty) const Text('Nincs rögzített adat.', style: TextStyle(color: AppColors.ink600)),
          for (final v in values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: Text('${v['name']}', style: const TextStyle(color: AppColors.ink600))),
                const SizedBox(width: 10),
                Expanded(flex: 5, child: Text('${v['value']}', style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          const Divider(height: 28),
          Text('Sérülések (${damages.length})', style: heading),
          const SizedBox(height: 6),
          if (damages.isEmpty) const Text('Nincs rögzített sérülés.', style: TextStyle(color: AppColors.ink600)),
          for (final d in damages)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${d['description'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (d['location'] != null) Text('Hely: ${d['location']}'),
                  if (d['damageType'] != null) Text('Típus: ${d['damageType']}'),
                  if (d['severity'] != null) Text('Súlyosság: ${d['severity']}'),
                  _Photos(urls: (d['photoUrls'] as List? ?? const []).map((u) => '$u').toList()),
                ]),
              ),
            ),
          const Divider(height: 28),
          Text('Fotók (${photos.length})', style: heading),
          const SizedBox(height: 6),
          _Photos(urls: [for (final p in photos) '${p['url']}']),
          if (note.isNotEmpty) ...[
            const Divider(height: 28),
            const Text('Általános megjegyzés', style: heading),
            const SizedBox(height: 6),
            Text(note),
          ],
          if (signature != null) ...[
            const Divider(height: 28),
            const Text('Szignó', style: heading),
            const SizedBox(height: 6),
            Text('${signature['signerName'] ?? ''} · ${_when(signature['signedAt'])}'),
            if (signature['url'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  color: Colors.white,
                  height: 120,
                  child: Image.network('${signature['url']}', fit: BoxFit.contain, loadingBuilder: _loading, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Photos extends StatelessWidget {
  const _Photos({required this.urls});
  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: urls.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) => GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(child: InteractiveViewer(child: Image.network(urls[i], fit: BoxFit.contain, loadingBuilder: _loading))),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(urls[i], width: 96, height: 96, fit: BoxFit.cover, loadingBuilder: _loading,
                  errorBuilder: (_, __, ___) => Container(width: 96, height: 96, color: AppColors.sheet100, child: const Icon(Icons.broken_image_outlined))),
            ),
          ),
        ),
      ),
    );
  }
}

/// Amíg a kép töltődik: forgó jel a helyén (a fotók a szerverről jönnek, lassú hálózaton sokáig).
Widget _loading(BuildContext context, Widget child, ImageChunkEvent? progress) {
  if (progress == null) return child;
  final total = progress.expectedTotalBytes;
  return Container(
    width: 96,
    height: 96,
    alignment: Alignment.center,
    color: AppColors.sheet100,
    child: SizedBox(
      width: 28,
      height: 28,
      child: CircularProgressIndicator(strokeWidth: 3, value: total == null ? null : progress.cumulativeBytesLoaded / total),
    ),
  );
}
