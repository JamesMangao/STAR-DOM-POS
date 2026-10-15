import 'package:flutter/foundation.dart';

/// Plain-Data models (no drift) — mapped from DB rows by repositories.
/// Keep pure-Dart types only where there is no drift counterpart and no name collision.
/// All 12 tables have Drift counterparts in db.g.dart; these are the canonical types
/// used within db.dart (via part 'db.g.dart'). Other files import models.dart for
/// lightweight DTOs that avoid the Drift-generated type namespace.

@immutable
class Store {
  final String id;
  final String name;
  final String tagline;
  final String ownerId;
  final String receiptName;
  final String receiptTin;
  final String receiptAddress;
  final String receiptAccreditation;
  final String receiptFooter;
  final String currency;

  const Store({
    required this.id,
    required this.name,
    this.tagline = '',
    this.ownerId = '',
    this.receiptName = '',
    this.receiptTin = '',
    this.receiptAddress = '',
    this.receiptAccreditation = '',
    this.receiptFooter = '',
    this.currency = 'PHP',
  });
}

@immutable
class Device {
  final String id;
  final String storeId;
  final String deviceName;
  final String deviceCode;
  final bool isActive;
  final DateTime? lastSyncAt;
  final DateTime createdAt;

  const Device({
    required this.id,
    required this.storeId,
    required this.deviceName,
    required this.deviceCode,
    this.isActive = true,
    this.lastSyncAt,
    required this.createdAt,
  });
}

@immutable
class Category {
  final String id;
  final String storeId;
  final String name;
  final int sortOrder;
  final bool isActive;

  const Category({
    required this.id,
    required this.storeId,
    required this.name,
    this.sortOrder = 0,
    this.isActive = true,
  });
}

@immutable
class Product {
  final String id;
  final String storeId;
  final String? categoryId;
  final String name;
  final double price;
  final String? barcode;
  final String? imagePath;
  final int stockQuantity;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  const Product({
    required this.id,
    required this.storeId,
    this.categoryId,
    required this.name,
    required this.price,
    this.barcode,
    this.imagePath,
    this.stockQuantity = 0,
    this.isActive = true,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  Product copyWith({
    String? name,
    double? price,
    String? categoryId,
    String? barcode,
    String? imagePath,
    int? stockQuantity,
    bool? isActive,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) =>
      Product(
        id: id,
        storeId: storeId,
        categoryId: categoryId ?? this.categoryId,
        name: name ?? this.name,
        price: price ?? this.price,
        barcode: barcode ?? this.barcode,
        imagePath: imagePath ?? this.imagePath,
        stockQuantity: stockQuantity ?? this.stockQuantity,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt ?? this.deletedAt,
      );
}

@immutable
class PaymentMethod {
  final String id;
  final String storeId;
  final String name;
  final String type; // cash | ewallet | bank
  final String color;
  final String? qrImagePath;
  final String accountName;
  final String accountNumber;
  final bool requireReference;
  final bool isEnabled;
  final int sortOrder;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  const PaymentMethod({
    required this.id,
    required this.storeId,
    required this.name,
    required this.type,
    this.color = '#B70011',
    this.qrImagePath,
    this.accountName = '',
    this.accountNumber = '',
    this.requireReference = false,
    this.isEnabled = true,
    this.sortOrder = 0,
    this.updatedAt,
    this.deletedAt,
  });

  PaymentMethod copyWith({
    String? name,
    String? type,
    String? color,
    String? qrImagePath,
    String? accountName,
    String? accountNumber,
    bool? requireReference,
    bool? isEnabled,
    int? sortOrder,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) =>
      PaymentMethod(
        id: id,
        storeId: storeId,
        name: name ?? this.name,
        type: type ?? this.type,
        color: color ?? this.color,
        qrImagePath: qrImagePath ?? this.qrImagePath,
        accountName: accountName ?? this.accountName,
        accountNumber: accountNumber ?? this.accountNumber,
        requireReference: requireReference ?? this.requireReference,
        isEnabled: isEnabled ?? this.isEnabled,
        sortOrder: sortOrder ?? this.sortOrder,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt ?? this.deletedAt,
      );
}

/// Append-only. Void = order_voids event + status flip. Never edited/deleted.
@immutable
class Order {
  final String id;
  final String storeId;
  final String deviceId;
  final String orderNo;
  final double subtotal;
  final double discount;
  final double total;
  final String note;
  final String? paymentMethodId;
  final double? amountReceived;
  final double? changeAmount;
  final String referenceNo;
  final String status; // completed | voided
  final List<OrderItem> items;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? syncedAt;

  const Order({
    required this.id,
    required this.storeId,
    required this.deviceId,
    required this.orderNo,
    required this.subtotal,
    required this.discount,
    required this.total,
    this.note = '',
    this.paymentMethodId,
    this.amountReceived,
    this.changeAmount,
    this.referenceNo = '',
    this.status = 'completed',
    this.items = const [],
    required this.createdAt,
    required this.updatedAt,
    this.syncedAt,
  });
}

/// Append-only. Void = order_voids event + status. Never edited/deleted.
@immutable
class OrderVoid {
  final String id;
  final String orderId;
  final String deviceId;
  final String reason;
  final DateTime createdAt;

  const OrderVoid({
    required this.id,
    required this.orderId,
    required this.deviceId,
    required this.reason,
    required this.createdAt,
  });
}

/// Delta event — stock = sum of deltas. No absolute overwrite.
@immutable
class StockEvent {
  final String id;
  final String storeId;
  final String productId;
  final int delta;
  final String reason; // sale | adjustment | import | sync
  final String? orderId;
  final String? deviceId;
  final DateTime createdAt;

  const StockEvent({
    required this.id,
    required this.storeId,
    required this.productId,
    required this.delta,
    required this.reason,
    this.orderId,
    this.deviceId,
    required this.createdAt,
  });
}

@immutable
class Shift {
  final String id;
  final String storeId;
  final String deviceId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double? cashExpected;
  final double? cashActual;
  final double? variance;
  final String? closedBy;

  const Shift({
    required this.id,
    required this.storeId,
    required this.deviceId,
    required this.openedAt,
    this.closedAt,
    this.cashExpected,
    this.cashActual,
    this.variance,
    this.closedBy,
  });
}

/// Outbox event — id is the deterministic dedupe key.
@immutable
class OutboxEvent {
  final String id;
  final String storeId;
  final String deviceId;
  final String entity; // orders, products, ...
  final String entityId;
  final String op; // insert | update | delete | void
  final String payload; // JSON
  final int attempts;
  final String? lastError;
  final DateTime createdAt;
  final DateTime? syncedAt;

  const OutboxEvent({
    required this.id,
    required this.storeId,
    required this.deviceId,
    required this.entity,
    required this.entityId,
    required this.op,
    required this.payload,
    this.attempts = 0,
    this.lastError,
    required this.createdAt,
    this.syncedAt,
  });

  OutboxEvent copyWith({int? attempts, String? lastError, DateTime? syncedAt}) =>
      OutboxEvent(
        id: id,
        storeId: storeId,
        deviceId: deviceId,
        entity: entity,
        entityId: entityId,
        op: op,
        payload: payload,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        createdAt: createdAt,
        syncedAt: syncedAt ?? this.syncedAt,
      );
}

/// Settings item — key-value pair stored as JSON.
@immutable
class SettingsItem {
  final String storeId;
  final String key;
  final String value; // JSON
  final DateTime updatedAt;

  const SettingsItem({
    required this.storeId,
    required this.key,
    required this.value,
    required this.updatedAt,
  });
}