import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selfUpdateAssetSuffix', () {
    test('names the arm64 APK the fork publishes', () {
      expect(selfUpdateAssetSuffix(Abi.androidArm64), 'android-arm64.apk');
    });

    test('leaves every unpublished build without an update', () {
      for (final abi in [
        Abi.androidArm,
        Abi.androidX64,
        Abi.windowsX64,
        Abi.windowsArm64,
        Abi.macosArm64,
        Abi.macosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
      ]) {
        expect(selfUpdateAssetSuffix(abi), isNull);
      }
    });
  });

  test('releaseAssetName matches the asset the fork publishes', () {
    expect(releaseAssetName('android-arm64.apk'), 'FlClash-android-arm64.apk');
  });

  group('releaseChecksum', () {
    const digest =
        'ff6a953c0f5c12e6bdc97b49428b565b64c4a62d85e50081823ba297407529b1';

    test('reads the entry sha256sum wrote for a file', () {
      final sums =
          '$digest  ./FlClash-0.9.2-android-arm64-v8a.apk\n'
          '${'0' * 64}  ./FlClash-0.9.2-windows-amd64-setup.exe\n';

      expect(
        releaseChecksum(sums, 'FlClash-0.9.2-android-arm64-v8a.apk'),
        digest,
      );
    });

    test('accepts the binary marker, upper case and CRLF', () {
      final sums = '${digest.toUpperCase()} *FlClash.apk\r\n';

      expect(releaseChecksum(sums, 'FlClash.apk'), digest);
    });

    test('answers null for a file the listing does not name', () {
      expect(releaseChecksum('$digest  ./other.apk\n', 'FlClash.apk'), isNull);
      expect(releaseChecksum('not a listing', 'FlClash.apk'), isNull);
    });
  });

  test('fileSha256 hashes the file on disk', () async {
    final directory = await Directory.systemTemp.createTemp('app_update');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/package');
    await file.writeAsString('package');

    expect(
      await fileSha256(file.path),
      sha256.convert(utf8.encode('package')).toString(),
    );
  });

  test('windowsUpdateArguments installs silently on behalf of a pid', () {
    final arguments = windowsUpdateArguments(4242).split(' ');

    expect(arguments, containsAll(['/SILENT', '/SUPPRESSMSGBOXES']));
    expect(arguments, contains('/updatefrom=4242'));
  });
}
