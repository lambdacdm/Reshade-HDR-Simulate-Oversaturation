// ============================================================================
// SimulateSRGBAsP3.fx
//
// EN: Recreates the look of sRGB content being sent to a wide-gamut (Display P3)
//     panel WITHOUT color management, using a real primaries matrix instead of
//     a generic saturation / vibrance boost. For HDR only (scRGB or HDR10 PQ).
//
// 中文: 复现"未做色彩管理时,sRGB 数值被显示器当成自己的原生 P3 色域直接点亮"
//     的过饱和效果。用真实的原色矩阵,而不是通用的饱和度/自然饱和度拉伸。
//     仅在 HDR(scRGB 或 HDR10 PQ)下生效。
//
// How it works / 原理:
//   Take the linear light of the image as Rec.709/sRGB values, then re-read the
//   same three numbers as Display P3 values (the "bug"). Because this is a
//   fixed linear 3x3 transform, it behaves identically at every brightness
//   (HDR highlights included), the R/G/B channels scale together (no hue
//   shift), and neutral colors (black, grays, white) are left untouched.
//   把画面线性光当作 Rec.709/sRGB 数值,再把同样三个数"误读"为 P3 数值。
//   这是固定的线性 3x3 变换:任何亮度下行为一致(包括 HDR 高光),
//   三个通道联动缩放(不会色相偏移),黑、灰、白保持不变。
//
// Implementation notes / 实现说明:
//   * The whole chain (container -> Rec.709 -> read as P3 -> container) is
//     pre-merged into single 3x3 matrices, all derived from the same D65 white
//     (0.3127, 0.3290). Every matrix row sums to 1, so white stays exactly white.
//     整条链路已预合并成单个 3x3 矩阵,全部基于同一 D65 白点推导,
//     每行之和为 1,因此白色保持精确不变。
//   * Strength blending is done in LINEAR light for both scRGB and PQ, so the
//     slider means the same thing in both modes.
//     强度混合在线性光中进行,scRGB 与 PQ 下滑块含义一致。
//   * No clamping of the input to Rec.709: out-of-gamut (negative) components
//     from wide-gamut content are processed by the same linear transform
//     instead of being hard-clipped. Negative values can only be dropped at
//     the very end when encoding PQ (PQ cannot represent them); scRGB keeps them.
//     不再把输入硬裁切到 Rec.709;超色域内容走同一线性变换。
//     只有在编码 PQ 的最后一步才会丢弃负值(PQ 无法表示),scRGB 则保留。
//
// Notes / 注意:
//   * Assumes the game content is authored for Rec.709/sRGB (true for the vast
//     majority of games). Natively wide-gamut content will look over-saturated.
//     假设游戏内容按 Rec.709/sRGB 制作(绝大多数游戏如此)。
//   * BUFFER_COLOR_SPACE: 2 = scRGB, 3 = HDR10 PQ. HDR10 HLG (4) is not
//     supported and is treated as "off".
//     BUFFER_COLOR_SPACE:2 = scRGB,3 = HDR10 PQ;HLG(4)不支持,视为关闭。
//   * Place this effect at the TOP of your effect list, above other color
//     shaders. / 请把本效果放在效果列表最上方。
//
// License: MIT
// ============================================================================

#include "ReShade.fxh"

#if BUFFER_COLOR_SPACE == 3
    #define AUTO_MODE_ITEM_LABEL "Auto (detected: HDR10 PQ)\0"
#elif BUFFER_COLOR_SPACE == 2
    #define AUTO_MODE_ITEM_LABEL "Auto (detected: scRGB)\0"
#else
    #define AUTO_MODE_ITEM_LABEL "Auto (detected: SDR / effect off)\0"
#endif

uniform int ColorSpaceMode <
    ui_type = "combo";
    ui_label = "Color Space Mode / 色彩空间判断方式";
    ui_items = AUTO_MODE_ITEM_LABEL "Force HDR10 PQ\0Force scRGB\0Force Off\0";
    ui_tooltip = "'Auto' relies on ReShade's BUFFER_COLOR_SPACE reported at compile time. If you toggle HDR on/off in-game and the effect stops responding to sliders, ReShade likely failed to refresh its color space detection. Manually switch this to 'Force HDR10 PQ' or 'Force scRGB' to fix it -- this takes effect instantly, no restart needed.\n\nWarning: forcing the wrong mode will make the image look broken. Switch back to Auto or pick the correct mode to recover.";
    ui_category = "Settings";
> = 0;

uniform float EffectStrength <
    ui_type = "slider";
    ui_label = "Effect Strength (%) / 效果强度";
    ui_tooltip = "0 = untouched/correct color, 100 = full effect. Blended in linear light, identical behavior in scRGB and HDR10 PQ.";
    ui_min = 0.0; ui_max = 100.0; ui_step = 1.0;
    ui_category = "Settings";
