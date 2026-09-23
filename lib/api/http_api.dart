import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message, {this.body});
  final int statusCode;
  final String message;
  final dynamic body;

  bool get isConflict => statusCode == 409;
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class HttpApi {
  HttpApi(this.baseUrl, {http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Időkorlát nélkül egy félig nyitott mobilkapcsolat örökre megállítaná a
  /// szinkront. Az időtúllépés hálózati hibának számít (statusCode 0).
  static const requestTimeout = Duration(seconds: 30);
  static const uploadTimeout = Duration(minutes: 2);

  Uri _uri(String path, [Map<String, String?> query = const {}]) {
    final cleanBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanBase$cleanPath').replace(
      queryParameters: query.isEmpty
          ? null
          : {for (final e in query.entries) if (e.value != null) e.key: e.value!},
    );
  }

  Future<dynamic> get(String path, {String? token, Map<String, String?> query = const {}}) =>
      _send('GET', _uri(path, query), token: token);

  Future<dynamic> post(String path, {String? token, Object? body}) =>
      _send('POST', _uri(path), token: token, body: body);

  Future<dynamic> put(String path, {String? token, Object? body}) =>
      _send('PUT', _uri(path), token: token, body: body);

  /// A fájlfeltöltés nem az API-ra megy, hanem presigned URL-lel közvetlenül az
  /// objektumtárra — az pedig külön hoszt, külön porton. Ha csak az nem érhető
  /// el (például mert a presigned URL "localhost"-ra mutat, ami a telefonon
  /// saját magát jelenti), az nem ugyanaz, mint hogy nincs internet, ezért a
  /// hibaüzenet megnevezi a hosztot.
  Future<void> putBytes(Uri uri, List<int> bytes, String contentType) async {
    try {
      final response = await _client.put(uri, headers: {'Content-Type': contentType}, body: bytes).timeout(uploadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(response.statusCode, 'Fájl feltöltési hiba (HTTP ${response.statusCode})');
      }
    } on TimeoutException {
      throw ApiException(0, 'A tárhely nem válaszolt időben: ${uri.host}:${uri.port}');
    } on SocketException catch (e) {
      throw ApiException(0, 'A tárhely nem érhető el: ${uri.host}:${uri.port}', body: e.message);
    } on http.ClientException catch (e) {
      throw ApiException(0, 'A tárhely nem érhető el: ${uri.host}:${uri.port}', body: e.message);
    }
  }

  Future<dynamic> _send(String method, Uri uri, {String? token, Object? body}) async {
    try {
      final request = http.Request(method, uri);
      request.headers['Accept'] = 'application/json';
      if (token != null && token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      final streamed = await _client.send(request).timeout(requestTimeout);
      final response = await http.Response.fromStream(streamed).timeout(requestTimeout);
      dynamic decoded;
      if (response.body.isNotEmpty) {
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {
          decoded = response.body;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map && decoded['message'] != null
            ? (decoded['message'] is List ? (decoded['message'] as List).join(', ') : '${decoded['message']}')
            : 'HTTP ${response.statusCode}';
        throw ApiException(response.statusCode, message, body: decoded);
      }
      return decoded;
    } on TimeoutException {
      throw ApiException(0, 'A szerver nem válaszolt időben: ${uri.host}:${uri.port}');
    } on SocketException catch (e) {
      throw ApiException(0, 'A szerver nem érhető el: ${uri.host}:${uri.port}', body: e.message);
    } on http.ClientException catch (e) {
      throw ApiException(0, 'A szerver nem érhető el: ${uri.host}:${uri.port}', body: e.message);
    }
  }
}
