import 'dart:typed_data';

/// Non-web stub: no persistence API, no wake lock, and a download that does
/// nothing. Only reachable from `flutter test` / a VM run.
Future<bool> requestPersistentStorage() async => false;

Future<bool> acquireWakeLock() async => false;

Future<void> releaseWakeLock() async {}

void downloadFile(String filename, String mimeType, Uint8List bytes) {}

bool get hasStorageManager => false;

/// Non-web stub: nothing to expose to a browser console.
void setBootInfo(String json) {}
