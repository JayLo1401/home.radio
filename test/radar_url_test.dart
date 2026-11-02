import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/features/home/radar_panel.dart';

void main() {
  test('fills in all radar URL placeholders', () {
    final url = RadarPanel.buildUrl(
      ' https://radar.example/radar.png?lat={lat}&lon={lon}&r={r}&w={w}&h={h}&scale={scale} ',
      lat: 47.0707,
      lon: 15.4395,
      radiusKm: 50,
      width: 840,
      height: 520,
      scale: 2,
    );
    expect(url, 'https://radar.example/radar.png?lat=47.0707&lon=15.4395&r=50&w=840&h=520&scale=2.00');
  });

  test('picks a map zoom that shows about the radius', () {
    // 260 px tall tile, 50 km to the top/bottom edge, Graz: ~385 m/px.
    expect(RadarPanel.zoomFor(lat: 47.07, radiusKm: 50, logicalHeight: 260), 8);
    expect(RadarPanel.zoomFor(lat: 47.07, radiusKm: 10, logicalHeight: 260), 10);
    final url = RadarPanel.buildUrl('x?wrm={zoom}', lat: 47.07, lon: 15.44, radiusKm: 50, width: 840, height: 520, scale: 2);
    expect(url, 'x?wrm=8');
  });

  test('leaves a URL without placeholders as it is', () {
    const plain = 'https://example.org/radar.jpg';
    expect(
      RadarPanel.buildUrl(plain, lat: 1, lon: 2, radiusKm: 3, width: 4, height: 5, scale: 1),
      plain,
    );
  });
}
