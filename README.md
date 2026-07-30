# ReShade-HDR-Simulate-Oversaturation

A ReShade shader that recreates the classic "narrow-gamut content displayed without color management on a wide-gamut screen" look — the oversaturated, punchy colors many people remember from SDR displays before proper color management was common.

一个 ReShade shader,用来复现经典的"窄色域内容在没做色彩管理的情况下被宽色域屏幕直接显示"效果——也就是很多人记忆里 SDR 时代那种没做好色彩管理时特有的、浓郁过饱和的色彩观感。

Unlike generic saturation/vibrance shaders, this doesn't push saturation via HSV/HSL math. Instead, it reproduces the actual mechanism behind the look: it takes the color values your HDR pipeline is correctly displaying, decodes them back to what the original sRGB-referred code value would have been, then re-encodes that same code value using the **wrong** (wider) set of primaries — exactly what happens when a display receives an sRGB signal and interprets it as native wide-gamut RGB without conversion. Because this is a real primaries matrix transform, red/green/blue channels scale together, so colors like yellow get richer without the hue-shifting artifacts you get from naive per-channel saturation boosts.

和通用的饱和度/自然饱和度 shader 不一样,这个不是靠 HSV/HSL 数学去拉饱和度,而是复现了这个效果背后真实的物理机制:把你 HDR 管线里正确显示的颜色,解码还原回游戏原本想输出的 sRGB 编码值,再用**错误的**(更宽的)原色重新编码这组数值——这正是显示器收到 sRGB 信号、却没做转换直接当成自己原生宽色域 RGB 去解读时发生的事情。因为这是真实的原色矩阵变换,红绿蓝三个通道是联动缩放的,所以像黄色这种颜色会变得更浓郁,而不会像普通的单通道饱和度拉伸那样在高饱和区域出现色相跑偏。

Only runs when the ReShade backbuffer is in an HDR color space (scRGB or HDR10 PQ); does nothing in SDR.

只在 ReShade 后台缓冲区处于 HDR 色彩空间(scRGB 或 HDR10 PQ)时生效;SDR 下不做任何处理。

## How it works / 原理

1. Decode the current pixel from your HDR backbuffer (scRGB linear or HDR10 PQ) back into absolute nits, then into XYZ.
   把当前像素从 HDR 后台缓冲区(scRGB 线性或 HDR10 PQ)解码回绝对尼特值,再转换到 XYZ。
2. Convert that XYZ into Rec.709/sRGB-referred linear light using your **Paper White** value as the reference point, then encode it with the sRGB transfer function — this recovers the 0–1 code value the game originally intended to output.
   用**纸白亮度**作为参考点,把这个 XYZ 转换成 Rec.709/sRGB 参考下的线性光,再用 sRGB 传递函数编码——这样就还原出了游戏原本想输出的 0~1 编码值。
3. Re-decode that same code value, but through the Display P3 primaries instead of sRGB — this is the "bug": the signal gets mixed using the wrong (wider) primaries.
   用 Display P3 的原色而不是 sRGB 去重新解码这组编码值——这就是那个"bug":信号被按错误的(更宽的)原色去混色了。
4. Convert back to your display's actual output format so it displays correctly.
   转换回你显示器实际需要的输出格式,正确上屏。

## Parameters / 参数说明

| Parameter / 参数 | Description / 说明 |
|---|---|
| **色彩空间判断方式 / Color Space Mode** | `自动 (Auto)` uses ReShade's detected color space at compile time. If you toggle HDR on/off in-game and the effect stops responding to sliders, ReShade likely failed to refresh its color space detection — switch this to `强制 HDR10 PQ` or `强制 scRGB` manually (no restart needed, takes effect instantly like any other slider) to fix it. `强制关闭` disables the effect entirely.<br>`自动`默认用 ReShade 编译时检测到的色彩空间。如果游戏内切换 HDR 开关后效果不再响应滑条,大概率是 ReShade 没能正确刷新色彩空间检测——手动切换成`强制 HDR10 PQ`或`强制 scRGB`即可修正(不需要重启,和其他滑条一样实时生效)。`强制关闭`则完全禁用效果。 |
| **SDR 参考白 / Paper White (nits)** | The nits value your system currently uses for SDR reference white — **not** your display's peak brightness. This anchors the recovery of the original sRGB code value in step 2 above; getting it wrong will systematically skew the result.<br>Rough estimate: nits ≈ 80 + 4 × (Windows "SDR content brightness" slider %). For the exact value, use [`set_sdrwhite`](https://github.com/ledoge/set_maxtml) (run with no arguments to list your monitors and their current SDR white level in nits).<br>你系统当前用于 SDR 参考白的尼特值——**不是**显示器峰值亮度。这个值是上面第 2 步还原原始编码值的基准,填错会让结果系统性跑偏。<br>粗略估算:尼特 ≈ 80 + 4 × (Windows "SDR 内容亮度" 滑块百分比)。想要精确值可以用 [`set_sdrwhite`](https://github.com/ledoge/set_maxtml)(不带参数直接运行,会列出你的显示器和当前 SDR 白色亮度的精确尼特值)。 |
| **效果强度 / Effect Strength (%)** | 0 = untouched/correct color, 100 = full effect. Blend to taste.<br>0 = 正常/正确颜色,100 = 完全体验效果,可在中间取值做混合强度调节。 |

## Installation / 安装

1. Drop `SimulateSRGBAsP3.fx` into your ReShade shaders folder (same place as your other `.fx` files).
   把 `SimulateSRGBAsP3.fx` 放进你的 ReShade shaders 文件夹(和你其他 `.fx` 文件同一个位置)。
2. Enable HDR in-game and in Windows.
   在游戏内和 Windows 里都打开 HDR。
3. In the ReShade overlay, enable `SimulateSRGBAsP3` and set Paper White to your actual value (see above).
   在 ReShade 悬浮菜单里勾选 `SimulateSRGBAsP3`,把纸白亮度填成你的实际值(见上表)。

If you're also using other saturation/color-grading shaders, put this one **above** them in the effect list (ReShade processes top to bottom) so it operates on the color before other adjustments are layered on.

如果你还在用别的饱和度/调色类 shader,把这个放在效果列表里它们**上面**(ReShade 是从上到下依次处理),让它先处理颜色,再叠加其他调整。

## Limitations / 局限

- Assumes the underlying game content is authored for Rec.709/sRGB gamut, which covers the vast majority of games. Native wide-gamut rendering will not be handled correctly.
  假设游戏内容本身是按 Rec.709/sRGB 色域制作的,覆盖了绝大多数游戏。原生宽色域渲染的游戏不会被正确处理。
- Paper White must be set correctly for the math to hold; see the parameter table above for how to find it.
  纸白亮度必须填对,整套计算才成立,获取方法见上面参数表。
- `色彩空间判断方式` auto-detection depends on ReShade correctly reporting `BUFFER_COLOR_SPACE` at compile time. This is known to sometimes go stale after toggling HDR off/on within the same game session — use the manual override if that happens.
  `色彩空间判断方式`的自动检测依赖 ReShade 在编译时正确汇报 `BUFFER_COLOR_SPACE`。已知在同一局游戏里反复切换 HDR 开关后,这个值有时会刷新不及时——遇到这种情况用手动覆盖选项即可。

## License / 许可协议

MIT
