# Home Radio

Eine Flutter-App für Android-TV-Boxen: DAB+-Radio (über einen RTL-SDR-USB-Stick),
Internetradio, Wetter, Regenradar und eine Sonne-&-Mond-Kachel, bedienbar komplett
per Fernbedienung (D-Pad) auf einem großen TV.

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
- **Wetterradar-Kachel**: eigenes, selbst gezeichnetes Radar aus offenen Daten
  auf einer grünen Reliefkarte (Copernicus-Höhenmodell, Natural-Earth-Grenzen,
  -Seen, -Flüsse und -Orte):
  - Wolken weiß bis grau (EUMETSAT-Satellit, Infrarot + Wolkenmaske, 10 Minuten),
  - Niederschlag nach Art und Intensität aus dem GeoSphere-Nowcast (INCA, 1 km,
    15 Minuten, Österreich und Umgebung): Regen hell- bis dunkelblau, Schnee rosa
    mit Schneeflocken, Schneeregen lila, gefrierender Regen rot, ab 50 mm/h
    violett („Hagel möglich“ - der Datensatz kennt keinen eigenen Hagel),
  - Blitze der letzten 5 Minuten als gelbe Punkte, größer und orange/rot bei
    starker Aktivität (EUMETSAT MTG Lightning Imager; Erd- und Wolkenblitze
    unterscheidet der Satellit nicht),
  - Hinweise „Blitze x km“ und „Böen x km/h“ für den Standort.
  Der gezeigte Umkreis um den Standort ist einstellbar (10 bis 500 km).
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
- RTL2832U-basierter RTL-SDR-USB-Stick mit R820T-, R820T2- oder R828D-Tuner
  (eigener Treiber, siehe `cpp/hrdab/rtl2832.cpp`). Über `rtl_tcp` geht jeder
  Stick, den der Server unterstützt.
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

> Der Release-Build wird mit dem gemeinsamen jaycloud-Schlüssel signiert
> (`android/key.properties` oder `../keystore/signing.properties` neben dem
> Projekt, nie im Git - siehe `android/app/build.gradle.kts`). Fehlt beides,
> wird mit dem Debug-Keystore signiert.

Für DAB+-Empfang: RTL-SDR-Stick anschließen (direkt oder über einen `rtl_tcp`-
Server im Netz) und die Verbindung unter Einstellungen → „DAB+ RTL-SDR
Einrichtung“ konfigurieren.

## Architektur (kurz)
- **State Management**: Riverpod.
- **Persistenz**: `drift` (SQLite) für Sender/Favoriten, `shared_preferences` für
  einfache Einstellungen.
- **Audio**: `just_audio`/`audio_service` für Internetradio inkl. MediaSession;
  für DAB+ dekodiert Androids eigener AAC-Decoder (`MediaCodec`) die
  Audio-Units, Ausgabe über `AudioTrack` mit Vorpuffer und Taktausgleich
  (`DabAacPlayer`).
- **DAB+-Empfänger** (`android/app/src/main/cpp/hrdab/`, eigener Code nach ETSI
  EN 300 401 / TS 102 563 / TS 101 756): OFDM-Synchronisation und
  -Demodulation, FIC/MSC, Viterbi, Reed-Solomon, DAB+-Superframes, DLS und
  MOT-Slideshow, dazu ein RTL2832U/R820T-Treiber direkt über usbfs und ein
  `rtl_tcp`-Client; angesteuert über `IntegratedDabEngine`/`DabRtlSdrPlugin`
  und einen `MethodChannel`/`EventChannel` nach Flutter. Ein Sender-Simulator
  mit Selbsttest liegt in `android/app/src/test_native/hrdab/`
  (`run_selftest.ps1`, läuft per adb auf einem Android-Gerät).
- **Wetter/Radar/Sonne**: reine HTTP-Aufrufe (GeoSphere Austria, Open-Meteo,
  EUMETView) sowie lokal berechnete Sonnenstands-/Mondphasenformeln. Das Radar
  liest die Nowcast-netCDF-Dateien mit einem eigenen, minimalen HDF5-Leser
  (`lib/data/services/hdf5_lite.dart`); die Karte ist ein aus Natural Earth
  erzeugtes Asset (`assets/map/alpine_basemap.json`, Skript
  `tools/make_basemap.py`).

## Lizenz

[PolyForm Noncommercial 1.0.0](LICENSE.md). Der Quellcode ist offen einsehbar.
Nutzung und Änderung sind für private und nicht-kommerzielle Zwecke frei, auch für
Vereine, Schulen und gemeinnützige Organisationen. **Kommerzielle Nutzung ist nicht
erlaubt**, z. B. Home Radio zu verkaufen, als bezahlten Dienst anzubieten oder in
kommerzielle Produkte einzubauen. Für eine kommerzielle Lizenz bitte über GitHub
anfragen.

Der DAB+-Empfänger (`android/app/src/main/cpp/hrdab/`) ist eigener Code nach den
öffentlichen ETSI-Normen, es ist kein fremder Quellcode eingebunden. AAC/HE-AAC
dekodiert der auf dem Android-Gerät vorhandene Decoder (`MediaCodec`). Die
Flutter-/Dart-Pakete aus `pubspec.yaml` stehen unter ihren eigenen (permissiven)
Lizenzen.

Genutzte Daten und Dienste (Quellenangaben in der App unter Einstellungen → Über):

- Wetterprognose: [GeoSphere Austria](https://data.hub.geosphere.at/),
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- UV-Index: [Open-Meteo.com](https://open-meteo.com/), CC BY 4.0, freie API nur
  für nicht-kommerzielle Nutzung.
- Internetradio-Suche und -Logos: [Radio Browser](https://www.radio-browser.info/)
  (Community-Verzeichnis).
- Wetterradar: Niederschlag, Niederschlagsart und Böen von GeoSphere Austria
  (Nowcast, CC BY 4.0); Wolken und Blitze © EUMETSAT (MSG Cloud Mask, MTG FCI
  IR 10.5, MTG Lightning Imager über EUMETView, ohne Gebühren); Grenzen, Seen,
  Flüsse, Orte [Natural Earth](https://www.naturalearthdata.com/) (gemeinfrei);
  Relief „produced using Copernicus WorldDEM-90 © DLR e.V. 2010-2014 and © Airbus
  Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union
  and ESA; all rights reserved“ (`tools/make_relief.py`).
