import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/utils/math_syntax.dart';
import 'package:privatelm/widgets/code_block.dart';
import 'package:privatelm/widgets/math_builder.dart';

const _navierStokes = r'''
Bentuk umumnya seperti ini:

$$
\rho \left( \frac{\partial \mathbf{u}}{\partial t} + \mathbf{u} \cdot \nabla \mathbf{u} \right) = -\nabla p + \mu \nabla^2 \mathbf{u} + \mathbf{f}
$$

* **$\rho$ (Rho):** Massa jenis.
* **$\frac{\partial \mathbf{u}}{\partial t}$:** Perubahan kecepatan.
''';

void main() {
  testWidgets('long code blocks scroll vertically instead of growing',
      (tester) async {
    final code = List<String>.generate(
      80,
      (i) => 'print("baris ${i + 1}")  # komentar panjang',
    ).join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              child: CodeBlock(code: code, language: 'python', isDark: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final vertical = tester
        .widgetList<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        )
        .where((view) => view.scrollDirection == Axis.vertical);
    expect(vertical, isNotEmpty);

    final scrollableHeight = tester
        .getSize(find.byWidget(vertical.first))
        .height;
    expect(scrollableHeight, lessThanOrEqualTo(420));
    expect(vertical.first.controller!.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('display and inline math render inside markdown',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: _navierStokes,
              extensionSet: piercingExtensionSet,
              builders: {
                'pre': CodeBlockBuilder(false),
                'math': MathInlineBuilder(),
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(r'\rho'), findsNothing);
  });
}
