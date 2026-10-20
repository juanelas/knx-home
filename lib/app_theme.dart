// Shared colors for the app's Material widgets and custom controls.
import 'package:flutter/material.dart';

const ink = Color(0xff202a25),
    dark = Color(0xff202f28),
    lime = Color(0xffd8ef94),
    paper = Color(0xfff4f5f0),
    muted = Color(0xff7b847e),
    line = Color(0xffe3e6e0),
    blue = Color(0xff3588c7),
    orange = Color(0xffdf6338);

BoxDecoration appPanelDecoration() => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(8),
  border: Border.all(color: line),
);
