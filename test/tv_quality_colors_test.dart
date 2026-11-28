import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/features/tv/tv_screen.dart';

void main() {
  test('picture: Full HD / UHD green, HD yellow, SD orange', () {
    double hue(Color c) => HSVColor.fromColor(c).hue;
    expect(hue(tvPictureColor('Full HD')), closeTo(120, 1));
    expect(hue(tvPictureColor('UHD')), closeTo(120, 1));
    expect(hue(tvPictureColor('HD')), closeTo(55, 1));
    expect(hue(tvPictureColor('SD')), closeTo(30, 1));
    expect(tvPictureColor(null), Colors.white70);
  });

  test('sound: 5.1 green, stereo yellow, mono orange', () {
    double hue(Color c) => HSVColor.fromColor(c).hue;
    expect(hue(tvSoundColor('Dolby Digital 5.1')), closeTo(120, 1));
    expect(hue(tvSoundColor('Dolby Digital Plus 7.1')), closeTo(120, 1));
    expect(hue(tvSoundColor('MPEG Stereo')), closeTo(55, 1));
    expect(hue(tvSoundColor('AAC Mono')), closeTo(30, 1));
    expect(tvSoundColor(null), Colors.white70);
  });
}
