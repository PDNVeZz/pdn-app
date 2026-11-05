import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/price_alert.dart';
import '../services/api_service.dart';

/// "Mis alertas": lista de alertas del usuario, con opción de pausarlas,
/// borrarlas o revisarlas al instante, y el paso de vincular Telegram (que es
/// por donde llegan los avisos).
class AlertsScreen extends StatefulWidget {
  /// true cuando se llega justo después de crear una alerta.
  final bool justCreated;

  const AlertsScreen({super.key, this.justCreated = false});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<PriceAlert> _alerts = [];
  bool _loading = true;
  String? _error;

  bool _telegramLinked = false;
  bool _botConfigured = true;
  bool _linkingInProgress = false; // abrió el enlace y espera confirmar
  bool _busyTelegram = false;
  final Set<String> _checking = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ApiService.listAlerts(),
        ApiService.telegramStatus(),
      ]);
      if (!mounted) return;
      final status = results[1] as Map<String, dynamic>;
      setState(() {
        _alerts = results[0] as List<PriceAlert>;
        _telegramLinked = status['linked'] as bool? ?? false;
        _botConfigured = status['bot_configured'] as bool? ?? false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // --- Telegram -----------------------------------------------------------

  Future<void> _startTelegramLink() async {
    setState(() => _busyTelegram = true);
    try {
      final url = await ApiService.telegramLinkUrl();
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened) _snack('No pude abrir Telegram. Abre este enlace a mano: $url');
      if (mounted) setState(() => _linkingInProgress = true);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busyTelegram = false);
    }
  }

  Future<void> _verifyTelegram() async {
    setState(() => _busyTelegram = true);
    try {
      final linked = await ApiService.telegramVerify();
      if (!mounted) return;
      setState(() {
        _telegramLinked = linked;
        if (linked) _linkingInProgress = false;
      });
      _snack(linked
          ? 'Telegram vinculado. Te llegará un mensaje de confirmación.'
          : 'Aún no veo tu mensaje. En Telegram toca "Iniciar" y vuelve a probar.');
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busyTelegram = false);
    }
  }

  Widget _telegramCard(BuildContext context) {
    final theme = Theme.of(context);

    if (_telegramLinked) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.check_circle, color: theme.colorScheme.primary),
          title: const Text('Telegram vinculado'),
          subtitle: const Text('Los avisos te llegarán por ahí.'),
        ),
      );
    }

    if (!_botConfigured) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.warning_amber_rounded),
          title: Text('Telegram aún no está configurado en el servidor'),
          subtitle: Text('Falta el TELEGRAM_BOT_TOKEN en Railway. Mientras tanto las alertas '
              'se revisan, pero no te llegará el aviso.'),
        ),
      );
    }

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vincula Telegram para recibir los avisos',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(_linkingInProgress
                ? 'En Telegram toca "Iniciar" en el chat del bot y luego vuelve aquí a confirmar.'
                : 'Se abrirá el bot en Telegram. Solo toca "Iniciar".'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busyTelegram ? null : _startTelegramLink,
                  icon: const Icon(Icons.send),
                  label: Text(_linkingInProgress ? 'Abrir de nuevo' : 'Vincular Telegram'),
                ),
                if (_linkingInProgress)
                  OutlinedButton.icon(
                    onPressed: _busyTelegram ? null : _verifyTelegram,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Ya le di Iniciar'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- Acciones sobre alertas ---------------------------------------------

  void _replace(PriceAlert updated) {
    final i = _alerts.indexWhere((a) => a.id == updated.id);
    if (i >= 0) setState(() => _alerts[i] = updated);
  }

  Future<void> _toggleActive(PriceAlert alert, bool active) async {
    try {
      _replace(await ApiService.updateAlert(alert.id, {'active': active}));
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _delete(PriceAlert alert) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar alerta'),
        content: Text('¿Eliminar la alerta de "${alert.query}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiService.deleteAlert(alert.id);
      if (!mounted) return;
      setState(() => _alerts.removeWhere((a) => a.id == alert.id));
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _checkNow(PriceAlert alert) async {
    setState(() => _checking.add(alert.id));
    try {
      final updated = await ApiService.checkAlertNow(alert.id);
      _replace(updated);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _checking.remove(alert.id));
    }
  }

  // --- UI -----------------------------------------------------------------

  static String _fmt(num value) {
    final s = value.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return '\$$buf';
  }

  static String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _storeLabel(String? store) {
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
        return store ?? '';
    }
  }

  Widget _alertCard(BuildContext context, PriceAlert alert) {
    final theme = Theme.of(context);
    final checking = _checking.contains(alert.id);
    final reached = alert.lastBestPrice != null && alert.lastBestPrice! <= alert.targetPrice;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(alert.query,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Switch(
                  value: alert.active,
                  onChanged: (v) => _toggleActive(alert, v),
                ),
              ],
            ),
            Text('Avisar a ${_fmt(alert.targetPrice)} o menos'),
            const SizedBox(height: 4),
            Text('${alert.daysSummary} · ${alert.hoursSummary}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (alert.lastBestPrice != null)
              Text(
                'Mejor precio: ${_fmt(alert.lastBestPrice!)} en ${_storeLabel(alert.lastBestStore)}'
                '${reached ? '  ✔ objetivo alcanzado' : ''}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: reached ? theme.colorScheme.primary : null,
                ),
              )
            else
              Text('Aún sin revisar. La primera revisión corre en un minuto.',
                  style: theme.textTheme.bodySmall),
            if (alert.lastCheckedAt != null)
              Text('Última revisión: ${_fmtDate(alert.lastCheckedAt!)}',
                  style: theme.textTheme.bodySmall),
            if (alert.active && alert.nextCheckAt != null)
              Text('Próxima revisión: ${_fmtDate(alert.nextCheckAt!)}',
                  style: theme.textTheme.bodySmall),
            if (alert.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(alert.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (alert.lastBestUrl != null)
                  TextButton.icon(
                    onPressed: () => launchUrl(Uri.parse(alert.lastBestUrl!),
                        mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Comprar'),
                  ),
                TextButton.icon(
                  onPressed: checking ? null : () => _checkNow(alert),
                  icon: checking
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(checking ? 'Revisando...' : 'Revisar ahora'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Eliminar',
                  onPressed: () => _delete(alert),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.justCreated)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Alerta creada. Ya quedó programada.'),
            ),
          _telegramCard(context),
          const SizedBox(height: 12),
          if (_alerts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Aún no tienes alertas. Busca un producto y toca "Crear alerta" en la pantalla de resultados.',
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final alert in _alerts) ...[
              _alertCard(context, alert),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis alertas'),
        actions: [
          IconButton(tooltip: 'Actualizar', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _body(context),
          ),
        ),
      ),
    );
  }
}
