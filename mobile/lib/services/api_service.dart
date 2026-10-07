import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../models/store_result.dart';

/// Claude solo acepta estos tipos de imagen. Si el archivo no trae un
/// `mimeType` reconocible (pasa seguido en la versión web), lo adivinamos
/// por la extensión del nombre de archivo, y si tampoco se puede, usamos
/// "image/jpeg" como respaldo.
String _resolveMimeType(XFile image) {
  const allowed = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};
  if (image.mimeType != null && allowed.contains(image.mimeType)) {
    return image.mimeType!;
  }
  final lower = image.name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

/// Extrae un mensaje legible del cuerpo de la respuesta (FastAPI devuelve
/// errores como {"detail": "..."}). Si no puede parsearlo, muestra el texto
/// crudo, para que siempre se vea la causa real del error, no solo el código.
String _describeError(http.Response response, String accion) {
  String detail = response.body;
  try {
    final data = jsonDecode(response.body);
    if (data is Map && data['detail'] != null) {
      detail = data['detail'].toString();
    }
  } catch (_) {
    // el cuerpo no era JSON, dejamos el texto crudo
  }
  return 'No se pudo $accion (código ${response.statusCode}): $detail';
}

class ApiService {
  /// Sube la foto al backend y devuelve el nombre del producto identificado.
  static Future<String> identifyProduct(XFile image) async {
    final uri = Uri.parse('$backendBaseUrl/identify-product');
    final request = http.MultipartRequest('POST', uri);

    final bytes = await image.readAsBytes();
    final mimeType = _resolveMimeType(image);
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: image.name.isNotEmpty ? image.name : 'foto.jpg',
        contentType: MediaType.parse(mimeType),
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw ApiException(_describeError(response, 'identificar el producto'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final productName = data['product_name'] as String?;
    if (productName == null || productName.isEmpty) {
      throw ApiException('El backend no devolvió un nombre de producto.');
    }
    return productName;
  }

  /// Busca el producto en las 4 tiendas y devuelve los resultados.
  static Future<List<StoreResult>> searchPrices(String query) async {
    final uri = Uri.parse('$backendBaseUrl/search-prices');

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'query': query}),
    );

    if (response.statusCode != 200) {
      throw ApiException(_describeError(response, 'buscar precios'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final stores = data['stores'] as List<dynamic>? ?? [];

    return stores
        .map((s) => StoreResult.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
  }
}
