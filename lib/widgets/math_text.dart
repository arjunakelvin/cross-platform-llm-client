import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Renders text that may contain LaTeX math delimited by `$...$` (inline)
/// or `$$...$$` (display), mixing it with plain text widgets.
class MathText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color? color;
  const MathText({super.key, required this.text, this.style, this.color});

  static final _pattern = RegExp(r'(\$\$[\s\S]+?\$\$|\$[^$\n]+?\$)');

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 15.5,
              height: 1.6,
            );
    final parts = text.splitMapJoin(
      _pattern,
      onMatch: (m) => '\u0000${m.group(0)}\u0000',
      onNonMatch: (s) => s,
    );
    final tokens = parts.split('\u0000').where((s) => s.isNotEmpty).toList();

    final children = <Widget>[];
    for (final token in tokens) {
      if (token.startsWith('\$\$') && token.endsWith('\$\$')) {
        final expr = token.substring(2, token.length - 2).trim();
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Math.tex(
              expr,
              textStyle: baseStyle,
              mathStyle: MathStyle.display,
            ),
          ),
        ));
      } else if (token.startsWith('\$') && token.endsWith('\$')) {
        final expr = token.substring(1, token.length - 1).trim();
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Math.tex(expr, textStyle: baseStyle),
        ));
      } else if (token.trim().isNotEmpty) {
        children.add(Text(token, style: baseStyle));
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

bool containsMath(String text) => text.contains(r'$');