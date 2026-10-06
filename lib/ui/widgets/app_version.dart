import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Az app verziója („Verzió: 1.10.2 (18)”): hibabejelentésnél ebből látszik, melyik változat fut.
class AppVersionText extends StatelessWidget {
  const AppVersionText({super.key, this.style});
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final info = snapshot.data;
          if (info == null) return const SizedBox.shrink();
          return Text('Verzió: ${info.version} (${info.buildNumber})',
              style: style ?? Theme.of(context).textTheme.bodySmall);
        },
      );
}
