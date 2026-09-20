import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class FileStore {
  const FileStore();

  Future<Directory> _root() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'fleet_driver_media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> persistImage(String sourcePath, {String extension = '.jpg'}) async {
    final root = await _root();
    final ext = p.extension(sourcePath).isEmpty ? extension : p.extension(sourcePath).toLowerCase();
    final target = File(p.join(root.path, '${const Uuid().v4()}$ext'));
    await File(sourcePath).copy(target.path);
    return target.path;
  }

  Future<String> persistBytes(Uint8List bytes, {String extension = '.png'}) async {
    final root = await _root();
    final target = File(p.join(root.path, '${const Uuid().v4()}$extension'));
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  Future<void> deleteIfExists(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
