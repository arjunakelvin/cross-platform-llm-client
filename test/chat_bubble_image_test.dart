import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/chat_message.dart';
import 'package:privatelm/widgets/chat_bubble.dart';

void main() {
  testWidgets('foto user tampil sebagai gambar, bukan nama file',
      (tester) async {
    // PNG 1x1 transparan.
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    final message = ChatMessage(
      id: 'm1',
      chatId: 'c1',
      role: 'user',
      content: 'apa isi gambar ini?',
      imageBase64: pngBase64,
      imagePath: '/tmp/foto.png',
      fileName: 'foto.png',
      fileType: 'image',
      fileSize: 68,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatBubble(message: message)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsWidgets);
    expect(find.text('foto.png'), findsNothing);
    expect(find.text('apa isi gambar ini?'), findsOneWidget);
  });
}
