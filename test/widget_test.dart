import 'package:flutter_test/flutter_test.dart';
import 'package:superior_college_tts/main.dart';

void main() {
  test('home url points to portal', () {
    expect(kHomeUrl, startsWith('https://$kHost/'));
  });
}