> = 100.0;

// ---------------------------------------------------------------------------
// Pre-merged primaries matrices (D65 white x=0.3127, y=0.3290).
// Row-major; used as mul(M, v). Every row sums to 1 (white is preserved).
// 预合并的原色矩阵(D65 白点),行主序,mul(M, v);每行之和为 1。
// ---------------------------------------------------------------------------

// HDR10 container (BT.2020 linear) -> Rec.709 linear
static const float3x3 BT2020_to_Rec709 = float3x3(
     1.6604910, -0.5876411, -0.0728499,
    -0.1245505,  1.1328999, -0.0083494,
    -0.0181508, -0.1005789,  1.1187297
);

// "The bug" for scRGB: Rec.709 values re-read as P3, expressed in Rec.709.
// Blue column is zero because sRGB and P3 share the same blue primary.
// scRGB 下的"误读":Rec.709 数值按 P3 解读,再表示回 Rec.709。
// sRGB 与 P3 蓝原色相同,所以最后一列前两项为 0。
static const float3x3 P3D65_to_Rec709 = float3x3(
     1.2249402, -0.2249402,  0.0000000,
    -0.0420570,  1.0420570,  0.0000000,
    -0.0196376, -0.0786360,  1.0982736
);

// "The bug" for HDR10: P3 primaries expressed in BT.2020 container.
// HDR10 下的"误读":P3 原色表示回 BT.2020 容器。
static const float3x3 P3D65_to_BT2020 = float3x3(
     0.7538330,  0.1985974,  0.0475696,
     0.0457438,  0.9417772,  0.0124789,
    -0.0012103,  0.0176017,  0.9836086
);

// ---------------------------------------------------------------------------
// ST.2084 (PQ) transfer functions
// ---------------------------------------------------------------------------

static const float PQ_m1 = 0.1593017578125;
static const float PQ_m2 = 78.84375;
static const float PQ_c1 = 0.8359375;
static const float PQ_c2 = 18.8515625;
static const float PQ_c3 = 18.6875;

// Encoded [0,1] -> linear light (normalized, 1.0 = 10000 nits)
float3 PQ_EOTF(float3 E)
{
    float3 Ep  = pow(max(E, 0.0), 1.0 / PQ_m2);
    float3 num = max(Ep - PQ_c1, 0.0);
    float3 den = PQ_c2 - PQ_c3 * Ep;
    return pow(num / max(den, 1e-6), 1.0 / PQ_m1);
}

// Linear light (normalized, 1.0 = 10000 nits) -> encoded [0,1]
float3 PQ_OETF(float3 L)
{
    float3 Lm  = pow(max(L, 0.0), PQ_m1);
    float3 num = PQ_c1 + PQ_c2 * Lm;
    float3 den = 1.0 + PQ_c3 * Lm;
    return pow(num / den, PQ_m2);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

float3 PS_SimulateSRGBAsP3(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 col = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // mode 0 = Auto (compile-time BUFFER_COLOR_SPACE as initial guess)
    // mode 1 = Force HDR10 PQ, 2 = Force scRGB, 3 = Force Off
    int mode = ColorSpaceMode;
    if (mode == 0)
    {
        #if BUFFER_COLOR_SPACE == 3
            mode = 1;
        #elif BUFFER_COLOR_SPACE == 2
            mode = 2;
        #else
            mode = 3;
        #endif
    }

    float t = saturate(EffectStrength / 100.0);
    if (mode == 3 || t <= 0.0) return col;

    bool isPQ = (mode == 1);

    // Linear light in the container's own primaries.
    // scRGB: already linear Rec.709. PQ: linear BT.2020.
    // (Matrices are linear, so the absolute nit scale does not matter.)
    float3 linearIn = isPQ ? PQ_EOTF(col) : col;

    // Bring to Rec.709 linear (identity for scRGB), then apply "the bug".
    float3 rec709Lin = isPQ ? mul(BT2020_to_Rec709, linearIn) : linearIn;
    float3 linearOut = isPQ ? mul(P3D65_to_BT2020, rec709Lin)
                            : mul(P3D65_to_Rec709, rec709Lin);

    // Blend in linear light (same meaning of the slider in both modes).
    float3 blended = lerp(linearIn, linearOut, t);

    // PQ cannot encode negative values; scRGB can, so keep them there.
    return isPQ ? PQ_OETF(max(blended, 0.0)) : blended;
}

technique SimulateSRGBAsP3
<
    ui_tooltip = "Deliberately recreates the look of sRGB values being misread as native P3 by the display, using a real primaries matrix transform instead of a generic saturation algorithm.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_SimulateSRGBAsP3;
    }
}
