// ============================================================================
// SimulateSRGBAsP3.fx
//
// 目的:复现"未做色彩管理时,游戏输出的 sRGB 数值被显示器当成自己的原生
// (P3)色域直接点亮"这一现象——而不是用通用的 HSV/HSL 饱和度拉伸去近似它。
//
// 原理:
//   把当前 HDR 画面的颜色转换到 XYZ,然后不经过正确的 sRGB/Rec.709 矩阵,
//   而是故意用 P3 的原色矩阵重新解读这组数值,得到"面板被错误驱动"后实际
//   发出的颜色,再转换回显示器真正需要的输出格式。
//
// 这是一个固定的线性矩阵变换,对任意亮度(包括超过纸白的 HDR 高光)一视同仁,
// 不需要纸白亮度之类的参考点,也不会在高光区域出现裁切或色相跑偏的问题。
// 因为整个过程走的是原色矩阵变换,红绿蓝三个通道是联动缩放的,不会像通用
// 饱和度算法那样因为单通道提前 clip 而在高饱和区域出现色相跑偏(比如黄色偏红)。
//
// 用法:
//   - EffectStrength: 0 = 正常/正确颜色,100 = 完全体验"bug"效果,可以按
//     喜好在中间取值做混合强度调节。
//
// 注意:
//   - BUFFER_COLOR_SPACE 的具体数值(2=scRGB, 3=HDR10 PQ)是 ReShade 近期
//     版本的通用约定。如果编译报错或者效果方向不对(比如在错误的模式下
//     生效),可以在 ReShade 内置的预处理器定义/统计信息里确认你当前的
//     实际 BUFFER_COLOR_SPACE 数值,然后把下面 #if 里的数字改成对应的值。
//   - 这版假设你的游戏内容本来就是按 Rec.709/sRGB 色域制作的(绝大多数
//     游戏都是),如果是原生宽色域渲染的游戏,效果会不准确。
// ============================================================================

#include "ReShade.fxh"

uniform int ColorSpaceMode <
    ui_type = "combo";
    ui_label = "Color Space Mode / 色彩空间判断方式";
    ui_items = "Auto (compile-time detection)\0Force HDR10 PQ\0Force scRGB\0Force Off\0";
    ui_tooltip = "'Auto' relies on ReShade's BUFFER_COLOR_SPACE reported at compile time. If you toggle HDR on/off in-game and the effect stops responding to sliders, ReShade likely failed to refresh its color space detection. Manually switch this to 'Force HDR10 PQ' or 'Force scRGB' to fix it -- this takes effect instantly like any other slider, no restart needed.";
    ui_category = "Settings";
> = 0;

uniform float EffectStrength <
    ui_type = "slider";
    ui_label = "Effect Strength (%) / 效果强度";
    ui_tooltip = "0 = untouched/correct color, 100 = full effect. Blend to taste.";
    ui_min = 0.0; ui_max = 100.0; ui_step = 1.0;
    ui_category = "Settings";
> = 100.0;

// ---------------------------------------------------------------------------
// 标准原色矩阵 (D65 白点,行主序,M * vec = 结果)
// ---------------------------------------------------------------------------

static const float3x3 Rec709_to_XYZ = float3x3(
    0.4124564, 0.3575761, 0.1804375,
    0.2126729, 0.7151522, 0.0721750,
    0.0193339, 0.1191920, 0.9503041
);

static const float3x3 XYZ_to_Rec709 = float3x3(
     3.2404542, -1.5371385, -0.4985314,
    -0.9692660,  1.8760108,  0.0415560,
     0.0556434, -0.2040259,  1.0572252
);

static const float3x3 P3D65_to_XYZ = float3x3(
    0.4865709, 0.2656677, 0.1982173,
    0.2289746, 0.6917385, 0.0792869,
    0.0000000, 0.0451134, 1.0439444
);

static const float3x3 XYZ_to_BT2020 = float3x3(
     1.7166512, -0.3556708, -0.2533663,
    -0.6666844,  1.6164812,  0.0157685,
     0.0176399, -0.0427706,  0.9421031
);

static const float3x3 BT2020_to_XYZ = float3x3(
    0.6369580, 0.1446169, 0.1688810,
    0.2627002, 0.6779981, 0.0593017,
    0.0000000, 0.0280727, 1.0609851
);

// ---------------------------------------------------------------------------
// ST.2084 (PQ) 编解码
// ---------------------------------------------------------------------------

static const float PQ_m1 = 0.1593017578125;
static const float PQ_m2 = 78.84375;
static const float PQ_c1 = 0.8359375;
static const float PQ_c2 = 18.8515625;
static const float PQ_c3 = 18.6875;

float3 PQ_EOTF(float3 E) // 编码值[0,1] -> 线性亮度(相对 10000 nit 归一化)
{
    float3 Ep  = pow(max(E, 0.0), 1.0 / PQ_m2);
    float3 num = max(Ep - PQ_c1, 0.0);
    float3 den = PQ_c2 - PQ_c3 * Ep;
    return pow(num / max(den, 1e-6), 1.0 / PQ_m1);
}

float3 PQ_OETF(float3 L) // 线性亮度(相对 10000 nit 归一化) -> 编码值[0,1]
{
    float3 Lm  = pow(max(L, 0.0), PQ_m1);
    float3 num = PQ_c1 + PQ_c2 * Lm;
    float3 den = 1.0 + PQ_c3 * Lm;
    return pow(num / den, PQ_m2);
}

// ---------------------------------------------------------------------------
// 主逻辑
// ---------------------------------------------------------------------------

float3 PS_SimulateSRGBAsP3(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 col = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // 决定本次实际使用哪种格式处理:
    // mode 0 = 自动(用编译时的 BUFFER_COLOR_SPACE 作初始猜测,仅在切换 HDR 后
    //           ReShade 没能正确重新编译时才可能不准,此时手动选下面两项之一即可)
    // mode 1 = 强制 HDR10 PQ   mode 2 = 强制 scRGB   mode 3 = 强制关闭
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

    if (mode == 3) return col;

    bool isPQ = (mode == 1);

    // ---- 以下是运行时分支,不依赖重新编译,HDR/SDR 切换后立刻按当前 mode 生效 ----

    float3 linearNits = isPQ ? (PQ_EOTF(col) * 10000.0) : (col * 80.0);
    float3 XYZ = isPQ ? mul(BT2020_to_XYZ, linearNits) : mul(Rec709_to_XYZ, linearNits);

    // 这就是那个"bug":不用正确的 Rec.709 矩阵转回去,而是先转到 Rec.709
    // 线性光,再故意用 P3 的原色矩阵重新混色——对任意亮度一视同仁,不设上限。
    float3 rec709Linear = mul(XYZ_to_Rec709, XYZ);
    float3 buggyXYZ = mul(P3D65_to_XYZ, max(rec709Linear, 0.0));

    // 转换回显示器真正需要的输出格式
    float3 outNits = isPQ ? mul(XYZ_to_BT2020, buggyXYZ) : mul(XYZ_to_Rec709, buggyXYZ);
    float3 outCode = isPQ ? PQ_OETF(max(outNits, 0.0) / 10000.0) : (outNits / 80.0);

    return lerp(col, outCode, EffectStrength / 100.0);
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
