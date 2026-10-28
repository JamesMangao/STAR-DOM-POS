import 'dart:typed_data';

import 'picked_image.dart';

/// Non-web stub: no persistence API, no wake lock, and a download that does
/// nothing. Only reachable from `flutter test` / a VM run.
Future<bool> requestPersistentStorage() async => false;

Future<bool> acquireWakeLock() async => false;

Future<void> releaseWakeLock() async {}

void downloadFile(String filename, String mimeType, Uint8List bytes) {}

/// Non-web: there is no file picker to open and no share sheet to hand a file
/// to. Tests never upload a photo, so `null`/`false` is the honest answer.
Future<PickedImage?> pickImage({int maxDimension = 400}) async => null;

/// Non-web: no camera either.
Future<PickedImage?> pickImageFromCamera({int maxDimension = 400}) async =>
    null;

Future<bool> shareFile(
  String filename,
  String mimeType,
  Uint8List bytes,
) async => false;

bool get hasStorageManager => false;

/// Non-web stub: no OS motion setting reaches the VM. Tests that must assert
/// the reduced-motion path pass `disableAnimations` through MediaQuery instead.
bool prefersReducedMotion() => false;

/// Non-web stub: nothing to expose to a browser console.
void setBootInfo(String json) {}

/// Non-web: no PWA install prompt on VM/test.
class PwaInstallPrompt {
  PwaInstallPrompt._();
  static final PwaInstallPrompt instance = PwaInstallPrompt._();
  void listen() {}
  Future<bool> show() async => false;
  bool get isAvailable => false;
}

/// Non-web: there is no localStorage — the backup layer is a no-op and the
/// VM keeps everything in the in-memory database for the test run.
String? localStorageRead(String key) => null;

bool localStorageWrite(String key, String value) => false;

/// Non-web: no service worker, so there is never an update waiting.
void listenForAppUpdate(void Function() onReady) {}

void applyAppUpdate() {}

/// Non-web: no online/offline events. Assume online.
void listenForOnline(void Function() onOnline) {}
void listenForOffline(void Function() onOffline) {}

/// Non-web: assume online.
bool get isOnline => true;
