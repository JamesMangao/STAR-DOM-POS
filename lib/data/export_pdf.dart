import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../data/db.dart';
import '../data/logic.dart';

/// A sales report PDF for a chosen time range.
///
/// Built entirely offline from the local database, then downloaded through the
/// browser's downloadFile (web) so nothing touches a printer or a server.
class ExportPdf {
  ExportPdf._();
  static final ExportPdf instance = ExportPdf._();

  /// Build a sales report for [store], covering [start] to [end] (UTC, end
  /// exclusive), with [storeName] printed on the header.
  Future<Uint8List> build({
    required String storeName,
    required String periodLabel,
    required List<Order> activeOrders,
    required List<Order> voidedOrders,
    required List<OrderItem> items,
    required List<Payment> payments,
  }) async {
    final font = await _reportFont();
    final bold = font;

    final total = Money.sum(activeOrders.map((o) => o.total));
    final voidedTotal = Money.sum(voidedOrders.map((o) => o.total));
    final activeCount = activeOrders.length;
    final voidedCount = voidedOrders.length;
    final crimson = PdfColor.fromHex('B70011');

    // Group active orders by payment method (snapshot name).
    final byMethod = <String, (double total, int count)>{};
    for (final o in activeOrders) {
      final p = payments.firstWhere(
        (p) => p.orderId == o.id,
        orElse: () => Payment(
          id: '',
          storeId: '',
          deviceId: '',
          orderId: o.id,
          methodId: '',
          methodName: 'Cash',
          methodType: 'cash',
          amount: o.total,
          referenceNo: '',
          createdAt: o.createdAt,
        ),
      );
      final key = p.methodName.isEmpty ? 'Cash' : p.methodName;
      final prev = byMethod[key] ?? (0, 0);
      byMethod[key] = (Money.round(prev.$1 + o.total), prev.$2 + 1);
    }

    // Sort methods by total descending.
    final sortedMethods = byMethod.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // -------- Header --------
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      storeName.isEmpty ? 'Stardom' : storeName,
                      style: pw.TextStyle(
                        font: bold,
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: crimson,
                      ),
                    ),
                    pw.Text(
                      'Sales Report',
                      style: pw.TextStyle(
                        font: bold,
                        fontSize: 26,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'Stardom POS · Offline-first booth sales',
                      style: pw.TextStyle(font: font, fontSize: 9),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      periodLabel,
                      style: pw.TextStyle(
                        font: bold,
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'Generated ${Fmt.date(DateTime.now())} ${Fmt.time(DateTime.now())}',
                      style: pw.TextStyle(font: font, fontSize: 8),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            _rule(font),

            // -------- KPI summary --------
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _kpiCard(font, bold, 'Total sales', Fmt.peso(total)),
                _kpiCard(font, bold, 'Sales', '$activeCount'),
                _kpiCard(font, bold, 'Voided', '$voidedCount', color: crimson),
                _kpiCard(
                  font,
                  bold,
                  'Net sales',
                  Fmt.peso(total - voidedTotal),
                ),
              ],
            ),
            pw.SizedBox(height: 16),

            // -------- By payment method --------
            pw.Text(
              'Sales by payment method',
              style: pw.TextStyle(
                font: bold,
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            if (sortedMethods.isEmpty)
              pw.Text(
                'No sales in this period.',
                style: pw.TextStyle(font: font, fontSize: 9),
              )
            else
              ...sortedMethods.map(
                (e) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        e.key,
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        '${e.value.$2} sale${e.value.$2 == 1 ? '' : 's'}',
                        style: pw.TextStyle(font: font, fontSize: 8),
                      ),
                      pw.Text(
                        Fmt.peso(e.value.$1),
                        style: pw.TextStyle(
                          font: bold,
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            pw.SizedBox(height: 16),
            _rule(font),

            // -------- Detailed orders --------
            pw.Text(
              'Order detail',
              style: pw.TextStyle(
                font: bold,
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            if (activeOrders.isEmpty && voidedOrders.isEmpty)
              pw.Text(
                'No orders in this period.',
                style: pw.TextStyle(font: font, fontSize: 9),
              )
            else ...[
              ...activeOrders.map(
                (o) => _orderRow(
                  font,
                  bold: bold,
                  crimson: crimson,
                  orderNo: o.orderNo,
                  date: '${Fmt.date(o.createdAt)} ${Fmt.time(o.createdAt)}',
                  total: Fmt.peso(o.total),
                  status: 'Completed',
                ),
              ),
              if (voidedOrders.isNotEmpty)
                pw.Text(
                  'Voided',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: crimson,
                  ),
                ),
              ...voidedOrders.map(
                (o) => _orderRow(
                  font,
                  bold: bold,
                  crimson: crimson,
                  orderNo: o.orderNo,
                  date: '${Fmt.date(o.createdAt)} ${Fmt.time(o.createdAt)}',
                  total: Fmt.peso(o.total),
                  status: 'Voided',
                ),
              ),
            ],
            pw.SizedBox(height: 16),

            // -------- Items sold --------
            if (items.isNotEmpty) ...[
              pw.Text(
                'Items sold',
                style: pw.TextStyle(
                  font: bold,
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              ..._itemRows(font, crimson, items),
              pw.SizedBox(height: 16),
              _rule(font),
            ],

            // -------- Footer --------
            pw.Text(
              'Stardom POS — sales report',
              style: pw.TextStyle(font: font, fontSize: 8),
            ),
            pw.Text(
              'This report is generated offline from the iPad. Voided orders '
              'are listed for reference and are excluded from totals.',
              style: pw.TextStyle(font: font, fontSize: 7),
            ),
          ],
        ),
      ),
    );
    return doc.save();
  }

  pw.Widget _rule(pw.Font font) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 6),
    child: pw.Container(height: 0.5, color: PdfColors.grey700),
  );

  pw.Widget _kpiCard(
    pw.Font font,
    pw.Font bold,
    String label,
    String value, {
    PdfColor? color,
  }) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              label,
              style: pw.TextStyle(
                font: font,
                fontSize: 7.5,
                color: PdfColors.grey600,
              ),
            ),
            pw.Text(
              value,
              style: pw.TextStyle(
                font: bold,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: color ?? PdfColors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _orderRow(
    pw.Font font, {
    required pw.Font bold,
    required PdfColor crimson,
    required String orderNo,
    required String date,
    required String total,
    required String status,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              orderNo,
              style: pw.TextStyle(
                font: font,
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(date, style: pw.TextStyle(font: font, fontSize: 7.5)),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              total,
              style: pw.TextStyle(
                font: font,
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              status,
              style: pw.TextStyle(
                font: font,
                fontSize: 7.5,
                color: status == 'Voided' ? crimson : PdfColors.green,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  List<pw.Widget> _itemRows(
    pw.Font font,
    PdfColor crimson,
    List<OrderItem> items,
  ) {
    final byProduct =
        <String, ({String name, double unit, int qty, double total})>{};
    for (final it in items) {
      final key = it.productId ?? it.productName;
      final prev =
          byProduct[key] ??
          (name: it.productName, unit: 0.0, qty: 0, total: 0.0);
      byProduct[key] = (
        name: it.productName,
        unit: prev.unit,
        qty: prev.qty + it.quantity,
        total: Money.round(prev.total + it.lineTotal),
      );
    }
    return byProduct.values
        .map(
          (e) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(e.name, style: pw.TextStyle(font: font, fontSize: 8)),
                pw.Text(
                  '${e.qty} × ${Fmt.peso(e.unit)}',
                  style: pw.TextStyle(font: font, fontSize: 8),
                ),
                pw.Text(
                  Fmt.peso(e.total),
                  style: pw.TextStyle(
                    font: font,
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        )
        .toList();
  }

  Future<pw.Font> _reportFont() async {
    try {
      final data = await rootBundle.load('assets/fonts/PlusJakartaSans.ttf');
      return pw.Font.ttf(data);
    } catch (_) {
      return pw.Font.helvetica();
    }
  }
}
