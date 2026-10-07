import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const PdnApp());
}

class PdnApp extends StatelessWidget {
  const PdnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Compara Precios',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
