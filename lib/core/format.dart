import 'package:intl/intl.dart';

/// ₱ currency, order numbers, and date formats.
class Fmt {
  Fmt._();

  static final _peso = NumberFormat('#,##0.00', 'en_PH');

  /// ₱1,234.00 — tabular numerals, 2 decimals.
  static String peso(num v) => '₱${_peso.format(v)}';

  /// {device_code}-{YYMMDD}-{seq} — seq zero-padded to 3.
  static String orderNo(String deviceCode, DateTime now, int seq) {
    final y = now.year % 100;
    final m = now.month;
    final d = now.day;
    final ymd = '${y.toString().padLeft(2, '0')}${m.toString().padLeft(2, '0')}${d.toString().padLeft(2, '0')}';
    return '$deviceCode-$ymd-${seq.toString().padLeft(3, '0')}';
  }

  /// YYMMDD key for per-day order sequences.
  static String dayKey(DateTime now) =>
      orderNo('', now, 0).split('-')[1];

  static String time(DateTime t) => DateFormat('h:mm a').format(t);

  static String date(DateTime t) => DateFormat('MMM d, yyyy').format(t);
}
