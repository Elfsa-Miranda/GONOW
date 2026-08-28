import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/main.dart';

void main() {
  test('root application type remains a Flutter widget', () {
    const GoNowApp application = GoNowApp();
    expect(application, isA<StatelessWidget>());
  });
}
