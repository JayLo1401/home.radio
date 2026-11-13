import 'dart:typed_data';

/// One ACARS message (ARINC 618) as the receiver's decoder delivers it:
/// SOH, mode, registration, ack, label, block id, [STX text] ETX/ETB, BCS.
class AcarsMessage {
  final DateTime receivedAt;
  final int freqHz;
  final String mode;

  /// Aircraft registration, e.g. "D-AIZA" (leading dots removed).
  final String registration;
  final String label;
  final String blockId;

  /// Downlink (aircraft -> ground) carries a message number and flight id.
  final bool downlink;
  final String? messageNo;
  final String? flight;
  final String text;
  final bool more; // ended with ETB: continued in the next block

  const AcarsMessage({
    required this.receivedAt,
    required this.freqHz,
    required this.mode,
    required this.registration,
    required this.label,
    required this.blockId,
    required this.downlink,
    required this.messageNo,
    required this.flight,
    required this.text,
    required this.more,
  });

  /// What the label means, for the common ones.
  String get labelName => acarsLabelName(label);
}

String acarsLabelName(String label) => switch (label) {
      '_\x7f' => 'Quittung (ohne Inhalt)',
      'Q0' => 'Verbindungstest',
      'H1' => 'Bordrechner (FMS/Wartung)',
      'SA' => 'Systemstatus',
      '5Z' => 'Airline-Meldung',
      '10' || '11' || '12' || '13' || '14' || '15' || '16' || '17' => 'Flugdaten',
      '80' || '81' || '82' || '83' => 'Airline-Meldung',
      _ => 'Meldung',
    };

/// The frame bytes of an ACARS `nbPacket` event (kind 2).
Uint8List? acarsFrameFromEvent(Map<String, dynamic> event) {
  final data = event['data'];
  if (data is Uint8List) return data;
  if (data is List) return Uint8List.fromList(data.cast<int>());
  final hex = event['hex'] as String?;
  if (hex == null || hex.length.isOdd) return null;
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Parses a message (parity bits are stripped here); null if too short.
AcarsMessage? parseAcars(Uint8List raw, {required int freqHz, DateTime? at}) {
  // Without the two BCS bytes; 7-bit characters.
  if (raw.length < 16) return null;
  final b = [for (final x in raw.sublist(0, raw.length - 2)) x & 0x7F];
  if (b[0] != 0x01) return null;
  String chars(int from, int to) => String.fromCharCodes(b.sublist(from, to));
  final mode = chars(1, 2);
  final registration = chars(2, 9).replaceAll('.', '').trim();
  final label = chars(10, 12);
  final blockId = chars(12, 13);
  final end = b.last; // ETX or ETB
  var text = '';
  String? messageNo, flight;
  final downlink = RegExp('[0-9]').hasMatch(blockId);
  if (b.length > 14 && b[13] == 0x02) {
    text = chars(14, b.length - 1);
    if (downlink && text.length >= 10) {
      messageNo = text.substring(0, 4);
      flight = text.substring(4, 10).trim();
      text = text.substring(10);
    }
  }
  return AcarsMessage(
    receivedAt: at ?? DateTime.now(),
    freqHz: freqHz,
    mode: mode,
    registration: registration,
    label: label,
    blockId: blockId,
    downlink: downlink,
    messageNo: messageNo,
    flight: flight == null || flight.isEmpty ? null : flight,
    text: text.replaceAll('\r', '').trim(),
    more: end == 0x17,
  );
}
