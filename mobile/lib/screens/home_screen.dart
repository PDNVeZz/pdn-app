import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'alerts_screen.dart';
import 'results_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _searchController = TextEditingController();
  bool _loading = false;
  String _loadingMessage = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Busca los precios de [productName] en todas las tiendas y abre la
  /// pantalla de resultados. Lo usan tanto la búsqueda por foto como la
  /// búsqueda por texto, para no repetir la lógica.
  Future<void> _searchAndShow(String productName) async {
    setState(() {
      _loading = true;
      _loadingMessage = 'Buscando precios en Falabella, Ripley, Paris y Ahumada...';
    });

    final results = await ApiService.searchPrices(productName);

    if (!mounted) return;
    setState(() => _loading = false);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultsScreen(productName: productName, results: results),
      ),
    );
  }

  Future<void> _pickAndSearch(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source, imageQuality: 85);
      if (image == null) return; // el usuario canceló

      setState(() {
        _loading = true;
        _loadingMessage = 'Identificando el producto...';
      });

      final productName = await ApiService.identifyProduct(image);

      if (!mounted) return;
      await _searchAndShow(productName);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _searchByText() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe el nombre del producto que quieres buscar')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    try {
      await _searchAndShow(query);
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compara Precios'),
        actions: [
          IconButton(
            tooltip: 'Mis alertas',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AlertsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: _loading ? _buildLoading() : _buildIdle(context),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(_loadingMessage, textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _buildIdle(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    // Scroll para que el teclado no tape los botones en pantallas chicas.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.price_check, size: 80, color: colors.primary),
            const SizedBox(height: 16),
            Text(
              'Encuentra el mejor precio',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Saca una foto, elige una de tu galería o busca por nombre',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _pickAndSearch(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Tomar foto'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _pickAndSearch(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Elegir de galería'),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('o busca por nombre', style: Theme.of(context).textTheme.bodySmall),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchByText(),
              decoration: InputDecoration(
                hintText: 'Ej: Audífonos Sony WH-1000XM5',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _searchByText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
