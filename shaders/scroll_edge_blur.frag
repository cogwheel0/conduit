// One pass of the soft scroll edge's progressive blur (ConduitScrollEdgeEffect).
//
// A Gaussian whose sigma depends on the distance from the screen edge: full
// strength out to `uProfile.y`, easing to nothing at `uProfile.x`. Run once
// horizontally and once vertically (ImageFilter.compose) as a backdrop
// filter. Fragment coordinates are the render target's, in physical pixels.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
// x: 1 for the vertical pass, 0 for the horizontal one.
// y: 1 when the edge is the top of the screen, 0 for the bottom.
uniform vec2 uMode;
// x: distance from the screen edge where the blur ends (px).
// y: distance where it reaches full strength (px).
// z: full sigma (px).
// w: the screen's height (px), the origin of distances for a bottom edge.
uniform vec4 uProfile;
uniform sampler2D uTexture;

out vec4 fragColor;

const int kTaps = 14;

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 uv = coord / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  // GLES flips y; keep the content as it is rather than guess the edge.
  uv.y = 1.0 - uv.y;
  fragColor = texture(uTexture, uv);
#else
  float fromEdge = uMode.y > 0.5 ? coord.y : uProfile.w - coord.y;
  float span = max(uProfile.x - uProfile.y, 1.0);
  float u = clamp((uProfile.x - fromEdge) / span, 0.0, 1.0);
  float sigma = uProfile.z * pow(u, 1.6);
  if (sigma < 0.35) {
    fragColor = texture(uTexture, uv);
    return;
  }
  vec2 dir = uMode.x > 0.5 ? vec2(0.0, 1.0 / uSize.y) : vec2(1.0 / uSize.x, 0.0);
  // Taps reach 3 sigma; spacing never drops below a pixel, and bilinear
  // sampling between taps keeps wide kernels smooth.
  float spacing = max(sigma * 3.0 / float(kTaps), 1.0);
  float inv = -0.5 / (sigma * sigma);
  vec4 sum = texture(uTexture, uv);
  float total = 1.0;
  for (int i = 1; i <= kTaps; i++) {
    float x = float(i) * spacing;
    float w = exp(x * x * inv);
    sum += (texture(uTexture, uv + dir * x) + texture(uTexture, uv - dir * x)) * w;
    total += 2.0 * w;
  }
  fragColor = sum / total;
#endif
}
