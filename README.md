# ReShade-HDR-Simulate-Oversaturation

[English](README.md) | [简体中文](README.zh-CN.md)

A ReShade shader that recreates the classic "narrow-gamut content displayed without color management on a wide-gamut screen" look — the oversaturated, punchy colors many people remember from SDR displays before proper color management was common.

Unlike generic saturation/vibrance shaders, this doesn't push saturation via HSV/HSL math. Instead, it reproduces the actual mechanism behind the look: it takes the linear light your HDR pipeline is correctly displaying as Rec.709/sRGB values, then re-reads those same three numbers through the **wrong** (wider) set of primaries — Display P3 instead of sRGB — exactly what happens when a display receives an sRGB-referred signal and interprets it as native wide-gamut RGB without conversion.

Because this is a real primaries matrix transform, the red/green/blue channels scale together, so colors like yellow get richer without the hue-shifting artifacts you get from naive per-channel saturation boosts. It's also a fixed linear transform applied uniformly at any brightness — including HDR highlights well above SDR reference white — so there's no reference-white parameter to get wrong, and no highlight detail is lost.

Only runs when the ReShade backbuffer is in an HDR color space (scRGB or HDR10 PQ); does nothing in SDR.

## How it works

1. Decode the pixel from your HDR backbuffer (scRGB is already linear; HDR10 PQ is decoded to linear BT.2020) and bring it to Rec.709 linear light.
2. Re-read those same values as Display P3 primaries — this is the "bug".
3. Blend with the original according to **Effect Strength**, in linear light, so the slider behaves identically in scRGB and HDR10 PQ.
4. Encode back to your display's actual output format.

The whole chain is pre-merged into single 3×3 matrices, all derived from the same D65 white point (x = 0.3127, y = 0.3290). Every matrix row sums to 1, so neutral colors are left untouched: black stays black, grays stay gray, and white stays exactly white.

## Parameters

| Parameter               | Description |
| ----------------------- | ----------- |
| **Color Space Mode**    | `Auto` uses ReShade's detected color space at compile time. If you toggle HDR on/off in-game and the effect stops responding, ReShade likely failed to refresh its color space detection — switch this to `Force HDR10 PQ` or `Force scRGB` manually (no restart needed, takes effect instantly like any other slider) to fix it. `Force Off` disables the effect entirely. Forcing the wrong mode will make the image look broken; switch back to `Auto` or pick the correct mode to recover. |
| **Effect Strength (%)** | 0 = untouched/correct color, 100 = full effect. Blended in linear light. |

## Installation

1. Drop `SimulateSRGBAsP3.fx` into your ReShade shaders folder (same place as your other `.fx` files).
2. Enable HDR in-game and in Windows.
3. In the ReShade overlay, enable `SimulateSRGBAsP3`.

If you're also using other saturation/color-grading shaders, put this one **above** them in the effect list (ReShade processes top to bottom) so it operates on the color before other adjustments are layered on.

## Limitations

- Assumes the underlying game content is authored for Rec.709/sRGB gamut, which covers the vast majority of games. Natively wide-gamut content will look over-saturated.
- The input is not clamped to Rec.709, so out-of-gamut colors go through the same linear transform. The result can fall outside Display P3; what happens to those colors is up to your display. In HDR10 PQ mode, components that end up negative cannot be encoded and are dropped at the final step; scRGB keeps them.
- The effect is only visible on a display whose gamut is wider than sRGB.
- It processes the final image, so UI elements, text and HUD colors are affected as well as the 3D scene.
- HDR10 HLG is not supported and is treated as "off".
- `Color Space Mode` auto-detection depends on ReShade correctly reporting `BUFFER_COLOR_SPACE` at compile time. This is known to sometimes go stale after toggling HDR off/on within the same game session — use the manual override if that happens.

## License

MIT
