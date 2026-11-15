-   Digitale Sprache: DMR ist hörbar (erledigt, siehe unten); offen sind
    dPMR446, Yaesu Fusion (C4FM) und D-STAR.
    Stand DMR: Betriebsart „DMR“ im Funk-Fenster, „Auto“ erkennt DMR selbst
    (70-cm-Relais 438,000–440,000 und Betriebsfunk 446,2–470 stehen im
    Bandplan auf Auto). Eigener Demodulator und Rahmen nach der offenen
    ETSI-Norm TS 102 361-1/-2 (kein Code aus DSD/DSD-FME): 4FSK, Sync,
    beide Zeitschlitze (Relais über CACH), FEC (Golay, QR, Hamming, BPTC,
    RS), Sprachkopf/Ende, eingebettetes LC (Einstieg mitten im Gespräch),
    Talker Alias (Rufzeichen). Anzeige: Zeitschlitz, Farbcode, Gruppe (TG)
    oder Teilnehmer, Sender-ID, verschlüsselt (dann stumm), Notruf,
    Empfangsgüte, zuletzt gehörte Gespräche. Geprüft im Selbsttest mit
    eigenem Sender-Simulator (run_selftest.ps1 -Mode dmr) und mit einer
    Aufnahme echter Relais (439,375 und 438,350, Farbcode 1, TG 293):
    IDs, Talker Alias, Zeitschlitz und Sprachrahmen ohne Bitfehler.
    Offen bei DMR:
    - in der App am Fernseher anhören (Klang, Lautstärke im Vergleich).
    - Zeitschlitz von Hand wählen (bisher: das zuerst begonnene Gespräch).
    - Namen zu IDs und Sprechgruppen (z. B. RadioID-Liste, offline).
    - Daten (SMS, GPS), CSBK und Short LC anzeigen.
    Sprachdecoder mbelib (third_party/mbelib, ISC-Lizenz, unverändert; nur
    die AMBE+2-Teile eingebunden, für D-STAR käme ambe3600x2400.c dazu).
    Mit -DHRDAB_MBELIB=OFF baut alles ohne mbelib (DMR dann ohne Ton).
    Klang brauchbar, etwas blechern, bei schlechtem Empfang Artefakte.
    Patente: DVSI hält Patente auf AMBE+2, mbelib weist selbst darauf hin.
    In Österreich und Deutschland wirkt ein Patent nicht für private,
    nicht-gewerbliche Nutzung – für die private App geringes Risiko; bei
    Verkauf oder öffentlicher Verteilung neu bewerten (Einschätzung, keine
    Rechtsberatung). Alternative: lizenzierter DVSI-Chip per USB (AMBE-3000,
    z. B. ThumbDV).

-   Kurzwelle (HF, unter 24 MHz): schaltet auf einen Schlag ~12 Punkte frei
    (KW-Rundfunk, Morse, RTTY, Wetterfax, FT8, Zeitzeichen, Baken, …).
    Vorher klären: RTL-SDR Blog V3 (Direct Sampling) oder V4 (eingebauter
    Aufwärtsmischer)? Über rtl_tcp evtl. schon durch den Server-Treiber
    erledigt, für direkt USB in den eigenen Treiber einbauen.

-   SSTV: schöne Bilder, auf 2 m (145,500) und von der ISS (145,800).

-   VOR-Peilung und Verkehrsfunk-Kennung (TA): kleine, nette Ergänzungen.

-   TPMS (anonym): rundet die Funksensoren ab – Reifendruck ohne
    Fahrzeug-ID anzeigen bzw. nur zählen.
