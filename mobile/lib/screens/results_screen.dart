import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/store_result.dart';

class ResultsScreen extends StatelessWidget {
  final String productName;
  final List<StoreResult> results;

  const ResultsScreen({
    super.key,
    required this.productName,
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    // Ordena: primero las tiendas donde SÍ se encontró precio (de más barata
    // a más cara), y al final las que no encontraron nada o dieron error.
    final sorted = [...results];
    sorted.sort((a, b) {
      if (a.priceValue == null && b.priceValue == null) return 0;
      if (a.priceValue == null) return 1;
      if (b.priceValue == null) return -1;
      return a.priceValue!.compareTo(b.priceValue!);
    });

    final bestPrice = sorted.isNotEmpty && sorted.first.priceValue != null
        ? sorted.first.priceValue
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Comparación de precios')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              productName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: sorted.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final result = sorted[index];
                final isBest = bestPrice != null && result.priceValue == bestPrice;
                return _StoreCard(result: result, highlight: isBest);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StoreCard extends StatelessWidget {
  final StoreResult result;
  final bool highlight;

  const _StoreCard({required this.result, required this.highlight});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: highlight ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: highlight
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StoreImage(result: result),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        result.storeLabel,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (highlight) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'MÁS BARATO',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (result.found) ...[
                    if (result.title != null)
                      Text(
                        result.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      result.priceText!,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: highlight ? Theme.of(context).colorScheme.primary : null,
                          ),
                    ),
                    if (result.url != null) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _openProductUrl(context, result.url!),
                          icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                          label: const Text('Comprar'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            alignment: Alignment.centerLeft,
                          ),
                        ),
                      ),
                    ],
                  ] else
                    Text(
                      result.error ?? 'No se encontró el producto en esta tienda',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openProductUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el link del producto')),
      );
    }
  }
}

/// Miniatura del producto encontrado en la tienda. Si no hay imagen, o si
/// falla la carga (URL rota, bloqueada, etc.), muestra un ícono de
/// reemplazo en vez de dejar un espacio vacío o romper la pantalla.
class _StoreImage extends StatelessWidget {
  final StoreResult result;

  const _StoreImage({required this.result});

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    // Usamos la imagen a través del proxy del backend: varias tiendas
    // (Paris, Ripley, Ahumada) bloquean que su imagen se cargue directamente
    // desde otro sitio o app, y el backend evita ese bloqueo descargándola
    // por su cuenta.
    final url = result.proxiedImageUrl;

    Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 24,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (!result.found || url == null) {
      return placeholder;
    }

    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return SizedBox(
            width: size,
            height: size,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );

    return GestureDetector(
      onTap: () => _openFullImage(context, url, result.title),
      child: thumbnail,
    );
  }

  void _openFullImage(BuildContext context, String url, String? title) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const Padding(
                        padding: EdgeInsets.all(48),
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) => const Padding(
                      padding: EdgeInsets.all(48),
                      child: Icon(Icons.broken_image, color: Colors.white, size: 48),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
