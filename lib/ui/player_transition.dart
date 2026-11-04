import 'package:flutter/material.dart';

import 'player_page.dart';
import 'widgets.dart';

enum PlayerPart { artwork, title, artist }

Widget inactivePlayerTransition(Widget child) => HeroMode(
  enabled: false,
  child: TickerMode(
    enabled: false,
    child: IgnorePointer(
      child: ExcludeFocus(child: ExcludeSemantics(child: child)),
    ),
  ),
);

void openPlayer(BuildContext miniContext) {
  if (ModalRoute.of(miniContext)?.isCurrent != true) return;
  final navigator = Navigator.of(miniContext);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  Rect? miniBounds() {
    if (!miniContext.mounted) return null;
    final box = miniContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  }

  final initialBounds = miniBounds()!;
  final reduceMotion = MediaQuery.disableAnimationsOf(miniContext);
  navigator.push(
    PageRouteBuilder<void>(
      transitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 400),
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 360),
      pageBuilder: (_, animation, secondaryAnimation) => const PlayerPage(),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (reduceMotion) return child;
        return LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (context, child) {
              final t = Curves.easeInOutCubic.transform(animation.value);
              final rect = Rect.lerp(
                miniBounds() ?? initialBounds,
                Offset.zero & constraints.biggest,
                t,
              )!;
              // Keep the page laid out at full size; only its surface contracts.
              return Stack(
                children: [
                  Positioned.fromRect(
                    rect: rect,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24 * (1 - t)),
                      child: Opacity(
                        opacity: (t / .3).clamp(0.0, 1.0),
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minWidth: constraints.maxWidth,
                          maxWidth: constraints.maxWidth,
                          minHeight: constraints.maxHeight,
                          maxHeight: constraints.maxHeight,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ),
  );
}

class PlayerHero extends StatelessWidget {
  const PlayerHero({super.key, required this.part, required this.child});
  final PlayerPart part;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return Hero(
      tag: part,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
      flightShuttleBuilder: (context, animation, direction, from, to) {
        final miniContext = direction == HeroFlightDirection.push ? from : to;
        final fullContext = direction == HeroFlightDirection.push ? to : from;
        final mini = (miniContext.widget as Hero).child;
        final full = (fullContext.widget as Hero).child;
        if (part == PlayerPart.artwork) {
          final small = mini as Cover, large = full as Cover;
          return AnimatedBuilder(
            animation: animation,
            child: Cover(
              large.url,
              size: large.size,
              radius: 0,
              // Keep the cached mini cover visible while the larger image loads.
              placeholder: FittedBox(
                fit: BoxFit.cover,
                child: Cover(small.url, size: small.size, radius: 0),
              ),
            ),
            builder: (context, child) => ClipRRect(
              key: const ValueKey('player-artwork-flight'),
              borderRadius: BorderRadius.circular(
                small.radius + (large.radius - small.radius) * animation.value,
              ),
              child: FittedBox(fit: BoxFit.cover, child: child),
            ),
          );
        }
        final small = mini as Text, large = full as Text;
        final smallStyle = DefaultTextStyle.of(miniContext).style
            .merge(small.style);
        final largeStyle = DefaultTextStyle.of(fullContext).style
            .merge(large.style);
        return Material(
          type: MaterialType.transparency,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) => Text(
                large.data!,
                style: TextStyle.lerp(smallStyle, largeStyle, animation.value),
                maxLines: large.maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}
