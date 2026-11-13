import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/ui.dart';
import 'package:privatelm/widgets/account_info_sheet.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('kartu token: bar sisa + persen + angka ribuan (tanpa overflow)',
      (tester) async {
    await pump(
      tester,
      const TokenQuotaCard(
        maxTokens: 20000000,
        used: 7400000,
        remaining: 12600000,
        ratio: 0.37,
        resetDays: 1,
        countdown: 'Resets in 23h 59m',
        isLoggedIn: true,
      ),
    );

    expect(tester.takeException(), isNull);

    final bar =
        tester.widget<QuotaProgressBar>(find.byType(QuotaProgressBar).first);
    // Sisa 63% (7.4jt dari 20jt terpakai).
    expect(bar.remaining, closeTo(0.63, 0.001));

    expect(find.textContaining('37% terpakai'), findsOneWidget);
    expect(find.textContaining('12,600,000 / 20,000,000 tersisa'),
        findsOneWidget);
    expect(find.textContaining('20,000,000 Limit (Login)'), findsOneWidget);
  });

  testWidgets('kartu token habis: bar kosong + peringatan reset',
      (tester) async {
    await pump(
      tester,
      const TokenQuotaCard(
        maxTokens: 1000,
        used: 1000,
        remaining: 0,
        ratio: 1,
        resetDays: 1,
        countdown: 'Resets today',
        isLoggedIn: true,
      ),
    );

    expect(tester.takeException(), isNull);
    final bar =
        tester.widget<QuotaProgressBar>(find.byType(QuotaProgressBar).first);
    expect(bar.remaining, 0);
    expect(find.textContaining('Kuota token sudah habis'), findsOneWidget);
  });

  testWidgets('kartu kredit: sisa + persen + format ribuan (tanpa overflow)',
      (tester) async {
    await pump(
      tester,
      const CreditQuotaCard(creditBalance: 1234.5, creditUsed: 3.5),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(r'$1,234.50'), findsOneWidget);
    expect(find.textContaining(r'Terpakai $3.50'), findsOneWidget);
    expect(find.text(r'Total $1,238.00'), findsOneWidget);
    // 3.5 dari 1238 total -> 0.28% (presisi ekstra untuk nilai kecil).
    expect(find.text('0.28%'), findsOneWidget);
  });

  testWidgets('kartu kredit habis: peringatan kredit', (tester) async {
    await pump(
      tester,
      const CreditQuotaCard(creditBalance: 0, creditUsed: 3.5),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Kredit sudah habis'), findsOneWidget);
  });

  testWidgets('kartu kredit: saldo besar tetap ringkas, potongan kecil presisi',
      (tester) async {
    await pump(
      tester,
      const CreditQuotaCard(creditBalance: 11.9955, creditUsed: 0.0045),
    );

    expect(tester.takeException(), isNull);
    // Saldo dan total dua-duanya dibulatkan 2 desimal.
    expect(find.text(r'$12.00'), findsOneWidget);
    expect(find.text(r'Total $12.00'), findsOneWidget);
    expect(find.textContaining(r'Terpakai $0.0045'), findsOneWidget);
  });
}
