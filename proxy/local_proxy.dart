/// Local CORS proxy for development.
///
/// Run:
///   dart run proxy/local_proxy.dart 8787
///
/// Then set the app's custom provider "Proxy URL" to:
///   http://localhost:8787/?url=
///
/// This is only for local testing. Do not expose it on a public network: an
/// open proxy lets anyone relay requests through your machine.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8787 : (int.tryParse(args.first) ?? 8787);
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('PiercingBlow CORS proxy listening on '
      'http://localhost:$port/?url=<encoded-endpoint>');

  await for (final request in server) {
    final response = request.response;
    try {
      await _handle(request);
    } catch (error) {
      // Headers may already have been sent if the error happened while
      // streaming the upstream body. Writing is best-effort, closing always.
      try {
        response.statusCode = HttpStatus.badGateway;
        response.write('Proxy error: $error');
      } catch (_) {
        // Response already committed; nothing more we can send.
      }
      await response.close();
    }
  }
}

void _cors(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  response.headers.set(
      'Access-Control-Allow-Headers', 'authorization, content-type, accept');
  response.headers.set('Access-Control-Max-Age', '86400');
}

Future<void> _handle(HttpRequest request) async {
  final response = request.response;
  _cors(response);

  if (request.method == 'OPTIONS') {
    response.statusCode = HttpStatus.noContent;
    await response.close();
    return;
  }

  final target = request.uri.queryParameters['url'];
  if (target == null || target.isEmpty) {
    response.statusCode = HttpStatus.badRequest;
    response.write('Missing "url" query parameter.');
    await response.close();
    return;
  }

  final uri = Uri.tryParse(target);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    response.statusCode = HttpStatus.badRequest;
    response.write('Only http(s) targets are allowed.');
    await response.close();
    return;
  }

  final client = HttpClient();
  try {
    final upstream = await client.openUrl(request.method, uri);
    for (final name in const ['authorization', 'content-type', 'accept']) {
      final value = request.headers.value(name);
      if (value != null) upstream.headers.set(name, value);
    }

    final body = await request.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    if (body.isNotEmpty) upstream.add(body);

    final upstreamResponse = await upstream.close();
    response.statusCode = upstreamResponse.statusCode;
    final contentType = upstreamResponse.headers.value('content-type');
    if (contentType != null) response.headers.set('content-type', contentType);
    response.headers.set('cache-control', 'no-store');
    await upstreamResponse.forEach(response.add);
  } finally {
    client.close();
    await response.close();
  }
}
