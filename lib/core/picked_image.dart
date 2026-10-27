import 'dart:typed_data';

/// One image the cashier picked from the iPad's photo library, already
/// downscaled to ≤400 px by the web implementation (device rule: product art
/// is never stored at 2000 px in a 3 GB iPad tab) and ready to upload to the
/// `pos-assets` bucket.
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.mime,
    required this.filename,
  });

  final Uint8List bytes;

  /// `image/webp`, `image/png`, … as the encoder actually produced it.
  final String mime;

  final String filename;

  /// Object path extension for `pos-assets` ('webp' / 'png' / 'jpg').
  String get extension {
    switch (mime) {
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      default:
        return 'webp';
    }
  }
}
