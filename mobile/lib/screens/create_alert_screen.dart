import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import 'alerts_screen.dart';

/// Segunda ventana: después de ver los precios, el usuario define a qué
/// valor quiere que le avisen, en qué días de la semana y a qué horas se
/// vuelve a revisar el producto.
class CreateAlertScreen extends StatefulWidget {
  final String productName;

  /// Mejor precio encontrado hoy (solo referencia, puede ser null).
  final double? currentBestPrice;

  const CreateAlertScreen({
    super.key,
    required this.productName,
    this.currentBestPrice,
  });

  @override
  State<CreateAlertScreen> createState() => _CreateAlertScreenState();
}

class _CreateAlertScreenState extends State<CreateAlertScreen> {
  static const int _maxHours = 12;

  final TextEditingController _priceController = TextEditingController();
  final Set<int> _days = {0, 1, 2, 3, 4, 5, 6};
  final Set<int> _hours = {9, 18};
  bool _saving = false;

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  static String _fmt(num value) {
    final s = value.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return '\$$buf';
  }

  bool get _isWeekdays => _days.length == 5 && _days.containsAll([0, 1, 2, 3, 4]);
  bool get _isWeekend => _days.length == 2 && _days.containsAll([5, 6]);
  bool get _isEveryDay => _days.length == 7;

  void _setDays(Iterable<int> days) {
    setState(() {
      _days
        ..clear()
        ..addAll(days);
    });
  }

  void _toggleHour(int hour, bool selected) {
    if (selected && _hours.length >= _maxHours) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Máximo 12 horas por día')),
      );
      return;
    }
    setState(() => selected ? _hours.add(hour) : _hours.remove(hour));
  }

  Future<void> _save() async {
    final target = int.tryParse(_priceController.text.trim());
    String? problem;
    if (target == null || target <= 0) {
      problem = 'Escribe el precio al que quieres que te avise';
    } else if (_days.isEmpty) {
      problem = 'Elige al menos un día';
    } else if (_hours.isEmpty) {
      problem = 'Elige al menos una hora';
    }
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    try {
      await ApiService.createAlert(
        query: widget.productName,
        targetPrice: target!,
        days: _days.toList()..sort(),
        hours: _hours.toList()..sort(),
      );
      if (!mounted) return;
      // Pasamos a "Mis alertas", donde también se vincula Telegram.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AlertsScreen(justCreated: true)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checksPerWeek = _days.length * _hours.length;
    final current = widget.currentBestPrice;
    final target = int.tryParse(_priceController.text.trim());

    return Scaffold(
      appBar: AppBar(title: const Text('Crear alerta de precio')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(widget.productName,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                if (current != null) ...[
                  const SizedBox(height: 4),
                  Text('Mejor precio hoy: ${_fmt(current)}', style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 24),

                // --- Valor buscado -------------------------------------
                Text('Avísame cuando cueste', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _priceController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixText: '\$ ',
                    hintText: current != null ? 'Ej: ${(current * 0.9).round()}' : 'Ej: 15000',
                    helperText: 'Te aviso cuando alguna tienda llegue a este valor o menos',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                if (current != null && target != null && target >= current)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Ese valor ya se cumple hoy: te avisaré en la primera revisión.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
                const SizedBox(height: 28),

                // --- Días ------------------------------------------------
                Text('Días a buscar', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos los días'),
                      selected: _isEveryDay,
                      onSelected: (_) => _setDays(List.generate(7, (i) => i)),
                    ),
                    ChoiceChip(
                      label: const Text('Días de semana'),
                      selected: _isWeekdays,
                      onSelected: (_) => _setDays([0, 1, 2, 3, 4]),
                    ),
                    ChoiceChip(
                      label: const Text('Fines de semana'),
                      selected: _isWeekend,
                      onSelected: (_) => _setDays([5, 6]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (var d = 0; d < 7; d++)
                      FilterChip(
                        label: Text(const [
                          'Lunes',
                          'Martes',
                          'Miércoles',
                          'Jueves',
                          'Viernes',
                          'Sábado',
                          'Domingo'
                        ][d]),
                        selected: _days.contains(d),
                        onSelected: (sel) =>
                            setState(() => sel ? _days.add(d) : _days.remove(d)),
                      ),
                  ],
                ),
                const SizedBox(height: 28),

                // --- Horas -----------------------------------------------
                Text('Horas a buscar', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Hora de Chile. Máximo $_maxHours por día.',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (var h = 0; h < 24; h++)
                      FilterChip(
                        label: Text('${h.toString().padLeft(2, '0')}:00'),
                        selected: _hours.contains(h),
                        onSelected: (sel) => _toggleHour(h, sel),
                      ),
                  ],
                ),
                const SizedBox(height: 20),

                // --- Resumen ---------------------------------------------
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      checksPerWeek == 0
                          ? 'Elige días y horas para ver el resumen.'
                          : 'Se revisará $checksPerWeek ${checksPerWeek == 1 ? 'vez' : 'veces'} '
                              'por semana. Cada revisión consulta las 4 tiendas y usa créditos '
                              'de Apify, así que mientras más horas, más gasto.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.notifications_active),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Crear alerta'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
