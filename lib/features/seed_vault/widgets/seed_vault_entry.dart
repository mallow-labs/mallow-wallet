import 'package:flutter/material.dart';

import '../../../core/services/seed_vault_service.dart';
import '../../../di.dart';

/// Whether this device has a Seed Vault implementation.
///
/// The single gate every Seed Vault entry point must pass. It is a runtime
/// check, never a device-model check: `Build.MODEL` is spoofable, while this
/// answers from the signature protection on the implementation's own
/// permission. On a plain Android phone and on iOS it is false, so the whole
/// feature is invisible there — the same binary ships everywhere.
Future<bool> isSeedVaultAvailable() => sl<SeedVaultService>().isAvailable();

/// Renders [builder] only once [isSeedVaultAvailable] has answered true.
///
/// Renders nothing — not a spinner, not a placeholder — while the probe is in
/// flight or when the answer is false. An entry row that flickers in and out,
/// or one that renders and then dead-ends, is worse than one that never
/// appears.
class SeedVaultEntry extends StatefulWidget {
  const SeedVaultEntry({required this.builder, super.key});

  final WidgetBuilder builder;

  @override
  State<SeedVaultEntry> createState() => _SeedVaultEntryState();
}

class _SeedVaultEntryState extends State<SeedVaultEntry> {
  bool _available = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    // isAvailable is fail-soft in the service, so this cannot throw — a broken
    // probe answers false and hides the feature rather than breaking the screen
    // that asked.
    final available = await isSeedVaultAvailable();
    if (!mounted || !available) return;
    setState(() => _available = true);
  }

  @override
  Widget build(BuildContext context) =>
      _available ? widget.builder(context) : const SizedBox.shrink();
}
