import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;

import 'math_builder.dart';

/// Markdown fence languages that use a different identifier in `highlight`.
const Map<String, String> _languageIds = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'py3': 'python',
  'rb': 'ruby',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'c++': 'cpp',
  'cplusplus': 'cpp',
  'c#': 'cs',
  'csharp': 'cs',
  'objc': 'objectivec',
  'objective-c': 'objectivec',
  'html': 'xml',
  'htm': 'xml',
  'svg': 'xml',
  'vue': 'xml',
  'yml': 'yaml',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'rs': 'rust',
  'md': 'markdown',
  'docker': 'dockerfile',
  'golang': 'go',
  'postgres': 'sql',
  'postgresql': 'sql',
  'mysql': 'sql',
  'plaintext': 'plaintext',
  'text': 'plaintext',
  'txt': 'plaintext',
};

/// Pretty label shown in the code block header.
const Map<String, String> _languageLabels = <String, String>{
  'javascript': 'JavaScript',
  'typescript': 'TypeScript',
  'python': 'Python',
  'dart': 'Dart',
  'java': 'Java',
  'kotlin': 'Kotlin',
  'swift': 'Swift',
  'go': 'Go',
  'rust': 'Rust',
  'cpp': 'C++',
  'c': 'C',
  'cs': 'C#',
  'php': 'PHP',
  'ruby': 'Ruby',
  'bash': 'Bash',
  'powershell': 'PowerShell',
  'sql': 'SQL',
  'html': 'HTML',
  'xml': 'XML',
  'css': 'CSS',
  'scss': 'SCSS',
  'json': 'JSON',
  'yaml': 'YAML',
  'markdown': 'Markdown',
  'dockerfile': 'Dockerfile',
  'plaintext': 'Code',
};

String _normalizeLanguage(String raw) {
  final lang = raw.trim().toLowerCase();
  if (lang.isEmpty) return 'plaintext';
  return _languageIds[lang] ?? lang;
}

String _languageLabel(String raw, String normalized) {
  final key = raw.trim().toLowerCase();
  return _languageLabels[key] ??
      _languageLabels[normalized] ??
      (key.isEmpty ? 'Code' : key);
}

class CodeBlockBuilder extends MarkdownElementBuilder {
  final bool isDark;

  CodeBlockBuilder(this.isDark);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.trimRight();
    String language = '';

    void readClass(String? value) {
      if (value == null) return;
      for (final part in value.split(RegExp(r'\s+'))) {
        if (part.startsWith('language-')) {
          language = part.substring('language-'.length);
        }
      }
    }

    readClass(element.attributes['class']);
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element) readClass(child.attributes['class']);
    }

    if (_normalizeLanguage(language) == 'math') {
      return MathBlockView(expression: code);
    }

    return CodeBlock(code: code, language: language, isDark: isDark);
  }
}

class CodeBlock extends StatefulWidget {
  final String code;
  final String language;
  final bool isDark;

  const CodeBlock({
    super.key,
    required this.code,
    required this.language,
    required this.isDark,
  });

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;
  late final ScrollController _vertical = ScrollController();
  late final ScrollController _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  Map<String, TextStyle> _theme() {
    final base = Map<String, TextStyle>.from(
      widget.isDark ? atomOneDarkTheme : atomOneLightTheme,
    );
    // Let the outer container paint the background so it spans the full width.
    final root = base['root'];
    if (root != null) {
      base['root'] = root.copyWith(backgroundColor: Colors.transparent);
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final background =
        widget.isDark ? const Color(0xFF282C34) : const Color(0xFFFAFAFA);
    final headerColor = widget.isDark
        ? const Color(0xFF21252B)
        : const Color(0xFFF0F0F2);
    final borderColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);
    final mutedColor =
        widget.isDark ? const Color(0xFF9AA0AA) : const Color(0xFF6A6F78);
    final normalized = _normalizeLanguage(widget.language);
    final label = _languageLabel(widget.language, normalized);
    final lineCount = '\n'.allMatches(widget.code).length + 1;
    final isLong = lineCount > 20 || widget.code.length > 1600;
    final maxHeight =
        (MediaQuery.sizeOf(context).height * 0.5).clamp(220.0, 420.0);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 0.6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(label, headerColor, mutedColor, isLong),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Scrollbar(
              controller: _vertical,
              thumbVisibility: isLong,
              thickness: 5,
              radius: const Radius.circular(4),
              child: SingleChildScrollView(
                controller: _vertical,
                primary: false,
                child: Scrollbar(
                  controller: _horizontal,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  thickness: 5,
                  radius: const Radius.circular(4),
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: HighlightView(
                      widget.code,
                      language: normalized,
                      theme: _theme(),
                      textStyle: GoogleFonts.firaCode(
                        fontSize: 13,
                        height: 1.55,
                        letterSpacing: 0,
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(
    String label,
    Color background,
    Color muted,
    bool isLong,
  ) {
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, size: 13, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: muted,
              ),
            ),
          ),
          if (isLong) ...[
            Icon(Icons.unfold_more_rounded, size: 13, color: muted),
            const SizedBox(width: 4),
            Text(
              'Scroll',
              style: GoogleFonts.inter(fontSize: 10.5, color: muted),
            ),
            const SizedBox(width: 8),
          ],
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _copy,
              borderRadius: BorderRadius.circular(7),
              hoverColor: muted.withValues(alpha: 0.12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _copied
                          ? Icons.check_rounded
                          : Icons.content_copy_rounded,
                      size: 14,
                      color: _copied ? const Color(0xFF4CAF50) : muted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _copied ? 'Copied' : 'Copy',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _copied ? const Color(0xFF4CAF50) : muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
