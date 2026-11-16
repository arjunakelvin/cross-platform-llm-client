import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/admin_db_service.dart';
import 'package:privatelm/widgets/account_info_sheet.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('kartu plan: limit token + sisa hari, tanpa progress bar',
      (tester) async {
    final plan = PlanInfo(
      id: 'p1',
      name: 'VIP Membership',
      tier: 'vip',
      expiresAt:
          DateTime.now().add(const Duration(days: 12)).millisecondsSinceEpoch,
      durationDays: 30,
    );
    await pump(
      tester,
      MembershipPlanCard(
        tier: 'vip',
        plan: plan,
        tokenLimit: 20000000,
        tokenUsed: 7400000,
        isLoggedIn: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('20M'), findsOneWidget);
    expect(find.textContaining('token limit'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.textContaining('Aktif sampai'), findsOneWidget);
    expect(find.textContaining('Sisa 12.6M token'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.63, 0.001));
  });

  testWidgets('kartu plan free guest: 10M limit, tanpa kedaluwarsa',
      (tester) async {
    await pump(
      tester,
      const MembershipPlanCard(
        tier: 'Free',
        tokenLimit: 10000000,
        tokenUsed: 10000000,
        isLoggedIn: false,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('10M'), findsOneWidget);
    expect(find.textContaining('Kuota habis'), findsOneWidget);
    expect(find.textContaining('Berlaku tanpa batas waktu'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0);
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
