import 'package:flutter/material.dart';

// Review's settings section title sits outside the card, aligned with its content.
class AppSectionHeading extends StatelessWidget {
  const AppSectionHeading(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Low-emphasis, flush surface for grouped settings and utility actions.
class AppSectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;

  const AppSectionCard({super.key, required this.child, this.margin});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.surface == Colors.black
        ? scheme.surfaceContainer
        : scheme.surfaceContainerLow;
    return Card(
      margin: margin ?? EdgeInsets.zero,
      color: color,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide.none,
      ),
      child: child,
    );
  }
}
