import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Today's order day from bestell_manager (see [OrderService]) - only exists
/// while there actually is one; "no order day" is plain null.
class OrderDay {
  const OrderDay({
    required this.title,
    required this.hostName,
    required this.statusCode,
    required this.statusLabel,
    required this.statusIcon,
    required this.url,
    required this.qrPngBase64,
    required this.qrPng,
  });

  /// E.g. "Pizzaabend bei Jürgen" - shown as "Bestellung aufgeben für <title>".
  final String title;
  final String hostName;

  /// 'starter' | 'main' | 'dessert' | 'closed'.
  final String statusCode;
  final String statusLabel;
  final String statusIcon;
  final String url;

  /// Kept alongside the decoded bytes so a re-poll with an unchanged QR code
  /// can reuse the same [qrPng] instance (see [OrderService.fetchToday]) -
  /// a new Uint8List would make Image.memory decode it again every minute.
  final String qrPngBase64;
  final Uint8List? qrPng;

  bool get isClosed => statusCode == 'closed';

  // Value equality over what's displayed, so an unchanged poll (see
  // orderDayProvider) doesn't trigger a rebuild. The QR is compared by its
  // base64 string, not the decoded bytes.
  @override
  bool operator ==(Object other) =>
      other is OrderDay &&
      other.title == title &&
      other.hostName == hostName &&
      other.statusCode == statusCode &&
      other.statusLabel == statusLabel &&
      other.statusIcon == statusIcon &&
      other.url == url &&
      other.qrPngBase64 == qrPngBase64;

  @override
  int get hashCode => Object.hash(title, hostName, statusCode, statusLabel, statusIcon, url, qrPngBase64);
}

/// One order the kitchen just marked as done (see [OrderService.fetchReady])
/// - shown in the "Bitte abholen" overlay.
class ReadyItem {
  const ReadyItem({
    required this.key,
    required this.number,
    required this.guest,
    required this.itemName,
    required this.itemIcon,
    required this.options,
    required this.ageSeconds,
  });

  /// Unique per completion - a reopened and re-completed order gets a new
  /// one, so it's announced again.
  final String key;
  final int? number;
  final String guest;
  final String itemName;
  final String itemIcon;
  final String options;

  /// How long ago it was completed, per the *server's* clock - so the
  /// radio's own clock being off doesn't matter.
  final int ageSeconds;

  /// Who to call out - the guest's name, or the order number if there's none.
  String get who => guest.isNotEmpty ? guest : (number != null ? 'Nr. $number' : '?');

  factory ReadyItem.fromJson(Map<String, dynamic> json) => ReadyItem(
    key: '${json['key']}',
    number: (json['number'] as num?)?.toInt(),
    guest: (json['guest'] as String? ?? '').trim(),
    itemName: (json['item_name'] as String? ?? '').trim(),
    itemIcon: json['item_icon'] as String? ?? '',
    options: (json['options'] as String? ?? '').trim(),
    ageSeconds: (json['age_seconds'] as num?)?.toInt() ?? 0,
  );
}

/// Outcome of one [OrderService.fetchToday] call - distinguishes the "no
/// order day" reasons only so the settings page can tell the user what's
/// wrong; the home screen treats everything except [OrderFetchResult.day]
/// the same way (no tile, weather as usual).
enum OrderFetchStatus { ok, unauthorized, error }

class OrderFetchResult {
  const OrderFetchResult(this.status, [this.day]);

  final OrderFetchStatus status;

  /// Today's order day, null if there's none (or the request failed).
  final OrderDay? day;
}

/// Reads today's order day from bestell_manager's read-only API
/// (`GET <baseUrl>/api/v1/today`, HTTP Basic auth with the host's own
/// bestell_manager e-mail + password - each host gets their own order
/// day; 401 = wrong credentials or account not activated). The kitchen's status
/// changes over the evening as courses are switched, so callers poll this
/// (see orderDayProvider); the date rolling over turns `active` false on
/// its own server-side.
class OrderService {
  static const _timeout = Duration(seconds: 10);

  Future<OrderFetchResult> fetchToday({
    required String baseUrl,
    required String user,
    required String password,
    OrderDay? previous,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/api/v1/today');
    if (uri == null || !uri.hasScheme) return const OrderFetchResult(OrderFetchStatus.error);
    try {
      final response = await http.get(uri, headers: _headers(user, password)).timeout(_timeout);
      if (response.statusCode == 401) return const OrderFetchResult(OrderFetchStatus.unauthorized);
      if (response.statusCode != 200) return const OrderFetchResult(OrderFetchStatus.error);
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (json['active'] != true) return const OrderFetchResult(OrderFetchStatus.ok);
      return OrderFetchResult(OrderFetchStatus.ok, _parse(json, previous));
    } catch (_) {
      return const OrderFetchResult(OrderFetchStatus.error);
    }
  }

  /// Orders completed in the last [seconds] (10..600, server-side limit),
  /// oldest first - or null if the request failed. Lightweight (no QR),
  /// meant for frequent polling while there's an order day.
  Future<List<ReadyItem>?> fetchReady({
    required String baseUrl,
    required String user,
    required String password,
    required int seconds,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/api/v1/ready?seconds=${seconds.clamp(10, 600)}');
    if (uri == null || !uri.hasScheme) return null;
    try {
      final response = await http.get(uri, headers: _headers(user, password)).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (json['active'] != true) return const [];
      return [
        for (final item in (json['ready'] as List? ?? const []))
          ReadyItem.fromJson((item as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers(String user, String password) => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}',
    'Accept': 'application/json',
    'User-Agent': 'home_radio/1.0',
  };

  OrderDay _parse(Map<String, dynamic> json, OrderDay? previous) {
    final status = (json['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final qrBase64 = json['qr_png_base64'] as String? ?? '';
    Uint8List? qrPng;
    if (previous != null && previous.qrPngBase64 == qrBase64) {
      qrPng = previous.qrPng;
    } else if (qrBase64.isNotEmpty) {
      try {
        qrPng = base64Decode(qrBase64);
      } on FormatException {
        qrPng = null;
      }
    }
    return OrderDay(
      title: json['title'] as String? ?? '',
      hostName: json['host_name'] as String? ?? '',
      statusCode: status['code'] as String? ?? 'closed',
      statusLabel: status['label'] as String? ?? 'Geschlossen',
      statusIcon: status['icon'] as String? ?? '',
      url: json['url'] as String? ?? '',
      qrPngBase64: qrBase64,
      qrPng: qrPng,
    );
  }
}
