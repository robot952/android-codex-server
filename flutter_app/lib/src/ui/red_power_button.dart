import 'package:flutter/material.dart';

import 'theme.dart';

class RedPowerButton extends StatelessWidget {
  const RedPowerButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Container(
        // Same 24 dp face as the 40 dp server row button after its padding.
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: codexRed.withValues(alpha: 0.2),
          border: Border.all(color: codexRed.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.08),
              blurRadius: 1,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: const Icon(Icons.power_settings_new, size: 17, color: codexRed),
      ),
    );
  }
}
