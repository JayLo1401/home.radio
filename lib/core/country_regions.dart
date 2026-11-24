import '../l10n/l10n.dart';

/// World regions for narrowing the internet radio search's country list -
/// otherwise one dropdown of ~200 countries, a long way down with a remote.
enum WorldRegion {
  europe,
  northAmerica,
  southAmerica,
  asia,
  africa,
  oceania,
  other;

  /// The region's name in the app's language.
  String get label => switch (this) {
        WorldRegion.europe => l10n.miscRegionEurope,
        WorldRegion.northAmerica => l10n.miscRegionNorthAmerica,
        WorldRegion.southAmerica => l10n.miscRegionSouthAmerica,
        WorldRegion.asia => l10n.miscRegionAsia,
        WorldRegion.africa => l10n.miscRegionAfrica,
        WorldRegion.oceania => l10n.miscRegionOceania,
        WorldRegion.other => l10n.miscRegionOther,
      };
}

const _codesByRegion = <WorldRegion, String>{
  WorldRegion.europe: 'AD AL AM AT AX AZ BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GB GE GG GI GR HR HU IE IM IS '
      'IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM TR UA VA XK',
  WorldRegion.northAmerica: 'AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX '
      'NI PA PM PR SV SX TC TT US VC VG VI',
  WorldRegion.southAmerica: 'AR BO BR CL CO EC FK GF GY PE PY SR UY VE',
  WorldRegion.asia: 'AE AF BD BH BN BT CN HK ID IL IN IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MO MV MY NP '
      'OM PH PK PS QA SA SG SY TH TJ TL TM TW UZ VN YE',
  WorldRegion.africa: 'AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG '
      'ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW',
  WorldRegion.oceania: 'AS AU CK FJ FM GU KI MH MP NC NF NR NU NZ PF PG PN PW SB TK TO TV UM VU WF WS',
};

final Map<String, WorldRegion> _regionByCode = {
  for (final entry in _codesByRegion.entries)
    for (final code in entry.value.split(' ')) code: entry.key,
};

/// The region of an ISO 3166-1 alpha-2 country code.
WorldRegion regionOf(String countryCode) => _regionByCode[countryCode.toUpperCase()] ?? WorldRegion.other;
