import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Identificador anónimo de este usuario/instalación. Se genera una vez y se
/// guarda en el dispositivo; el backend lo usa para saber de quién es cada
/// alerta y a qué Telegram avisarle. Cuando la app tenga cuentas reales
/// (varios usuarios), este id se reemplaza por el del login.
class UserId {
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('user_id');
    if (id == null || id.length < 8) {
      final rng = Random.secure();
      const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
      id = List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
      await prefs.setString('user_id', id);
    }
    _cached = id;
    return id;
  }
}
