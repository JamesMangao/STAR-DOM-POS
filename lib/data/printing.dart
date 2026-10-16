import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/format.dart';

/// Receipt rendering and printing (W5).
///
/// Bluetooth ESC/POS printing is gone with the APK: an installed iPad PWA talks
/// to the printer through the system print/share sheet, so a receipt is a PDF
/// page 80 mm wide and as tall as its contents. There is exactly one
/// abstraction — [ReceiptPrinter] — and two implementations, so swapping the
/// print path never touches a screen.

/// One sold line, already frozen (name/price are snapshots on the order).
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  final String name;
  final int quantity;
  final double unitPrice;
  final double lineTotal;

  String get unitLabel => Fmt.peso(unitPrice);
  String get totalLabel => Fmt.peso(lineTotal);
}

/// Everything the paper needs, and nothing about where it is printed.
class Receipt {
  const Receipt({
    required this.storeName,
    required this.orderNo,
    required this.createdAt,
    required this.lines,
    required this.total,
    this.tagline = '',
    this.receiptName = '',
    this.tin = '',
    this.address = '',
    this.accreditation = '',
    this.footer = '',
    this.subtotal,
    this.discount = 0,
    this.paymentLabel = '',
    this.amountReceived,
    this.change,
    this.referenceNo = '',
    this.note = '',
    this.deviceName = '',
    this.voided = false,
  });

  final String storeName;
  final String tagline;
  final String receiptName;
  final String tin;
  final String address;
  final String accreditation;
  final String footer;
  final String orderNo;
  final DateTime createdAt;
  final String deviceName;
  final List<ReceiptLine> lines;
  final double? subtotal;
  final double discount;
  final double total;
  final String paymentLabel;
  final double? amountReceived;
  final double? change;
  final String referenceNo;
  final String note;
  final bool voided;

  /// "Sales Receipt" — never the BIR-accreditation title (the one the import
  /// test greps the source for). This business is not accredited to issue such
  /// a receipt, and printing that title would be a false claim.
  static const String title = 'Sales Receipt';
}

/// 80 mm paper in PDF points (1 inch = 72 pt).
const double receiptWidthPt = 80 * PdfPageFormat.mm;

/// The receipt PDF. Height is computed from the content: a page taller than
/// the text would print a long blank tail on a thermal roll.
Future<Uint8List> buildReceiptPdf(Receipt r) async {
  final font = await _receiptFont();
  final bold = font;

  final height = (170 + r.lines.length * 12.5 + 150)
      .clamp(320, 2000)
      .toDouble();
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(receiptWidthPt, height),
      margin: const pw.EdgeInsets.fromLTRB(8, 10, 8, 10),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            r.receiptName.isEmpty ? r.storeName : r.receiptName,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              font: bold,
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (r.tagline.isNotEmpty)
            pw.Text(
              r.tagline,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 6.5),
            ),
          // The store row carries no invented TIN/address/PTU (import fix A8-6):
          // a line prints only when it is non-empty.
          if (r.tin.isNotEmpty)
            pw.Text(
              'TIN: ${r.tin}',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 6.5),
            ),
          if (r.address.isNotEmpty)
            pw.Text(
              r.address,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 6.5),
            ),
          if (r.accreditation.isNotEmpty)
            pw.Text(
              r.accreditation,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 6.5),
            ),
          pw.SizedBox(height: 4),
          _rule(),
          pw.Text(
            Receipt.title,
            style: pw.TextStyle(
              font: bold,
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (r.voided)
            pw.Text(
              '*** VOID ***',
              style: pw.TextStyle(
                font: bold,
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          _kv('Order', r.orderNo, font),
          _kv(
            'Date',
            '${Fmt.date(r.createdAt)} ${Fmt.time(r.createdAt)}',
            font,
          ),
          if (r.deviceName.isNotEmpty) _kv('Device', r.deviceName, font),
          _rule(),
          ...r.lines.map(
            (l) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(l.name, style: pw.TextStyle(font: font, fontSize: 7)),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      '  ${l.quantity} x ${l.unitLabel}',
                      style: pw.TextStyle(font: font, fontSize: 7),
                    ),
                    pw.Text(
                      l.totalLabel,
                      style: pw.TextStyle(
                        font: bold,
                        fontSize: 7,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _rule(),
          if (r.subtotal != null) _kv('Subtotal', Fmt.peso(r.subtotal!), font),
          if (r.discount > 0) _kv('Discount', '-${Fmt.peso(r.discount)}', font),
          _kv('TOTAL', Fmt.peso(r.total), font, bold: true),
          if (r.paymentLabel.isNotEmpty) _kv('Paid via', r.paymentLabel, font),
          if (r.amountReceived != null)
            _kv('Received', Fmt.peso(r.amountReceived!), font),
          if (r.change != null) _kv('Change', Fmt.peso(r.change!), font),
          if (r.referenceNo.isNotEmpty) _kv('Reference', r.referenceNo, font),
          if (r.note.isNotEmpty) _kv('Note', r.note, font),
          pw.SizedBox(height: 6),
          if (r.footer.isNotEmpty)
            pw.Text(
              r.footer,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: font, fontSize: 6.5),
            ),
          pw.Text(
            'Thank you!',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: font, fontSize: 7),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

/// The bundled font that actually carries ₱ (U+20B1) — Sora does not, so the
/// PDF is set in PlusJakartaSans and falls back to Helvetica rather than
/// throwing if the asset is ever missing.
Future<pw.Font> _receiptFont() async {
  try {
    final data = await rootBundle.load('assets/fonts/PlusJakartaSans.ttf');
    return pw.Font.ttf(data);
  } catch (_) {
    return pw.Font.helvetica();
  }
}

pw.Widget _rule() => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 2),
  child: pw.Container(height: 0.5, color: PdfColors.grey700),
);

pw.Widget _kv(String k, String v, pw.Font font, {bool bold = false}) => pw.Row(
  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
  children: [
    pw.Text(
      k,
      style: pw.TextStyle(
        font: font,
        fontSize: 7,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
    pw.Text(
      v,
      style: pw.TextStyle(
        font: font,
        fontSize: 7,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  ],
);

/// The one interface every print path implements.
abstract class ReceiptPrinter {
  const ReceiptPrinter();

  /// Render and hand the receipt to the platform.
  Future<void> print(Receipt receipt);
}

/// Implementation 1: the system print sheet (AirPrint on an iPad, "Save as
/// PDF" elsewhere). Nothing to configure, works offline, needs no pairing.
class PdfPrinter extends ReceiptPrinter {
  const PdfPrinter();

  @override
  Future<void> print(Receipt receipt) async {
    final bytes = await buildReceiptPdf(receipt);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: receipt.orderNo,
    );
  }
}

/// Implementation 2: the share sheet / a download. On the web
/// `Printing.sharePdf` uses the Web Share API when it exists and otherwise
/// downloads the file — which is the fallback when there is no printer at all.
class ShareReceiptPrinter extends ReceiptPrinter {
  const ShareReceiptPrinter();

  @override
  Future<void> print(Receipt receipt) async {
    final bytes = await buildReceiptPdf(receipt);
    await Printing.sharePdf(bytes: bytes, filename: '${receipt.orderNo}.pdf');
  }
}
