-   Digitale Sprache (DMR, dPMR, Yaesu Fusion, D-STAR) hörbar machen –
    zuerst DMR (Amateurfunk-Relais 70 cm, 438,650–439,425; DMR446/dPMR446).
    Variante 1: Freie Nachbildung mbelib
    - mbelib ist eine offene Nachbildung der AMBE/IMBE-Sprachdecoder in C.
      Sie kann AMBE+2 (DMR, dPMR, Yaesu Fusion) und AMBE (D-STAR). Alle
      bekannten freien Programme nutzen sie, z. B. DSD, DSD-FME und SDR++ mit
      Plugin.
    - Klangqualität brauchbar, aber hörbar schlechter als das Original: etwas
      blechern, bei schlechtem Empfang mit Artefakten.
    - Lizenz des Codes: mbelib selbst steht unter einer sehr freien Lizenz
      (ISC-artig), unproblematisch. Viele Programme drumherum (z. B. DSD-FME)
      sind GPL – den DMR-Teil daher selbst nach der offenen ETSI-Norm
      (TS 102 361) schreiben und nur mbelib übernehmen.
    - Patente: die eigentliche Grauzone. Der Hersteller DVSI hält Patente auf
      das Verfahren; ein Teil der älteren ist abgelaufen, für AMBE+2 ist die
      Lage nicht eindeutig. mbelib weist selbst darauf hin, dass die Nutzung
      patentrechtlich eingeschränkt sein kann. In Österreich und Deutschland
      wirkt ein Patent grundsätzlich nicht für private, nicht-gewerbliche
      Nutzung – für die private App ist das Risiko daher gering. Bei Verkauf
      oder öffentlicher Verteilung sähe das anders aus. (Einschätzung, keine
      Rechtsberatung.)
    - Davor nötig: eigener DMR-Demodulator (4FSK, Sync, Zeitschlitze, FEC);
      Zwischenstufe ohne Ton möglich (Teilnehmer-/Gruppen-ID, Relais).
    Alternative: lizenzierter DVSI-Chip per USB (AMBE-3000, z. B. ThumbDV).

-   Kurzwelle (HF, unter 24 MHz): schaltet auf einen Schlag ~12 Punkte frei
    (KW-Rundfunk, Morse, RTTY, Wetterfax, FT8, Zeitzeichen, Baken, …).
    Vorher klären: RTL-SDR Blog V3 (Direct Sampling) oder V4 (eingebauter
    Aufwärtsmischer)? Über rtl_tcp evtl. schon durch den Server-Treiber
    erledigt, für direkt USB in den eigenen Treiber einbauen.

-   SSTV: schöne Bilder, auf 2 m (145,500) und von der ISS (145,800).

-   VOR-Peilung und Verkehrsfunk-Kennung (TA): kleine, nette Ergänzungen.

-   TPMS (anonym): rundet die Funksensoren ab – Reifendruck ohne
    Fahrzeug-ID anzeigen bzw. nur zählen.
