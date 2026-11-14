import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';

String _chunk(String token, {String? finish}) => 'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': token},
          'finish_reason': finish,
        }
      ]
    })}\n\n';

void main() {
  late Directory dir;
  late HttpServer server;
  late CloudService cloud;
  // What the fake provider streams back for the next request.
  late Future<void> Function(HttpResponse res) respond;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      await respond(req.response);
    });

    await hive.setSetting(AppConstants.keyCloudProvider, 'custom');
    await hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, 'http://127.0.0.1:${server.port}');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'test-key');
    await hive.setSetting(AppConstants.keyCustomCloudModel, 'test-model');
    cloud = CloudService();
  });

  tearDown(() async {
    CloudService.streamIdleTimeout = const Duration(seconds: 60);
    CloudService.streamConnectTimeout = const Duration(seconds: 90);
    await server.close(force: true);
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<String> send(List<String> tokens) => cloud.sendMessage(
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
        onToken: tokens.add,
      );

  test('a complete stream returns the text', () async {
    respond = (res) async {
      res.write(_chunk('Hello '));
      res.write(_chunk('world', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    expect(await send(tokens), 'Hello world');
    expect(tokens.join(), 'Hello world');
  });

  test('an error event mid-stream is reported, not shown as a reply',
      () async {
    respond = (res) async {
      res.write(_chunk('Partial '));
      res.write('data: ${jsonEncode({
            'error': {'message': 'Rate limit exceeded'}
          })}\n\n');
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Partial'));
    expect(result, contains('Rate limit exceeded'));
  });

  test('an error event before any text is an ERROR', () async {
    respond = (res) async {
      res.write('data: ${jsonEncode({'error': 'upstream failed'})}\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stream that ends without [DONE] is marked as cut off', () async {
    respond = (res) async {
      res.write(_chunk('Half an answer'));
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Half an answer'));
    expect(result, contains('cut off'));
  });

  test('an empty stream is an ERROR, not a blank reply', () async {
    respond = (res) async {
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stalled stream times out instead of hanging', () async {
    CloudService.streamIdleTimeout = const Duration(milliseconds: 300);
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush(); // ...then nothing more
      await Future.delayed(const Duration(seconds: 5));
    };
    final result = await send([]).timeout(const Duration(seconds: 3));
    expect(result, startsWith('ERROR:'));
    expect(result, contains("didn't respond in time"));
  });

  test('a slow first byte (long prompt prefill) still completes', () async {
    // Self-hosted models on CPU can take a long time before the first token;
    // the old 30 s connect timeout cancelled the request mid-prefill.
    CloudService.streamConnectTimeout = const Duration(seconds: 3);
    respond = (res) async {
      await Future.delayed(const Duration(milliseconds: 600));
      res.write(_chunk('Slow ', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    expect(await send(tokens).timeout(const Duration(seconds: 5)), 'Slow ');
    expect(tokens.join(), 'Slow ');
  });

  test('a provider that never sends headers times out', () async {
    CloudService.streamConnectTimeout = const Duration(milliseconds: 200);
    respond = (res) async {
      try {
        await Future.delayed(const Duration(seconds: 1));
        await res.close();
      } catch (_) {
        // The test already finished and closed the server.
      }
    };
    final result = await send([]).timeout(const Duration(seconds: 5));
    expect(result, startsWith('ERROR:'));
    expect(result, contains("didn't respond in time"));
  });

  test('cancel() aborts the stream in progress', () async {
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush();
      await Future.delayed(const Duration(seconds: 5));
    };
    final pending = send([]);
    await Future.delayed(const Duration(milliseconds: 200));
    cloud.cancel();
    expect(await pending.timeout(const Duration(seconds: 2)),
        startsWith('ERROR:'));
  });

  test('queue events from the proxy drive the UI position indicator', () async {
    respond = (res) async {
      res.write('data: ${jsonEncode({
            'piercingblow_queue': true,
            'active': 1,
            'queued': 2,
            'position': 2,
            'wait_ms': 1200,
          })}\n\n');
      res.write(_chunk('Halo dunia', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    final statuses = <QueueStatus>[];
    final result = await cloud.sendMessage(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      onToken: tokens.add,
      onQueue: statuses.add,
    );
    expect(result, 'Halo dunia');
    // Event antrean: posisi kita ke-2 dari 2 antrean, ±1,2 dtk tunggu.
    expect(statuses.length, greaterThanOrEqualTo(2));
    final waiting = statuses.first;
    expect(waiting.position, 2);
    expect(waiting.queued, 2);
    expect(waiting.waitMs, 1200);
    // Request mulai diproses → event idle/clear harus menghapus indikator.
    expect(statuses.last.position, 0);
  });
}
