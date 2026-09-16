import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/terminal/terminal_theme.dart';
import 'package:xterm/xterm.dart';

/// Guards the terminal's two palettes.
///
/// The failure this prevents is invisible in a widget test and obvious to a
/// user: shell output drawn in a colour that cannot be read against its own
/// background. The page used to hardcode a dark palette, so under the app's
/// light themes every ANSI colour was painted on a light surface — `green` at
/// `#3FB950` on white is the worst of them, and it is the colour of a
/// successful command.
void main() {
  /// Relative luminance, WCAG 2.x. Kept local and minimal: the test needs a
  /// number to compare, not a conformance claim.
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// The colours that are read as text on the terminal background, as
  /// (name, colour) pairs so a failure names the colour rather than a position.
  ///
  /// ANSI `black` and `white` are deliberately NOT in this list. They are the
  /// pair defined relative to the background rather than against it — a
  /// program prints ANSI black as the text of an inverted status bar, and every
  /// dark terminal theme keeps it dim for exactly that use. Measured here, the
  /// dark palette's `black` sits at 2.2 against its background, which is the
  /// convention rather than a defect; they are checked by
  /// [distinguishablePair] instead.
  List<(String, Color)> readableOnBackground(TerminalTheme t) => [
    ('foreground', t.foreground),
    ('red', t.red),
    ('green', t.green),
    ('yellow', t.yellow),
    ('blue', t.blue),
    ('magenta', t.magenta),
    ('cyan', t.cyan),
    ('brightRed', t.brightRed),
    ('brightGreen', t.brightGreen),
    ('brightYellow', t.brightYellow),
    ('brightBlue', t.brightBlue),
    ('brightMagenta', t.brightMagenta),
    ('brightCyan', t.brightCyan),
    ('brightWhite', t.brightWhite),
  ];

  /// The background-relative pair, which must be *distinguishable* from the
  /// background but is not required to be readable against it.
  List<(String, Color)> distinguishablePair(TerminalTheme t) => [
    ('black', t.black),
    ('white', t.white),
  ];

  const darkScheme = ColorScheme.dark();
  const lightScheme = ColorScheme.light();
  const both = [
    (Brightness.dark, darkScheme),
    (Brightness.light, lightScheme),
  ];

  test('the background follows the theme surface in both brightnesses', () {
    // The one part of the palette the app owns: on a light theme the terminal
    // must sit on the light surface, not on a black slab.
    expect(
      terminalThemeFor(darkScheme, Brightness.dark).background,
      darkScheme.surface,
    );
    expect(
      terminalThemeFor(lightScheme, Brightness.light).background,
      lightScheme.surface,
    );
  });

  test('every colour is readable against its own background', () {
    // 3.0 is the WCAG large-text threshold, and terminal glyphs at 11-14 px are
    // not large — but a strict 4.5 would force the sixteen ANSI colours away
    // from the values every terminal uses and make `ls` output unrecognisable
    // to anyone who has used a shell. This floor catches the real defect (a
    // dark palette on a light surface, where green lands near 1.5) without
    // demanding a redesign.
    for (final (brightness, scheme) in both) {
      final theme = terminalThemeFor(scheme, brightness);
      for (final (name, color) in readableOnBackground(theme)) {
        expect(
          contrast(color, theme.background),
          greaterThan(3.0),
          reason: '$brightness: $name is unreadable on the terminal background',
        );
      }
    }
  });

  test('the background pair stays distinguishable from the background', () {
    // What this catches is a palette that accidentally maps ANSI black onto the
    // terminal background (or white onto a light one): output using it would
    // vanish entirely rather than merely be dim.
    for (final (brightness, scheme) in both) {
      final theme = terminalThemeFor(scheme, brightness);
      for (final (name, color) in distinguishablePair(theme)) {
        expect(
          contrast(color, theme.background),
          greaterThan(1.5),
          reason: '$brightness: $name is indistinguishable from the background',
        );
      }
    }
  });

  test('the two palettes differ, so switching themes is visible', () {
    final dark = terminalThemeFor(darkScheme, Brightness.dark);
    final light = terminalThemeFor(lightScheme, Brightness.light);

    expect(dark.green, isNot(light.green));
    expect(dark.foreground, isNot(light.foreground));
    expect(dark.background, isNot(light.background));
  });

  test('selection is visible under the foreground in both palettes', () {
    // A selection colour equal to the background makes selecting text look like
    // nothing happened — the exact case this page has no other feedback for.
    for (final (brightness, scheme) in both) {
      final theme = terminalThemeFor(scheme, brightness);
      expect(
        theme.selection,
        isNot(theme.background),
        reason: '$brightness: selection is invisible',
      );
      expect(
        contrast(theme.foreground, theme.selection),
        greaterThan(1.2),
        reason: '$brightness: selected text cannot be read',
      );
    }
  });
}
