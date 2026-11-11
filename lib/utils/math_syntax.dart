import 'package:markdown/markdown.dart' as md;

/// Block syntax for display math delimited by `$$ ... $$`.
///
/// Accepts both one-line (`$$ E = mc^2 $$`) and multi-line forms:
///
/// ```
/// $$
/// \rho \left( \frac{\partial \mathbf{u}}{\partial t} + ... \right) = ...
/// $$
/// ```
class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();

  static final RegExp _opening = RegExp(r'^\s*\$\$(.*)$');

  @override
  RegExp get pattern => _opening;

  @override
  md.Node parse(md.BlockParser parser) {
    final first = _opening.firstMatch(parser.current.content)!;
    final buffer = StringBuffer((first.group(1) ?? '').trim());
    parser.advance();

    var closed = buffer.toString().contains(r'$$');
    while (!closed && !parser.isDone) {
      final line = parser.current.content;
      final end = line.indexOf(r'$$');
      if (end >= 0) {
        final before = line.substring(0, end).trim();
        if (before.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(before);
        }
        parser.advance();
        closed = true;
      } else {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
        parser.advance();
      }
    }

    var expr = buffer.toString();
    final close = expr.indexOf(r'$$');
    if (close >= 0) expr = expr.substring(0, close);

    // Reuse the fenced-code-block pipeline (`pre` + `code`) so the markdown
    // builder renders this as a real block. The `language-math` class tells
    // [CodeBlockBuilder] to draw an equation instead of code.
    final code = md.Element.text('code', expr.trim());
    code.attributes['class'] = 'language-math';
    return md.Element('pre', <md.Node>[code]);
  }
}

/// Inline syntax for LaTeX math: `$$ ... $$` appearing mid-paragraph.
///
/// Display equations on their own line are handled by [MathBlockSyntax].
class MathInlineDisplaySyntax extends md.InlineSyntax {
  MathInlineDisplaySyntax() : super(r'\$\$([^$\n]+?)\$\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final expr = match.group(1)?.trim() ?? '';
    if (expr.isEmpty) return false;
    final el = md.Element.text('math', expr);
    el.attributes['display'] = 'true';
    parser.addNode(el);
    return true;
  }
}

/// Inline syntax for LaTeX math: `$ ... $`.
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(r'\$([^$\n]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final expr = match.group(1)?.trim() ?? '';
    if (expr.isEmpty) return false;
    parser.addNode(md.Element.text('math', expr));
    return true;
  }
}

/// Extension set = GFM + LaTeX math + GitHub emoji.
md.ExtensionSet get piercingExtensionSet => md.ExtensionSet(
      List<md.BlockSyntax>.unmodifiable(<md.BlockSyntax>[
        const MathBlockSyntax(),
        const md.FencedCodeBlockSyntax(),
        const md.TableSyntax(),
        const md.UnorderedListWithCheckboxSyntax(),
        const md.OrderedListWithCheckboxSyntax(),
        const md.FootnoteDefSyntax(),
      ]),
      List<md.InlineSyntax>.unmodifiable(<md.InlineSyntax>[
        MathInlineDisplaySyntax(),
        MathInlineSyntax(),
        md.EmojiSyntax(),
        md.InlineHtmlSyntax(),
        md.StrikethroughSyntax(),
        md.AutolinkExtensionSyntax(),
      ]),
    );
