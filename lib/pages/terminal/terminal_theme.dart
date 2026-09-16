import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// The terminal's colour scheme for the app's current theme.
///
/// The page used to carry one hardcoded palette — GitHub-dark on a black
/// background — regardless of the app theme. Under the light themes the app
/// ships, that made the shell a black slab framed by light chrome: the one
/// surface a user stares at for minutes at a time was the only one that ignored
/// the theme, and in bright ambient light it was also the hardest to read.
///
/// The split is deliberate: the sixteen ANSI colours are NOT derived from the
/// [ColorScheme]. They are the terminal's own semantic palette — `red` in shell
/// output means "failed", in every app that ever drew a terminal — so they come
/// in two hand-tuned sets (one per brightness) that both keep red readable
/// against their own background. Only the surfaces the terminal does not own
/// semantically — background, foreground, cursor, selection — follow the app.
///
/// Pure, so a test can pin both palettes without a widget tree.
TerminalTheme terminalThemeFor(ColorScheme colorScheme, Brightness brightness) {
  return brightness == Brightness.dark
      ? _darkTheme(colorScheme)
      : _lightTheme(colorScheme);
}

/// GitHub-dark on the theme's surface colour — the palette this page already
/// shipped, kept byte for byte so nothing regresses on dark themes.
TerminalTheme _darkTheme(ColorScheme cs) {
  return TerminalTheme(
    cursor: const Color(0xFFFFFFFF),
    foreground: const Color(0xFFC9D1D9),
    background: cs.surface,
    black: const Color(0xFF484D56),
    red: const Color(0xFFF85149),
    green: const Color(0xFF3FB950),
    yellow: const Color(0xFFD29922),
    blue: const Color(0xFF58A6FF),
    magenta: const Color(0xFFBC8CFF),
    cyan: const Color(0xFF39C5CF),
    white: const Color(0xFFB1BAC4),
    brightBlack: const Color(0xFF6E7681),
    brightRed: const Color(0xFFFFA198),
    brightGreen: const Color(0xFF56D364),
    brightYellow: const Color(0xFFE3B341),
    brightBlue: const Color(0xFF79C0FF),
    brightMagenta: const Color(0xFFD2A8FF),
    brightCyan: const Color(0xFF56D4DD),
    brightWhite: const Color(0xFFF0F6FC),
    searchHitBackground: const Color(0xFF264F78),
    searchHitBackgroundCurrent: const Color(0xFF58A6FF),
    searchHitForeground: const Color(0xFFFFFFFF),
    selection: const Color(0xFF264F78),
  );
}

/// A light palette: dark text on the theme's surface, with ANSI colours tuned
/// for contrast against a light background (the light counterparts of the set
/// above — `green` in particular has to be darkened, since the dark theme's
/// green is nearly invisible on white).
TerminalTheme _lightTheme(ColorScheme cs) {
  return TerminalTheme(
    cursor: const Color(0xFF1F2328),
    // Slightly off-black: pure black on white is the harshest pairing available
    // and the one that smears most on OLED phone panels.
    foreground: const Color(0xFF1F2328),
    background: cs.surface,
    black: const Color(0xFF24292F),
    red: const Color(0xFFCF222E),
    green: const Color(0xFF116329),
    yellow: const Color(0xFF7D4E00),
    blue: const Color(0xFF0969DA),
    magenta: const Color(0xFF8250DF),
    cyan: const Color(0xFF1B7C83),
    white: const Color(0xFF6E7781),
    brightBlack: const Color(0xFF57606A),
    brightRed: const Color(0xFFA40E26),
    brightGreen: const Color(0xFF1A7F37),
    brightYellow: const Color(0xFF9A6700),
    brightBlue: const Color(0xFF218BFF),
    brightMagenta: const Color(0xFFA475F9),
    brightCyan: const Color(0xFF3192AA),
    brightWhite: const Color(0xFF8C959F),
    // The selection must stay legible under the dark foreground text, so it is
    // a tint rather than a solid.
    searchHitBackground: const Color(0xFFFFDF9E),
    searchHitBackgroundCurrent: const Color(0xFFFFC53D),
    searchHitForeground: const Color(0xFF1F2328),
    selection: const Color(0xFFB6E3FF),
  );
}
