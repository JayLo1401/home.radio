-   IN ARBEIT (unterbrochen 2026-11-09): rtltcp.server-Umbau, Issues
    home.radio#5 (Anmeldung raus), #4 (Protokolle umbenennen, Protokollwahl
    raus), #6 (Stick-Namen). Übersicht: rtl.over.internet#1. Noch nichts
    committet – alles liegt als Änderung im Arbeitsverzeichnis.

    Erledigt:
    - SCRAM-Anmeldung komplett entfernt (scram.cpp/.h gelöscht, aus beiden
      CMakeLists raus; RtlTcpOptions weg; JNI nativeCreateTcp(host, port);
      Kotlin DabRtlSdrPlugin/IntegratedDabEngine; Desktop radio_controller).
    - rtltcp_source.cpp sendet immer HELLO_V2, "RTL2" → Jay extended,
      "RTL0" → klassisch. auth "required" / AUTH_* → Meldung „wird nicht
      mehr unterstützt, bitte rtltcp.server im lokalen Netz verwenden“.
    - Stick-Name aus server_info.device.name in den Status-/Fehlermeldungen
      (z. B. „„Dach“ wird bereits von 192.168.1.20 verwendet“).
    - Einstellungen: RtlTcpAuth, Protokoll-Dropdown, Benutzer/Passwort-Felder
      raus. Migration SettingsRepository.removeRtlTcpLogin() (löscht
      rtl_tcp_protocol/_login/_user + Passwort im Secure Storage), läuft beim
      Start aus settingsRepositoryProvider. SecretStore.keys jetzt leer,
      neu SecretStore.delete(), AppDatabase.deleteSettings().
    - Verbindungstest: Kotlin RtlSdrPlugin + RtlTcpClient gelöscht, jetzt ein
      Dart-Client für alle Plattformen (lib/data/services/rtl_sdr_service.dart)
      mit HELLO_V2, Frame-Parser, Anzeige „Protokoll: rtl_tcp / rtl_tcp Jay
      extended“, Stick-Name, Server-Version, Statusmeldungen.
    - Neuer Test test/rtl_sdr_service_test.dart (6 Fälle, grün).
    - 2026-11-10: Empfänger-Seite kompakt neu: mehrere rtl_tcp-Server
      (Einstellung rtl_tcp_servers als JSON, rtl_sdr_host/port = Standard),
      Radio-Knopf = Standard, pro Zeile Host | Port | Testen | Ergebnis.
      Ergebnis: „Name“ · Standort · Antenne (Jay extended) bzw. „Server
      unterstützt Standort und Antenne nicht“ (rtl_tcp v1). Frequenz/
      Auto-Gain/Byte-Rate-Test entfernt.
    - Wunsch Standort + Antenne pro Gerät an rtltcp-server-d2 und
      rtl-over-internet-fc weitergegeben. Vorgeschlagenes Format:
      server_info.device.location / .antenna (Rückfall remote.site).
    - README angepasst. flutter analyze sauber, Windows-Debug-Build ok.

    Offen:
    - [x] Android-Build geprüft (2026-11-10, `flutter build apk --debug` ok).
    - [ ] Auf echter Hardware testen: klassischer rtl_tcp (Pi / Treiber-App)
          verträgt das HELLO_V2 (unbekanntes Kommando 0xF2)? Vor allem die
          Android-Treiber-App „SDR driver“ (marto) prüfen.
    - [x] Format location/antenna bestätigt (2026-11-10, rtl.over.internet
          74fe437 / docs/protocol.md Entwurf 4, mit rtltcp.server
          abgestimmt): server_info.device.location / .antenna, Freitext
          max. 100 Zeichen, leer = "". home.radio liest es bereits so.
    - [ ] Empfänger-Seite auf dem TV mit Fernbedienung durchklicken
          (Fokus Radio-Knopf → Host → Port → Testen → Entfernen).
    - [ ] #6 fertig machen, sobald die rtltcp.server-Sitzung das endgültige
          Format meldet: server_info.device.source ("usb"|"remote"),
          device.remote {instance, site}, optional `list_devices` → im
          Verbindungstest Sticks auflisten und Port per Auswahl übernehmen.
    - [ ] test/widget_test.dart schlägt fehl („Kein Sender ausgewählt“
          nicht gefunden) – war schon vor diesen Änderungen so.
    - [ ] Commit/Push mit dem Nutzer klären (keine Claude-Attribution),
          Issues #4/#5 (und #3 als hinfällig) schließen, #6 nach Abschluss.
    - [ ] devtools_options.yaml (untracked) – committen oder ignorieren?

-   ERLEDIGT (2026-10-20): Eigener DAB+-Empfänger (cpp/hrdab) statt welle.io,
    eigener RTL2832U/R820T-Treiber statt librtlsdr/libusb, Android-MediaCodec
    statt fdk-aac. Raontech-Code und alle Fremdbibliotheken entfernt.
    Offen: FM/AM (eigene Demodulation) wäre auf hrdab aufbauend möglich.

-   DAB-Sender logos sind noch immer nicht zuverlässig teilweise falsch.
    Antenne Steiermark hat Rock Antenne als Logo.
    *GRUEN-WEISS* hat garkein logo - Wahrscheinlich durch die * und !

-   Bedienung:
    Taste nächster Titel vorherioger Titel soll sender rauf und runterschalten
