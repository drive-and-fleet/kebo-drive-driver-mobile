#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()

manifest = root / 'android/app/src/main/AndroidManifest.xml'
if manifest.exists():
    s = manifest.read_text()
    marker = '<application'
    permissions = (
        '    <uses-permission android:name="android.permission.INTERNET" />\n'
        '    <uses-permission android:name="android.permission.CAMERA" />\n'
    )
    if 'android.permission.INTERNET' not in s:
        s = s.replace(marker, permissions + marker, 1)
    manifest.write_text(s)

debug_manifest = root / 'android/app/src/debug/AndroidManifest.xml'
if debug_manifest.exists():
    s = debug_manifest.read_text()
    if 'usesCleartextTraffic' not in s:
        if '<application' in s:
            s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
        elif '</manifest>' in s:
            s = s.replace('</manifest>', '    <application android:usesCleartextTraffic="true" />\n</manifest>')
    if 'xmlns:android=' not in s:
        s = s.replace('<manifest', '<manifest xmlns:android="http://schemas.android.com/apk/res/android"', 1)
    debug_manifest.write_text(s)

plist = root / 'ios/Runner/Info.plist'
if plist.exists():
    s = plist.read_text()
    if 'NSCameraUsageDescription' not in s:
        s = s.replace(
            '</dict>',
            '\t<key>NSCameraUsageDescription</key>\n'
            '\t<string>A jármű és a sérülések dokumentálásához kamera-hozzáférés szükséges.</string>\n'
            '</dict>',
            1,
        )
    plist.write_text(s)
