-   ENTSCHIEDEN (2026-09-17): Umstieg von Raontech-USB-Stick auf RTL-SDR
    (Nooelec v5, kommt an). Grund: nach sehr ausführlicher Fehlersuche
    (Register/Timing/USB-Protokoll 1:1 mit funktionierender Referenz-App
    verglichen, kein Unterschied gefunden) bleibt der Datendurchsatz bei der
    Wiedergabe zu niedrig für lückenlosen Ton.
    Plan: DAB+ über rtl_tcp-Protokoll (konfigurierbar: localhost mit
    Treiber-App, oder externe IP z.B. Raspberry Pi als Server) + welle.io-
    Kern als native Bibliothek für die eigentliche Demodulation. Zusätzlich
    FM/AM geplant (eigene, einfachere Demodulation, welle.io kann das nicht).
    Fortschritt: RtlTcpClient.kt (Protokoll-Client) gebaut und gegen echten
    librtlsdr-Quellcode verifiziert, noch nicht mit echter Hardware getestet.
    Alter Raontech-Code bleibt vorerst im Projekt (nicht mehr aktiv
    weiterverfolgt), bis RTL-SDR-Pfad funktioniert.

-   DAB Sender kein TON (Raontech-Stick, siehe Eintrag oben - wird nicht mehr verfolgt)

-   DAB-Sender logos sind noch immer nicht zuverlässig teilweise falsch.
    Antenne Steiermark hat Rock Antenne als Logo.
    *GRUEN-WEISS* hat garkein logo - Wahrscheinlich durch die * und !

-   Bedienung:
    Taste nächster Titel vorherioger Titel soll sender rauf und runterschalten
