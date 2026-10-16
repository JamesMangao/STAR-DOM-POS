import 'package:intl/intl.dart';

/// ₱ currency, order numbers, and date formats.
class Fmt {
  Fmt._();

  static final _peso = NumberFormat('#,##0.00', 'en_PH');

  /// ₱1,234.00 — tabular numerals, 2 decimals.
  static String peso(num v) => '₱${_peso.format(v)}';

  // order_no and the YYMMDD day key live in OrderNo (data/logic.dart), which
  // takes the STORE-LOCAL day (B8). A second formatter here silently used the
  // UTC day, so it is gone.

  static String time(DateTime t) => DateFormat('h:mm a').format(t);

  static String date(DateTime t) => DateFormat('MMM d, yyyy').format(t);
}
