// ============================================================================
// SimulateSRGBAsP3.fx
//
// 目的:复现"未做色彩管理时,游戏输出的 sRGB 数值被显示器当成自己的原生
// (P3)色域直接点亮"这一现象——而不是用通用的 HSV/HSL 饱和度拉伸去近似它。
//
// 原理:
//   1. 从当前 HDR 后台缓冲区(scRGB 或 HDR10 PQ)反推出游戏"本来想输出"的
//      sRGB 编码值(0-1,类似没开 HDR 时你会看到的那串数字)。
//   2. 刻意用错误的方式解读这组数值——不当成 sRGB,而是当成 P3 原生 RGB,
//      按 P3 的原色去混色,得到"面板被错误驱动"后实际发出的颜色。
//   3. 把这个结果转换回你显示器真正需要的输出格式,正确上屏。
//
// 因为整个过程走的是原色矩阵(顶点坐标)变换,红绿蓝三个通道是联动缩放的,
// 不会像通用饱和度算法那样因为单通道提前 clip 而在高饱和区域出现色相跑偏
// (比如黄色偏红)的问题。
//
// 用法:
//   - PaperWhiteNits: 填你 Windows HDR 设置里 "SDR 内容亮度 / paper white"
//     的实际数值(不是显示器峰值,是那个用来定义"什么亮度算作 100% 白"的值)。
//     这个数值决定了第 1 步"反推原始 sRGB 值"是否准确,建议先精确填对。
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
    ui_label = "色彩空间判断方式";
    ui_items = "自动(跟随编译时检测)\0强制 HDR10 PQ\0强制 scRGB\0强制关闭(不处理)\0";
    ui_tooltip = "'自动'依赖 ReShade 编译时告知的 BUFFER_COLOR_SPACE,如果切换 HDR/SDR 后发现效果不再生效(比如滑块没反应),\n不需要重启游戏,直接在这里手动选'强制 HDR10 PQ'或'强制 scRGB'纠正即可——这个下拉框和滑条一样是实时生效的,不需要重新编译。";
    ui_category = "基础设置";
> = 0;

uniform float PaperWhiteNits <
    ui_type = "slider";
    ui_label = "SDR 参考白 / Paper White (nits)";
    ui_tooltip = "填 Windows HDR 设置里 'SDR 内容亮度' 对应的尼特值。\n不知道具体多少的话,可以用经验公式估算:80 + 4 x 滑块百分比(0~100),\n比如滑块 80% 大约对应 400 尼特。想要精确值可以用 set_sdrwhite 工具直接读取。";
    ui_min = 40.0; ui_max = 500.0; ui_step = 1.0;
    ui_category = "基础设置";
> = 400.0;

uniform float EffectStrength <
    ui_type = "slider";
    ui_label = "效果强度 / Bug Strength (%)";
    ui_tooltip = "0 = 正确颜色,100 = 完全模拟 sRGB 数值被当成 P3 原生色域显示的过饱和效果。";
    ui_min = 0.0; ui_max = 100.0; ui_step = 1.0;
    ui_category = "基础设置";
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

// sRGB 传递函数,同时也拿来当作"面板自身 EOTF"的近似(标准做法,P3 面板
// 通常也是接近 sRGB/2.2 这类曲线的响应,不是 P3 色域本身自带什么特殊曲线)
float3 TransferOETF(float3 c)
{
    c = saturate(c);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return (c <= 0.0031308) ? lo : hi;
}

float3 TransferEOTF(float3 c)
{
    c = saturate(c);
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return (c <= 0.04045) ? lo : hi;
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

    // 第一步:还原游戏"本来想输出"的 sRGB 编码值(以 PaperWhite 为参考白)
    float3 rec709Linear = mul(XYZ_to_Rec709, XYZ) / max(PaperWhiteNits, 1.0);
    float3 sdrCodeValue = TransferOETF(max(rec709Linear, 0.0));

    // 第二步(这就是那个"bug"):把这组数值错误地当成 P3 原生 RGB 去解码混色
    float3 p3Linear = TransferEOTF(sdrCodeValue);
    float3 buggyXYZ = mul(P3D65_to_XYZ, p3Linear) * PaperWhiteNits;

    // 第三步:转换回显示器真正需要的输出格式
    float3 outNits = isPQ ? mul(XYZ_to_BT2020, buggyXYZ) : mul(XYZ_to_Rec709, buggyXYZ);
    float3 outCode = isPQ ? PQ_OETF(max(outNits, 0.0) / 10000.0) : (outNits / 80.0);

    return lerp(col, outCode, EffectStrength / 100.0);
}

technique SimulateSRGBAsP3
<
    ui_tooltip = "故意复现'sRGB 数值被面板当成 P3 原生色域显示'的过饱和效果,基于真实原色矩阵变换而非通用饱和度算法。";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_SimulateSRGBAsP3;
    }
}
