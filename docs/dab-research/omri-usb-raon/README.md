# Referenzmaterial: hradio/omri-usb (Raontech-Tuner-Treiber)

**Quelle:** https://github.com/hradio/omri-usb (Stand: 2026-09-15, `master`-Branch)
**Lizenz:** LGPL 2.1 (siehe `LICENSE` in diesem Ordner, Originaldatei aus dem Repo)
**Autor der Originaldateien:** Fabian Sattler / IRT GmbH, 2018

## Warum das hier liegt

Bei der Recherche zum DAB+-USB-Adapter (siehe `snug-baking-rabbit.md`-Plan, Phase 4) gefunden:
Die App **DAB-Z** (von der der Nutzer weiß, dass sie mit seinem Adapter funktioniert) nutzt als
Middleware `OMRI` (Open Mobile Radio Interface), und deren Entwickler pflegt einen Fork von
`hradio/omri-usb` – einer **offenen** C++/JNI-Bibliothek, die DAB-USB-Hardware direkt anspricht
(nicht nur die abstrakte Java-API).

`omri-usb` enthält u. a. einen kompletten Treiber für einen **Raontech-Tuner-Chip**
(`raontunerinput.cpp/.h`) – exakt die Geräteklasse "Chip-integrierter USB-DAB-Stick für
Android-Autoradios", zu der auch unser Ciciglow-DAB-004-Adapter gehört. Ob es sich um denselben
Chip handelt, ist noch nicht bestätigt (siehe "Nächste Schritte" im Plan) – aber das Protokoll-
Muster ist ein extrem wertvoller Anhaltspunkt und ggf. direkt wiederverwendbar.

## Enthaltene Dateien

- `raontunerinput.cpp` / `.h` – der eigentliche Tuner-Treiber: Power-up, Register-Lese/Schreib-
  Kommandos, Kanal-/PLL-Tabellen für DAB Band III, FIC/MSC-Auslesen, Signalstärke.
- `jusbdevice.cpp` / `.h`, `jtunerusbdevice.cpp` / `.h` – die generische Android-USB-Anbindung
  (JNI-Brücke zu `UsbManager`/`UsbDeviceConnection`), die `RaonTunerInput` nutzt.
- `dabusbtunerinput.h` – abstraktes Interface, das jeder Tuner-Treiber implementiert.

## Wichtigste Erkenntnis: Wire-Protokoll-Muster

Kommunikation läuft über **Bulk-Endpunkte** (nicht Control-Transfer!):
- `RAON_ENDPOINT_OUT = 0x02`, `RAON_ENDPOINT_IN = 0x82`
- Register schreiben: Bulk-OUT von `[0x21, 0x00, 0x00, 0x02, <reg>, <wert>]`
- Register lesen: Bulk-OUT von `[0x22, 0x00, 0x01, 0x00, <reg>]`, danach 5 Bytes Bulk-IN lesen,
  Wert steht in Byte 4.
- Page-Wechsel (Registerbank umschalten) ist ebenfalls ein Register-Write auf Register `0x03`.

## Nächste Schritte, um zu prüfen ob das zu unserem Adapter passt

1. Sobald USB-Host-Modus + Zugriff gleichzeitig möglich sind: In der App unter "DAB+ suchen" →
   Gerät öffnen → Endpunkt-Liste ansehen. Wenn dort **Bulk-Endpunkte mit Adresse `0x02` (OUT) und
   `0x82` (IN)** auftauchen, ist eine Übereinstimmung mit diesem Raontech-Treiber sehr
   wahrscheinlich.
2. Falls ja: Mit der Control-Transfer-Sonde (bzw. einer noch zu ergänzenden Bulk-Transfer-Sonde)
   das obige Schreib-/Lese-Format nachbauen und z. B. `tunerPowerUp()` (Register `0x7D` auf Seite
   `HOST=0x07` auf `0x06` setzen, dann zurücklesen) probieren.
3. Falls die Endpunkte nicht passen: Dieses Referenzmaterial bleibt trotzdem hilfreich als Vorlage
   für das allgemeine Vorgehen (Register-Konzept, Page-Umschaltung, FIC/MSC-Handling), auch wenn
   die konkreten Bytes für unseren Chip anders sind.

## Lizenzhinweis

Diese Dateien sind unverändert aus `hradio/omri-usb` übernommen (LGPL 2.1). Bei Wiederverwendung
von Code daraus in `DabUsbPlugin.kt` (z. B. als abgeleiteter/adaptierter Kotlin-Code) muss die
LGPL-2.1-Herkunft weiterhin vermerkt bleiben.
