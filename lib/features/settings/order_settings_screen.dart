import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/order_service.dart';

/// bestell_manager connection (base URL plus the host's own bestell_manager
/// account e-mail/password) for the order tile - its own sub-page for the same
/// reason as LocationSettingsScreen (text fields in the main settings list
/// trap the D-Pad). Saving also runs one test request so a typo'd password
/// doesn't just silently show no tile.
class OrderSettingsScreen extends ConsumerStatefulWidget {
  const OrderSettingsScreen({super.key});

  @override
  ConsumerState<OrderSettingsScreen> createState() => _OrderSettingsScreenState();
}

class _OrderSettingsScreenState extends ConsumerState<OrderSettingsScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _userController;
  late final TextEditingController _passwordController;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(orderSettingsProvider);
    _urlController = TextEditingController(text: settings.baseUrl);
    _userController = TextEditingController(text: settings.user);
    _passwordController = TextEditingController(text: settings.password);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final baseUrl = _urlController.text.trim();
    final user = _userController.text.trim();
    final password = _passwordController.text;
    await ref.read(orderSettingsProvider.notifier).setApi(baseUrl: baseUrl, user: user, password: password);

    setState(() => _testing = true);
    final result = await ref
        .read(orderServiceProvider)
        .fetchToday(baseUrl: baseUrl, user: user, password: password);
    if (!mounted) return;
    setState(() => _testing = false);
    final message = switch (result.status) {
      OrderFetchStatus.ok when result.day != null => 'Gespeichert - heute: ${result.day!.title}',
      OrderFetchStatus.ok => 'Gespeichert - Verbindung OK, heute kein Bestelltag.',
      OrderFetchStatus.unauthorized => 'Gespeichert - aber E-Mail/Passwort falsch oder Konto nicht freigeschaltet.',
      OrderFetchStatus.error => 'Gespeichert - aber der Server ist nicht erreichbar.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bestellung einrichten')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Verbindung zum Bestell-Manager. An einem Bestelltag wird die Wetterkachel halbiert und '
            'darunter die Bestell-Kachel mit QR-Code angezeigt.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(labelText: 'Server-Adresse'),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _userController,
            decoration: const InputDecoration(labelText: 'E-Mail (Bestell-Manager-Konto)'),
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Passwort'),
            obscureText: true,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _testing ? null : _save,
              icon: _testing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('Speichern & testen'),
            ),
          ),
        ],
      ),
    );
  }
}
