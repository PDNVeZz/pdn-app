/// Una alerta de precio configurada por el usuario, tal como la devuelve el
/// backend.
class PriceAlert {
  final String id;
  final String query;
  final int targetPrice;
  final List<int> days; // 0 = lunes ... 6 = domingo
  final List<int> hours; // 0-23, horario de Chile
  final bool active;
  final DateTime? nextCheckAt;
  final DateTime? lastCheckedAt;
  final double? lastBestPrice;
  final String? lastBestStore;
  final String? lastBestUrl;
  final String? lastError;
  final bool notified;

  PriceAlert({
    required this.id,
    required this.query,
    required this.targetPrice,
    required this.days,
    required this.hours,
    required this.active,
    this.nextCheckAt,
    this.lastCheckedAt,
    this.lastBestPrice,
    this.lastBestStore,
    this.lastBestUrl,
    this.lastError,
    required this.notified,
  });

  static const dayNames = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

  factory PriceAlert.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) =>
        v == null ? null : DateTime.parse(v as String).toLocal();

    return PriceAlert(
      id: json['id'] as String,
      query: json['query'] as String,
      targetPrice: (json['target_price'] as num).toInt(),
      days: (json['days'] as List<dynamic>).map((e) => (e as num).toInt()).toList(),
      hours: (json['hours'] as List<dynamic>).map((e) => (e as num).toInt()).toList(),
      active: json['active'] as bool? ?? true,
      nextCheckAt: parseDate(json['next_check_at']),
      lastCheckedAt: parseDate(json['last_checked_at']),
      lastBestPrice: (json['last_best_price'] as num?)?.toDouble(),
      lastBestStore: json['last_best_store'] as String?,
      lastBestUrl: json['last_best_url'] as String?,
      lastError: json['last_error'] as String?,
      notified: json['notified'] as bool? ?? false,
    );
  }

  /// Resumen legible de los días: "Todos los días", "Lun a Vie", "Sáb y Dom"...
  String get daysSummary {
    final set = days.toSet();
    if (set.length == 7) return 'Todos los días';
    if (set.length == 5 && set.containsAll([0, 1, 2, 3, 4])) return 'Lunes a viernes';
    if (set.length == 2 && set.containsAll([5, 6])) return 'Fines de semana';
    return (days.toList()..sort()).map((d) => dayNames[d]).join(', ');
  }

  String get hoursSummary =>
      (hours.toList()..sort()).map((h) => '${h.toString().padLeft(2, '0')}:00').join(', ');
}
