import '../config.dart';

/// Resultado de buscar un producto en una tienda específica.
///
/// Los actores de Apify de cada tienda devuelven datos con nombres de campo
/// que pueden variar (title/name, price/salePrice, etc.). Este modelo intenta
/// varias llaves comunes para no depender de que todas las tiendas usen
/// exactamente el mismo formato.
class StoreResult {
  final String store;
  final String? title;
  final String? priceText;
  final String? url;
  final String? imageUrl;
  final String? error;

  StoreResult({
    required this.store,
    this.title,
    this.priceText,
    this.url,
    this.imageUrl,
    this.error,
  });

  bool get found => error == null && priceText != null;

  /// URL de la imagen pasada por el proxy del backend en vez de cargarla
  /// directamente desde la tienda. Varias tiendas (Paris, Ripley, Ahumada)
  /// bloquean que su imagen se cargue desde otro sitio o app, así que el
  /// backend la descarga por su cuenta y se la entrega a la app.
  String? get proxiedImageUrl {
    if (imageUrl == null) return null;
    return '$backendBaseUrl/image-proxy?url=${Uri.encodeQueryComponent(imageUrl!)}';
  }

  /// Intenta convertir el precio (ej: "$19.990" o "19990") a número, para
  /// poder ordenar las tiendas de más barata a más cara. Si no se puede,
  /// vuelve null y esa tienda queda al final del listado.
  double? get priceValue {
    if (priceText == null) return null;
    final digits = priceText!.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return double.tryParse(digits);
  }

  String get storeLabel {
    switch (store) {
      case 'falabella':
        return 'Falabella';
      case 'ripley':
        return 'Ripley';
      case 'paris':
        return 'Paris';
      case 'ahumada':
        return 'Ahumada';
      default:
        return store;
    }
  }

  factory StoreResult.fromJson(Map<String, dynamic> json) {
    final store = json['store'] as String? ?? 'desconocida';
    final error = json['error'] as String?;
    final results = json['results'] as List<dynamic>? ?? [];

    if (results.isEmpty) {
      return StoreResult(store: store, error: error ?? 'No se encontró el producto');
    }

    final first = Map<String, dynamic>.from(results.first as Map);

    return StoreResult(
      store: store,
      title: _firstString(first, ['title', 'name', 'productName', 'product_name']),
      priceText: _firstString(first, ['price', 'salePrice', 'currentPrice', 'precio', 'formattedPrice']),
      url: _firstString(first, ['url', 'link', 'productUrl', 'product_url']),
      imageUrl: _firstImageUrl(first, ['image', 'imageUrl', 'image_url', 'thumbnail', 'img', 'picture', 'images']),
      error: error,
    );
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return null;
  }

  /// Como `_firstString`, pero además acepta que el campo de imagen venga
  /// como una lista de URLs (algunas tiendas devuelven "images": [...]),
  /// en cuyo caso toma la primera.
  static String? _firstImageUrl(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is List && value.isNotEmpty) {
        final first = value.first;
        if (first != null && first.toString().trim().isNotEmpty) {
          return first.toString();
        }
      } else if (value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return null;
  }
}
