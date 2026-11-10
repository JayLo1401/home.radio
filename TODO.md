-   rtltcp.server-Umbau (rtl.over.internet#1): #4, #5 erledigt (7d7ddc2),
    #6 umgesetzt (Stick-Name, Standort, Antenne, Herkunft, Stick-Auswahl über
    das Info-HELLO "RTLI"). Offen:
    - [ ] Auf echter Hardware testen: klassischer rtl_tcp (Pi / Treiber-App)
          verträgt HELLO_V2 und RTLI (unbekanntes Kommando 0xF2)? Vor allem
          die Android-Treiber-App „SDR driver“ (marto) prüfen.
    - [ ] Empfänger-Seite auf dem TV mit Fernbedienung durchklicken
          (Standard-Knopf → Host → Port → Testen → Stick wählen → Entfernen).
    - [ ] test/widget_test.dart schlägt fehl („Kein Sender ausgewählt“
          nicht gefunden) – war schon vor dem Umbau so.
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
