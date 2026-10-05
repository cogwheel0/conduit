import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/utils/profile_avatar.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

img.Image _decodeDataUrl(String dataUrl, {String type = 'png'}) {
  check(dataUrl).startsWith('data:image/$type;base64,');
  final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
  return img.decodeImage(bytes)!;
}

void main() {
  group('extractAvatarInitials', () {
    test('two words give their first letters', () {
      check(extractAvatarInitials('  ada   lovelace king ')).equals('AL');
    });

    test('one word gives its first two letters', () {
      check(extractAvatarInitials('grace')).equals('GR');
      check(extractAvatarInitials('x')).equals('X');
    });

    test('an empty name reads U', () {
      check(extractAvatarInitials('   ')).equals('U');
    });

    test('a surrogate pair is never split', () {
      check(extractAvatarInitials('😀bc')).equals('😀B');
    });
  });

  group('initials colour', () {
    test('an empty seed uses hue 215', () {
      check(initialsAvatarHue('  ')).equals(215);
    });

    test('the hue is case and padding insensitive and in range', () {
      check(initialsAvatarHue(' Ada ')).equals(initialsAvatarHue('ada'));
      check(initialsAvatarHue('ada')).isGreaterOrEqual(0);
      check(initialsAvatarHue('ada')).isLessThan(360);
    });

    test('HSL converts like Flutter HSLColor', () {
      check(hslToArgb(0, 1, 0.5)).equals(0xFFFF0000);
      check(hslToArgb(120, 1, 0.5)).equals(0xFF00FF00);
      check(hslToArgb(240, 1, 0.5)).equals(0xFF0000FF);
      check(hslToArgb(0, 0, 1)).equals(0xFFFFFFFF);
      // HSLColor.fromAHSL(1, 215, 0.55, 0.52).toColor()
      check(hslToArgb(215, 0.55, 0.52)).equals(0xFF4179C8);
    });
  });

  group('initialsAvatarDataUrl', () {
    test('draws white initials centred on the seed colour', () {
      final image = _decodeDataUrl(initialsAvatarDataUrl('Ada Lovelace'));
      check(image.width).equals(kProfileAvatarDimension);
      check(image.height).equals(kProfileAvatarDimension);

      final argb = initialsAvatarColorValue('Ada Lovelace');
      final plate = image.getPixel(40, 125);
      check(plate.r.toInt()).equals(argb >> 16 & 0xFF);
      check(plate.g.toInt()).equals(argb >> 8 & 0xFF);
      check(plate.b.toInt()).equals(argb & 0xFF);

      // Outside the circle stays transparent.
      check(image.getPixel(2, 2).a.toInt()).equals(0);

      var white = 0;
      for (var y = 90; y < 160; y++) {
        for (var x = 60; x < 190; x++) {
          final pixel = image.getPixel(x, y);
          if (pixel.r > 240 && pixel.g > 240 && pixel.b > 240) white++;
        }
      }
      check(white).isGreaterThan(300);
    });

    test('initials the bitmap font lacks leave a plain circle', () {
      final image = _decodeDataUrl(initialsAvatarDataUrl('李 雷'));
      final argb = initialsAvatarColorValue('李 雷');
      final centre = image.getPixel(125, 125);
      check(centre.r.toInt()).equals(argb >> 16 & 0xFF);
    });
  });

  group('profileImageDataUrlFromBytes', () {
    test('scales a large photo to fit and re-encodes it as JPEG', () {
      final source = img.Image(width: 800, height: 400);
      img.fill(source, color: img.ColorRgb8(10, 20, 30));
      final dataUrl = profileImageDataUrlFromBytes(img.encodeJpg(source))!;

      final image = _decodeDataUrl(dataUrl, type: 'jpeg');
      check(image.width).equals(250);
      check(image.height).equals(125);
    });

    test('keeps a small image with alpha at its size, as PNG', () {
      final source = img.Image(width: 40, height: 60, numChannels: 4);
      final image = _decodeDataUrl(
        profileImageDataUrlFromBytes(img.encodePng(source))!,
      );
      check(image.width).equals(40);
      check(image.height).equals(60);
    });

    test('undecodable bytes give null', () {
      check(profileImageDataUrlFromBytes(Uint8List.fromList([1, 2, 3, 4])))
          .isNull();
    });
  });

  test('normalizeProfileImageUrl falls back to the default avatar', () {
    check(normalizeProfileImageUrl(null)).equals(kDefaultProfileImagePath);
    check(normalizeProfileImageUrl('  ')).equals(kDefaultProfileImagePath);
    check(normalizeProfileImageUrl(' /api/x ')).equals('/api/x');
  });
}
