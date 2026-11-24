import '../l10n/l10n.dart';

/// The receiver's native code (hrdab, rtl_tcp source, libusb - C++/Kotlin)
/// reports its state in German ("„Stick“ bereit", "… wird bereits von …
/// verwendet"). Dart recognises those texts by German parts (connection
/// chain, home screen), so they stay German inside; this turns them into
/// English only for showing.
String nativeMessageText(String message) {
  if (l10n.localeName == 'de' || message.isEmpty) return message;
  var m = message;
  for (final (pattern, replacement) in _rules) {
    m = m.replaceAllMapped(pattern, (match) => replacement(match));
  }
  return m;
}

String Function(Match) _fixed(String text) =>
    (_) => text;
String Function(Match) _withGroup(String Function(String g) f) =>
    (m) => f(m.group(1) ?? '');

final _rules = <(RegExp, String Function(Match))>[
  (RegExp('USB-Stick am rtl_tcp-Server'), _fixed('USB stick on the rtl_tcp server')),
  (
    RegExp(
      'rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt\\. '
      'Bitte den rtltcp\\.server im lokalen Netz verwenden\\.',
    ),
    _fixed(
      'The rtl_tcp server asks for a login, which is no longer supported. '
      'Please use rtltcp.server in the local network.',
    ),
  ),
  (RegExp(' wird bereits von einem anderen Gerät verwendet'), _fixed(' is already used by another device')),
  (RegExp(' wird bereits von (.+) verwendet'), _withGroup((g) => ' is already used by $g')),
  (RegExp('Vom rtl_tcp-Server getrennt'), _fixed('Disconnected from the rtl_tcp server')),
  (RegExp('rtl_tcp-Server meldet einen Protokollfehler'), _fixed('The rtl_tcp server reports a protocol error')),
  (RegExp('Empfänger am rtl_tcp-Server startet …'), _fixed('Receiver on the rtl_tcp server is starting …')),
  (RegExp(' getrennt – verbinde neu …'), _fixed(' disconnected – reconnecting …')),
  (RegExp(' nicht bereit'), _fixed(' not ready')),
  (RegExp(' startet …'), _fixed(' is starting …')),
  (RegExp(' bereit\$'), _fixed(' ready')),
  (
    RegExp('rtl_tcp-Server (\\S+) hat die Verbindung abgelehnt'),
    _withGroup((g) => 'rtl_tcp server $g refused the connection'),
  ),
  (RegExp('rtl_tcp-Quelle (\\S+) nicht erreichbar'), _withGroup((g) => 'rtl_tcp source $g not reachable')),
  (RegExp('Verbindung zur rtl_tcp-Quelle hergestellt'), _fixed('Connected to the rtl_tcp source')),
  (RegExp('Verbindung zur rtl_tcp-Quelle verloren'), _fixed('Connection to the rtl_tcp source lost')),
  (RegExp('USB-Übertragung konnte nicht gestartet werden'), _fixed("USB transfer couldn't be started")),
  (RegExp('USB-Stick getrennt'), _fixed('USB stick disconnected')),
  (RegExp('USB-Zugriff \\(libusb\\) nicht verfügbar'), _fixed('USB access (libusb) not available')),
  (RegExp('Kein RTL-SDR-Stick gefunden'), _fixed('No RTL-SDR stick found')),
  (RegExp('Kein Zugriff auf den RTL-SDR-Stick'), _fixed('No access to the RTL-SDR stick')),
  (RegExp('RTL-SDR-Stick braucht den WinUSB-Treiber'), _fixed('The RTL-SDR stick needs the WinUSB driver')),
  (RegExp('RTL-SDR-Stick lässt sich nicht öffnen'), _fixed("The RTL-SDR stick can't be opened")),
  (
    RegExp('RTL-SDR-Stick wird von einem anderen Programm verwendet'),
    _fixed('The RTL-SDR stick is used by another program'),
  ),
  (RegExp('RTL-SDR-Stick: Schnittstelle belegt'), _fixed('RTL-SDR stick: interface busy')),
  (
    RegExp('RTL-SDR-Stick antwortet nicht oder hat keinen unterstützten Tuner'),
    _fixed("The RTL-SDR stick doesn't answer or has no supported tuner"),
  ),
];
