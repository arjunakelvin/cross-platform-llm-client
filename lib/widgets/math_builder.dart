import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders `$ ... $` math inline with the surrounding text.
class MathInlineBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => false;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final expr = element.textContent.trim();
    if (expr.isEmpty) return null;
    final style = parentStyle ??
        preferredStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle();
    final display = element.attributes['display'] == 'true';
    return Math.tex(
      expr,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: display ? style.copyWith(fontSize: (style.fontSize ?? 15) + 1) : style,
      onErrorFallback: (error) =>
          _MathFallback(expression: expr, style: style),
    );
  }
}

/// Renders display math (`$$ ... $$`) as a centered equation that can scroll
/// horizontally when the formula is wider than the chat column.
class MathBlockView extends StatelessWidget {
  final String expression;
  final TextStyle? textStyle;

  const MathBlockView({
    super.key,
    required this.expression,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (textStyle ?? theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
      fontSize: 17,
      height: 1.45,
      color: theme.colorScheme.onSurface,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Align(
                alignment: Alignment.center,
                child: Math.tex(
                  expression,
                  mathStyle: MathStyle.display,
                  textStyle: style,
                  onErrorFallback: (error) =>
                      _MathFallback(expression: expression, style: style),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shows the raw LaTeX instead of a scary red error when a formula uses a
/// command that the parser does not understand.
class _MathFallback extends StatelessWidget {
  final String expression;
  final TextStyle? style;

  const _MathFallback({required this.expression, this.style});

  @override
  Widget build(BuildContext context) {
    final color = (style?.color ?? Theme.of(context).colorScheme.onSurface)
        .withValues(alpha: 0.72);
    return Text(
      expression,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.4,
        color: color,
      ),
    );
  }
}
