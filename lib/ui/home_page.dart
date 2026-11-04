// Tab transition/retention adapted from Review main_scaffold.dart (MIT).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/design_system/components/review_frosted_app_bar.dart';
import '../core/design_system/components/review_navigation_bar.dart';
import '../core/theme/theme_provider.dart';
import '../core/utils/app_toast.dart';
import '../providers.dart';
import '../player/music_handler.dart';
import 'discover_view.dart';
import 'library_view.dart';
import 'search_view.dart';
import 'widgets.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _index = 0, _previous = 0;
  bool _transitioning = false;
  final _visited = {0};
  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  Animation<Offset> _incoming = const AlwaysStoppedAnimation(Offset.zero),
      _outgoing = const AlwaysStoppedAnimation(Offset.zero);
  late final VoidCallback _errorListener;
  late final MusicHandler _handler;
  @override
  void initState() {
    super.initState();
    _handler = ref.read(playerProvider);
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted && _transitioning) {
        setState(() => _transitioning = false);
      }
    });
    _errorListener = () {
      final error = _handler.errors.value;
      if (error != null && mounted) {
        AppToast.show(context, error, duration: const Duration(seconds: 5));
      }
    };
    _handler.errors.addListener(_errorListener);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.read(authProvider).session?.expired == true) {
      unawaited(runAction(context, ref.read(authProvider).ensureSession));
    }
  }

  @override
  void dispose() {
    _handler.errors.removeListener(_errorListener);
    WidgetsBinding.instance.removeObserver(this);
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    FocusScope.of(context).unfocus();
    _visited.add(index);
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      setState(() {
        _index = index;
        _previous = index;
        _transitioning = false;
        _incoming = const AlwaysStoppedAnimation(Offset.zero);
        _outgoing = const AlwaysStoppedAnimation(Offset.zero);
      });
      _controller.value = 1;
      return;
    }
    final offset = _transitioning ? _incoming.value : Offset.zero;
    var direction = index > _index ? 1.0 : -1.0;
    if (Directionality.of(context) == TextDirection.rtl) direction *= -1;
    setState(() {
      _previous = _index;
      _index = index;
      _transitioning = true;
      _incoming = Tween<Offset>(
        begin: Offset(direction, 0),
        end: Offset.zero,
      ).animate(_curve);
      _outgoing = Tween<Offset>(
        begin: offset,
        end: Offset(-direction, 0),
      ).animate(_curve);
    });
    _controller.forward(from: 0);
  }

  int _layer(int index) => index == _index
      ? 2
      : _transitioning && index == _previous
      ? 1
      : 0;
  @override
  Widget build(BuildContext context) {
    final floating = ref.watch(
      themeProvider.select((t) => t.useFloatingNavBar),
    );
    final order = List.generate(3, (i) => i)
      ..sort((a, b) => _layer(a).compareTo(_layer(b)));
    const pages = [DiscoverView(), SearchView(), LibraryView()];
    const destinations = [
      ReviewNavigationDestination(
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
        label: '发现',
      ),
      ReviewNavigationDestination(
        icon: Icons.search_outlined,
        selectedIcon: Icons.search_rounded,
        label: '搜索',
      ),
      ReviewNavigationDestination(
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music_rounded,
        label: '我的',
      ),
    ];
    final bottom = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MiniPlayer(),
        ReviewNavigationBar(
          destinations: destinations,
          selectedIndex: _index,
          onSelected: _select,
          hasBottomInset: MediaQuery.viewPaddingOf(context).bottom > 0,
          isTransitioning: _transitioning,
        ),
      ],
    );
    final scaffold = Scaffold(
      extendBody: floating,
      extendBodyBehindAppBar: true,
      appBar: ReviewFrostedAppBar(title: Text(destinations[_index].label)),
      bottomNavigationBar: floating
          ? bottom
          : SafeArea(top: false, child: bottom),
      body: _glassBody(
        floating && ref.watch(themeProvider).useLiquidGlass,
        Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final i in order)
              Positioned.fill(
                key: ValueKey(i),
                child: Offstage(
                  offstage: i != _index && (!_transitioning || i != _previous),
                  child: TickerMode(
                    enabled: i == _index || _transitioning && i == _previous,
                    child: IgnorePointer(
                      ignoring: i != _index,
                      child: SlideTransition(
                        position: i == _index
                            ? _incoming
                            : i == _previous && _transitioning
                            ? _outgoing
                            : const AlwaysStoppedAnimation(Offset.zero),
                        child: RepaintBoundary(
                          key: ValueKey('tab-$i'),
                          child: _visited.contains(i)
                              ? pages[i]
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return floating && ref.watch(themeProvider).useLiquidGlass
        ? LiquidGlassWidgets.wrap(
            adaptiveQuality: true,
            brightnessResolver: Theme.maybeBrightnessOf,
            child: GlassPage(enableBackgroundSampling: true, child: scaffold),
          )
        : scaffold;
  }

  Widget _glassBody(bool enabled, Widget body) =>
      enabled ? GlassBackgroundSource(child: body) : body;
}
