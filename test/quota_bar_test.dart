import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/ui.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required double remaining,
    required Color color,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: QuotaProgressBar(remaining: remaining, color: color),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lebar isi bar (bagian berwarna).
  double filledWidth(WidgetTester tester) {
    final positioned = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((p) => p.width != null);
    if (positioned.isEmpty) return 0;
    return positioned.first.width!;
  }

  testWidgets('bar memendek saat kuota terpakai', (tester) async {
    // Kuota utuh -> bar penuh.
    await pumpBar(tester, remaining: 1, color: Colors.green);
    expect(filledWidth(tester), 200);

    // Terpakai 37% -> sisa 63% -> bar menyingkat.
    await pumpBar(tester, remaining: 0.63, color: Colors.green);
    expect(filledWidth(tester), closeTo(126, 0.5));

    // Hampir habis -> bar hampir kosong.
    await pumpBar(tester, remaining: 0.1, color: Colors.red);
    expect(filledWidth(tester), closeTo(20, 0.5));

    // Habis -> tidak ada isian.
    await pumpBar(tester, remaining: 0, color: Colors.red);
    expect(filledWidth(tester), 0);
  });

  testWidgets('bar tidak kosong saat kuota masih ada', (tester) async {
    await pumpBar(tester, remaining: 0.63, color: Colors.green);
    expect(filledWidth(tester), greaterThan(0));
  });

  testWidgets('warna bar mengikuti level kuota', (tester) async {
    await pumpBar(tester, remaining: 0.9, color: Colors.green);
    final bar = tester.widget<QuotaProgressBar>(find.byType(QuotaProgressBar));
    expect(bar.color, Colors.green);

    await pumpBar(tester, remaining: 0.2, color: Colors.red);
    final bar2 = tester.widget<QuotaProgressBar>(find.byType(QuotaProgressBar));
    expect(bar2.color, Colors.red);
  });
}
