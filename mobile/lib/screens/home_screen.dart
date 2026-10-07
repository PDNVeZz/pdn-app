import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'results_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _loading = false;
  String _loadingMessage = '';

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
      setState(() {
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compara Precios')),
      body: Center(
        child: _loading ? _buildLoading() : _buildIdle(context),
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_camera_outlined, size: 96, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Saca una foto del producto que quieres comparar',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 32),
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
        ],
      ),
    );
  }
}
