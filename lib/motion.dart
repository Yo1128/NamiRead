import 'package:flutter/material.dart';

AnimationStyle sheetMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? AnimationStyle.noAnimation
    : const AnimationStyle(
        duration: Duration(milliseconds: 210),
        reverseDuration: Duration(milliseconds: 150),
      );
