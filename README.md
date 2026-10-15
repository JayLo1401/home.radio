# Home Radio

Eine Flutter-App für Android-TV-Boxen: DAB+-Radio (über einen RTL-SDR-USB-Stick),
Internetradio, Wetter, Regenradar und eine Sonne-&-Mond-Kachel, bedienbar komplett
per Fernbedienung (D-Pad) auf einem großen TV.

> ⚠️ **Lizenzhinweis:** Der native DAB+-Decoder dieser App enthält Code, der aus
> mehreren GPL-/LGPL-lizenzierten Open-Source-Projekten portiert/übernommen wurde
> (siehe [Lizenz](#lizenz) unten). Vor einer öffentlichen oder kommerziellen
> Veröffentlichung (z. B. im Play Store) muss das geklärt werden - die App ist
> aktuell **nicht** ohne Weiteres als Closed-Source-Produkt vertreibbar.

## Funktionen

### DAB+-Radio
- Empfang über einen **RTL-SDR-USB-Stick** (RTL2832U-basiert, getestet mit einem
  Nooelec-Stick), wahlweise:
  - **direkt per USB** am TV-Gerät angeschlossen, oder
  - über **rtl_tcp** von einer entfernten Quelle (z. B. einem Raspberry Pi mit
    angeschlossenem Stick im selben Netzwerk) - Host/Port einstellbar.
- Vollständiger nativer OFDM-Demodulator/DAB+-Decoder (Tuning, FIC/MSC-Decoding,
  Reed-Solomon-Fehlerkorrektur, AAC-Decodierung) - kein Rückgriff auf eine externe
  DAB-App.
- **Sendersuchlauf** über Band III, gefundene Sender werden dauerhaft gespeichert
  (unabhängig von Favoriten, jederzeit erneut favorisierbar ohne neuen Suchlauf).
- **Favoriten mit Programmnummern** (wie ein klassischer Kanalplatz), gemeinsam für
  DAB+- und Internetradio-Sender, umsortierbar.
- **Senderlogos** auf zwei Arten:
  - *„via Empfang"*: tunt automatisch alle Sender durch und wartet auf ein echtes,
    über DAB+ ausgestrahltes MOT-Slideshow-Bild (authoritativ, überschreibt ein
    zuvor per Internet gesetztes Logo).
  - *Internet-Suche*: Logo-Lookup über die Radio-Browser-API, füllt nur fehlende
    Logos auf; manuelle Korrektur/Auswahl bei Fehltreffern möglich.
- Automatischer Wiederholungsversuch bei „Kein Signal!“ (jede Sekunde, ohne
  Obergrenze), solange der Sender ausgewählt bleibt.
- Live-Radiotext (DLS/PAD), Signalstärke-Anzeige (SNR), automatische
  Verstärkungsregelung (AGC) für den Tuner.
- Sortierung der Senderliste nach Ensemble oder Alphabet (ignoriert dabei
  dekorative Zeichen wie „*“/„!“ am Anfang echter Sendernamen).

### Internetradio
- Sendersuche nach Name/Genre/Land über die freie **Radio-Browser-API**
  (`api.radio-browser.info`), Ergebnisse direkt als Favorit mit Programmnummer
  speicherbar.
- Wiedergabe inkl. Live-„Now Playing“-Text (ICY-StreamTitle).

### Wetter, Regenradar, Sonne & Mond
- **Wetterprognose-Kachel**: Stundenvorhersage (Temperatur, Wind, Niederschlag)
  für den aktuellen Tag von **GeoSphere Austria** (AROME-Modell, kostenlos, ohne
  API-Key), automatische Aktualisierung alle 30 Minuten.
- **Regenradar-Kachel**: eingebettetes interaktives Regenradar von
  **wo-cloud.com**, zentriert auf den konfigurierten Standort.
- **Sonne-&-Mond-Kachel**: Sonnenaufgang/-untergang, Morgen-/Abenddämmerung,
  Sonnenhöchststand, Mondphase (alles lokal berechnet, NOAA-Sonnenstandsformeln)
  sowie der aktuelle **UV-Index** (live von **Open-Meteo**, kostenlos, ohne
  API-Key).
- Jede Kachel einzeln aktivierbar, eigene Größen-/Zoom-/Inhaltsskalierung; die
  Wetterprognose-Kachel kann wahlweise über die volle Höhe der beiden anderen
  Kacheln gehen.
- Gemeinsamer Standort (Name/Breitengrad/Längengrad) für alle drei Kacheln, frei
  editierbar (keine Geokodierung, Standardwert Graz).

### TV-/Fernbedienungsbedienung
- Vollständige D-Pad-Navigation (eigene Fokus-Reihenfolge in allen Listen/
  Einstellungsseiten).
- Medientasten der Fernbedienung (Vor/Zurück, Play/Pause/Stop) steuern
  Sender-Wechsel bzw. Wiedergabe, unabhängig vom aktuellen Fokus.
- Android-**MediaSession**-Integration: Sender erscheint als echte „Jetzt
  läuft“-Benachrichtigung, steuerbar auch über Bluetooth-Headset, Google
  Assistant oder z. B. eine Home-Assistant-Media-Player-Karte - auch im
  Hintergrund.
- Globale UI-Skalierung (0,4×-1,4×) für unterschiedliche TV-Größen/-Abstände.

### Autostart
- „Zuletzt gehörten Sender starten“ oder „Festen Sender starten“ (fest gewählter
  Favorit), konfigurierbar in den Einstellungen.

### Einstellungen
- RTL-SDR-Verbindung (eigener USB-Modus vs. rtl_tcp-Server, Host/Port,
  Geräteliste/Berechtigungen, Verbindungstest, Auto-Gain).
- DAB+-Senderverwaltung (Suchlauf, Favoriten, alle gefundenen Sender, Logos).
- Favoritenverwaltung (umsortieren, umbenennen, löschen).
- Kacheleinstellungen (siehe oben), Standort, UI-Skalierung, Uhrzeit-Datum-Anzeige.

## Zielhardware
- Android-TV-Box (Leanback-Launcher, Querformat).
- RTL2832U-basierter RTL-SDR-USB-Stick (unterstützte Tuner: E4000, FC0012,
  FC0013, FC2580, R820T/R828D via vendored `librtlsdr`).
- Optional: ein zweites Gerät (z. B. Raspberry Pi) mit angeschlossenem Stick als
  `rtl_tcp`-Quelle im Netzwerk, falls der Stick nicht direkt am TV hängt.

## Setup / Build
Normales Flutter-Projekt, keine API-Keys oder Konfigurationsdateien nötig - alle
verwendeten Wetter-/Radio-APIs sind kostenlos und schlüssellos.

```bash
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

> Der Release-Build ist aktuell noch mit dem **Debug-Keystore** signiert (siehe
> `android/app/build.gradle.kts`) - für eine echte Veröffentlichung (Play Store o.
> ä.) muss vorher ein eigener Upload-Keystore eingerichtet werden.

Für DAB+-Empfang: RTL-SDR-Stick anschließen (direkt oder über einen `rtl_tcp`-
Server im Netz) und die Verbindung unter Einstellungen → „DAB+ RTL-SDR
Einrichtung“ konfigurieren.

## Architektur (kurz)
- **State Management**: Riverpod.
- **Persistenz**: `drift` (SQLite) für Sender/Favoriten, `shared_preferences` für
  einfache Einstellungen.
- **Audio**: `just_audio`/`audio_service` für Internetradio inkl. MediaSession;
  natives `AudioTrack` für den DAB+-PCM-Ausgang.
- **DAB+-Kern**: natives C/C++ (JNI) - OFDM-Demodulation, FIC/MSC-Decoding,
  Reed-Solomon, AAC-Decodierung; angesteuert über ein Kotlin-Plugin
  (`DabRtlSdrPlugin`) und einen `MethodChannel`/`EventChannel` nach Flutter.
- **Wetter/Radar/Sonne**: reine HTTP-Aufrufe (GeoSphere Austria, Open-Meteo) bzw.
  ein eingebettetes WebView (wo-cloud.com) sowie lokal berechnete
  Sonnenstands-/Mondphasenformeln.

## Lizenz

**Es gibt aktuell keine einheitliche Projektlizenz.** Der native DAB+-Decoder
dieser App wurde durch Portierung/Übernahme von Code aus mehreren bestehenden
Open-Source-Projekten aufgebaut, jeweils mit Copyleft-Lizenzen:

| Komponente | Lizenz | Ursprung |
|---|---|---|
| DAB-Kern (OFDM/FIC/MSC, `android/app/src/main/cpp/dabcore/`) | GPL-2.0-or-later | [welle.io](https://github.com/AlbrechtL/welle.io) |
| DAB+-Superframe-Decoder (in `dabcore` sowie eigenständig in `dab_native.cpp`) | GPLv3 | [DABlin](https://github.com/opendigitalradio/dablin) |
| `Crc16.kt` | GPLv3 | DABlin |
| `EnergyDispersal.kt` | GPL-2.0 | welle.io |
| `librtlsdr` (`cpp/librtlsdr/`) | GPL-2.0 | [librtlsdr](https://github.com/steve-m/librtlsdr) |
| `libusb` (`cpp/libusb/`) | LGPL-2.1 | [libusb](https://github.com/libusb/libusb) |
| Reed-Solomon/FEC (`cpp/fec/`, `cpp/dabcore/libs/fec/`) | LGPL-2.1 | Phil Karns `libfec` |
| Raontech-Tunertreiber-Port (`RaonTunerDriver.kt`, `FigParser.kt`) | LGPL-2.1 | [hradio/omri-usb](https://github.com/hradio/omri-usb) |
| AAC-Decoder (`cpp/fdk-aac/`) | Fraunhofer-FDK-AAC-Lizenz (eigene Bedingungen, kein Patentgrant) | [fdk-aac](https://github.com/mstorsjo/fdk-aac) |
| FFT (`cpp/dabcore/libs/kiss_fft/`) | BSD-3-Clause-artig | kiss_fft |
| Alle `pubspec.yaml`-Pakete (Dart/Flutter) | MIT/BSD (permissiv) | diverse |

Alle diese Ursprünge sind direkt in den jeweiligen Quelldateien als Kommentar
dokumentiert. Bevor dieses Projekt außerhalb des privaten Gebrauchs
weitergegeben, veröffentlicht oder verkauft wird, muss mindestens:
- eine passende Projekt-`LICENSE`/`NOTICE`-Datei mit allen obigen Attributionen
  ergänzt werden,
- der vollständige Quellcode der GPL-/LGPL-Bestandteile den Empfängern der App
  zugänglich gemacht werden (GPL/LGPL verbieten keinen Verkauf, verlangen aber
  Quellcode-Verfügbarkeit),
- die Nutzung des eingebetteten wo-cloud.com-Regenradars sowie des
  FDK-AAC-Decoders (kein AAC-Patentgrant enthalten) rechtlich geprüft werden.

Näheres siehe Commit-/Code-Kommentare in `android/app/src/main/cpp/CMakeLists.txt`
und den jeweiligen Quelldateien.
