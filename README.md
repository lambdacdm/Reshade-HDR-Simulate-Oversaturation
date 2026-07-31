# ReShade-HDR-Simulate-Oversaturation

[English](README.md) | [简体中文](README.zh-CN.md)

A ReShade shader that recreates the classic "narrow-gamut content displayed without color management on a wide-gamut screen" look — the oversaturated, punchy colors many people remember from SDR displays before proper color management was common.

Unlike generic saturation/vibrance shaders, this doesn't push saturation via HSV/HSL math. Instead, it reproduces the actual mechanism behind the look: it converts the color your HDR pipeline is correctly displaying back into Rec.709/sRGB-referred linear light, then re-mixes that same linear light through the **wrong** (wider) set of primaries — Display P3 instead of sRGB — exactly what happens when a display receives an sRGB-referred signal and interprets it as native wide-gamut RGB without conversion.

Because this is a real primaries matrix transform, red/green/blue channels scale together, so colors like yellow get richer without the hue-shifting artifacts you get from naive per-channel saturation boosts. It's also a fixed linear transform applied uniformly at any brightness — including HDR highlights well above SDR reference white — so there's no clipping, no reference-white parameter to get wrong, and no highlight detail loss.

Only runs when the ReShade backbuffer is in an HDR color space (scRGB or HDR10 PQ); does nothing in SDR.

## How it works

1. Decode the current pixel from your HDR backbuffer (scRGB linear or HDR10 PQ) into XYZ.
2. Convert that XYZ into Rec.709/sRGB-referred linear light.
3. Re-mix that same linear light through the Display P3 primaries instead of sRGB — this is the "bug".
4. Convert back to your display's actual output format so it displays correctly.

## Parameters

| Parameter | Description |
|---|---|
| **Color Space Mode** | `Auto` uses ReShade's detected color space at compile time. If you toggle HDR on/off in-game and the effect stops responding, ReShade likely failed to refresh its color space detection — switch this to `Force HDR10 PQ` or `Force scRGB` manually (no restart needed, takes effect instantly like any other slider) to fix it. `Force Off` disables the effect entirely. |
| **Effect Strength (%)** | 0 = untouched/correct color, 100 = full effect. Blend to taste. |

## Installation

1. Drop `SimulateSRGBAsP3.fx` into your ReShade shaders folder (same place as your other `.fx` files).
2. Enable HDR in-game and in Windows.
3. In the ReShade overlay, enable `SimulateSRGBAsP3`.

If you're also using other saturation/color-grading shaders, put this one **above** them in the effect list (ReShade processes top to bottom) so it operates on the color before other adjustments are layered on.

## Limitations

- Assumes the underlying game content is authored for Rec.709/sRGB gamut, which covers the vast majority of games. Native wide-gamut rendering will not be handled correctly.
- `Color Space Mode` auto-detection depends on ReShade correctly reporting `BUFFER_COLOR_SPACE` at compile time. This is known to sometimes go stale after toggling HDR off/on within the same game session — use the manual override if that happens.

## License

MIT
