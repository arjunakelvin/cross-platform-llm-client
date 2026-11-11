import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/widgets/code_block.dart';

const _sample = '''
Berikut kode:

```python
print("halo")
```

Teks setelah kode.

* item satu
* item dua
''';

void main() {
  testWidgets('code block followed by text and list', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: _sample,
              builders: {'pre': CodeBlockBuilder(false)},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
