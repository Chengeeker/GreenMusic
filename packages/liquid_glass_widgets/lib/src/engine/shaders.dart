// Copyright 2024-2025 Tim Lehmann for whynotmake.it
//
// SPDX-License-Identifier: MIT
//
// Originally from liquid_glass_renderer (whynotmake.it).
// Maintained and evolved in-tree for liquid_glass_widgets.
// See lib/src/engine/ATTRIBUTION.md for provenance and modification history.

// ignore_for_file: public_member_api_docs

// App-level widget tests use the dependency's namespaced assets too.
const String _shadersRoot = 'packages/liquid_glass_widgets/';

abstract class ShaderKeys {
  const ShaderKeys._();

  static final blendedGeometry =
      '${_shadersRoot}shaders/liquid_glass_geometry_blended.frag';

  static final liquidGlassRender =
      '${_shadersRoot}shaders/liquid_glass_render.frag';
}
