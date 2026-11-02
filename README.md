# HX4S20 TF 卡 BMP 图片显示

基于安路 EG4S20BG256（HX4S20/EG4S20 底板）的纯 FPGA 图片显示工程。
系统从 FAT32 TF 卡读取 BMP 图片，将其解码到 SDRAM 帧缓存，再通过
640×480 HDMI 和 VGA 同步输出。HDMI 链路同时输出一段循环播放的提示音。

## 功能概览

- 上电后自动从 TF 卡根目录加载第 1 张 BMP 图片。
- 支持 24 位、32 位未压缩 BMP，最大 640×480。
- 图片不缩放；小于 640×480 时居中显示，四周自动补黑。
- 4×4 矩阵键盘可切换前四张图片、上一张、下一张和重新加载。
- HDMI 输出 640×480、约 60 Hz、24 位 RGB，并带 48 kHz HDMI 音频。
- VGA 输出使用相同视频时序，颜色为 RGB 5:6:5。
- LED 指示初始化、图片加载成功或读取错误。

## 数据通路

```text
TF 卡 (FAT32)
    │
    └─ SPI 6.25 MHz
         └─ 512 字节扇区缓存
              └─ MBR / FAT32 BPB / 根目录 / FAT 链解析
                   └─ 24/32 位 BMP 解码
                        └─ SDRAM 640×480 帧缓存
                             └─ 双行缓存
                                  ├─ VGA RGB 5:6:5
                                  └─ HDMI 1.4b / 48 kHz 音频
```

工程是纯 RTL 实现，不依赖 CPU 或软件图片处理。显示前会清除 SDRAM
帧缓存；图片重新加载期间，视频输出可能短暂黑屏。

## 快速开始

### 1. 获取源码

```powershell
git clone https://github.com/Dai-61/FRAME_HDMI_AUDIO.git
cd FRAME_HDMI_AUDIO
```

### 2. 准备 TF 卡和图片

将 TF 卡格式化为 **FAT32**，在根目录放入最多四张符合要求的 BMP。推荐的
文件名是 `IMAGE0.BMP`～`IMAGE3.BMP`。

转换普通图片：

```powershell
.\tools\prepare_image.ps1 `
    -InputImage .\photo.jpg `
    -Destination E:\ `
    -Index 0
```

脚本会生成 `E:\IMAGE0.BMP`，按比例缩放到 640×480 以内、居中并用黑色填充
空白区域。对另外三张图片分别使用 `-Index 1`、`2`、`3`。

如果 PowerShell 阻止执行脚本，可使用：

```powershell
powershell -ExecutionPolicy Bypass -File `
    .\tools\prepare_image.ps1 `
    -InputImage .\photo.jpg `
    -Destination E:\ `
    -Index 0
```

完成后安全弹出 TF 卡，再插入板卡。

### 3. 编译工程

1. 使用 **Anlogic TD 6.2.168116** 打开
   [project_frame_hdmi_v2.al](project_frame_hdmi_v2.al)。
2. 确认目标器件为 `EG4S20BG256`，顶层模块为 `top_frame`。
3. 依次执行综合、布局布线和生成码流。
4. 使用 TD 的下载工具烧录生成的 `.bit` 文件。

本地构建生成的码流通常位于：

```text
project_frame_hdmi_v2_Runs/phy_1/project_frame_hdmi_v2.bit
```

`project_frame_hdmi_v2_Runs/`、日志和 `*.bit` 已被 `.gitignore` 排除，
仓库中不包含预编译码流。工程依赖仓库内已包含的厂商加密 IP，必须使用
支持 EG4S20 的 Anlogic TD 构建。

## TF 卡与图片要求

### 文件系统

- 只支持 **FAT32**，不支持 exFAT、NTFS，也不支持无 MBR 的裸分区。
- 使用 MBR 分区表中的第一个分区。
- 只扫描根目录，不扫描子目录。
- 只识别 FAT 8.3 短文件名，不支持长文件名和长文件名目录项。
- 支持经过 FAT 链连接的碎片文件。

### 图片选择规则

硬件只检查 8.3 文件名的扩展名是否为 `.BMP`，不要求基本名必须为
`IMAGE`。例如 `1.BMP`、`A.BMP`、`IMAGE0.BMP` 都可以识别。

图片按根目录条目中实际出现的顺序选取，不是按文件名自动排序：

- 第 1 个匹配项由键码 `0` 选择，并作为上电默认图片。
- 第 2～4 个匹配项分别由键码 `1`～`3` 选择。
- 第五个及之后的 BMP 不会加入按键列表。

为了获得稳定、可预测的顺序，建议只放四张名称连续的图片：

```text
IMAGE0.BMP
IMAGE1.BMP
IMAGE2.BMP
IMAGE3.BMP
```

### BMP 格式

- 24 位或 32 位、未压缩 BMP。
- 宽、高必须大于 0；宽不超过 640，高不超过 480。
- 支持自底向上和自顶向下存储。
- 32 位 BMP 的 Alpha 通道会被忽略。
- 不支持调色板/索引色、RLE 压缩、JPEG、PNG 或其他图片格式。
- 硬件不做缩放；需要其他尺寸时请先使用 `prepare_image.ps1` 转换。

## 操作说明

4×4 矩阵键盘的键码按下式计算：

```text
key_code = row * 4 + col
```

通常第一排从左到右为 `0`～`3`，第二排为 `4`～`7`，第三排为 `8`～`11`，
第四排为 `12`～`15`。

| 键码 | 功能 |
|---|---|
| `0`～`3` | 加载根目录中第 1～4 张 BMP |
| `13` | 上一张；从第 1 张循环到第 4 张 |
| `14` | 下一张；从第 4 张循环到第 1 张 |
| `15` | 重新读取当前图片 |
| 其他键 | 无动作 |

按键在每次按下时触发一次，长按不会连续切换。初始化、读取或解码期间
视频会清屏；加载完成后自动重新开始显示。

## LED 状态

| LED 状态 | 含义 |
|---|---|
| 约 0.67 秒周期的慢闪 | 系统初始化或图片正在加载 |
| 约 0.34 秒周期的快闪 | TF 卡、FAT32 或 BMP 读取失败 |
| 常亮 | 图片加载成功 |

读取失败后屏幕为黑色。可以修正 TF 卡内容，然后按键码 `15` 重试，或复位
板卡重新初始化。

## 主要板级接口

完整约束以 [constraints/frame_hdmi.adc](constraints/frame_hdmi.adc) 为准。

| 功能 | 信号 | FPGA 引脚 |
|---|---|---|
| 50 MHz 输入时钟 | `clk` | R7 |
| 低有效复位 | `rst_n` | A9 |
| 状态 LED | `led` | B15 |
| HDMI 时钟 | `hdmi_clk_p` | P1 |
| HDMI Data0 | `hdmi_d0_p` | N1 |
| HDMI Data1 | `hdmi_d1_p` | P4 |
| HDMI Data2 | `hdmi_d2_p` | J3 |
| VGA 行同步 | `vga_hs` | M14 |
| VGA 场同步 | `vga_vs` | P14 |
| TF SPI CS | `sd_ncs` | F13 |
| TF SPI MOSI | `sd_mosi` | F14 |
| TF SPI CLK | `sd_dclk` | F15 |
| TF SPI MISO | `sd_miso` | D14 |

TF 卡使用 Micro SD 插槽的 SPI 模式：

- `SD_D3` 用作 `SPI_CS`
- `SD_CMD` 用作 `SPI_MOSI`
- `SD_CLK` 用作 `SPI_SCK`
- `SD_D0` 用作 `SPI_MISO`
- `SD_D1` 和 `SD_D2` 不使用

矩阵键盘引脚：

| 信号 | 引脚 |
|---|---|
| `key_row[0]`～`key_row[3]` | E10、C10、F9、D9 |
| `key_col[0]`～`key_col[3]` | E11、D11、C11、F10 |

VGA 色深为 RGB 5:6:5；HDMI 使用完整 24 位 RGB。SDRAM、HDMI、VGA 和
键盘的具体引脚定义与原有 HX4S20 工程保持一致。

## 工程结构

```text
.
├─ project_frame_hdmi_v2.al       Anlogic TD 工程
├─ top_frame.v                    顶层、SDRAM/显示/HDMI 连接
├─ constraints/
│  └─ frame_hdmi.adc              引脚与电平约束
├─ rtl/
│  ├─ image_loader.v              FAT32 根目录、FAT 链和 BMP 解码
│  ├─ sd_sector_reader.v          512 字节扇区缓存
│  ├─ spi_master.v                SPI 字节传输
│  ├─ sd_card_top.v               SD 卡初始化与扇区读取
│  ├─ pll_hdmi.v                  125 MHz、25 MHz 和 180° 时钟
│  ├─ hdmi_audio_tone_pcm_scale.v 48 kHz 提示音生成
│  ├─ audio_arc_calculate.v       HDMI 音频 ACR 计算
│  └─ *.enc.*                     厂商加密 IP
└─ tools/
   └─ prepare_image.ps1           普通图片转 24 位 BMP
```

## 实现说明

- `pll_hdmi` 从 50 MHz 输入产生 125 MHz SDRAM 时钟、25 MHz 像素时钟和
  180° 相移时钟。
- `image_loader` 读取 MBR 第一分区、FAT32 BPB、根目录和 FAT 链，并按
  BMP 头信息将像素写入 SDRAM。
- 每个 640 像素显示行由 `line_loader` 从 SDRAM 预取到双行缓存，当前行
  显示时并行加载下一行。
- HDMI 使用 800×525 总时序、640×480 有效区域和 25 MHz 像素时钟，输出
  TMDS Data0/1/2 与时钟。
- 音频每声道为 48 kHz、24 位 PCM，依次循环播放
  `C4 D4 E4 F4 G4 A4 B4 C5`，每个音符约 0.5 秒，左右声道内容相同。
- SD 卡 SPI 低速初始化分频为 248，读取阶段分频为 8，对应约 6.25 MHz。
- 图片加载、FAT 扇区和 SDRAM 访问均采用轮询状态机，不依赖软核。

## 内部错误码

`image_loader` 会给出如下 `error_code`。该信号未直接连接到板卡显示，
主要用于仿真、逻辑分析仪或增加调试输出时定位问题。

| 错误码 | 含义 |
|---|---|
| `1` | SD 卡或 SDRAM 初始化超时 |
| `2` | MBR 扇区读取超时 |
| `3` | FAT32 BPB 扇区读取超时 |
| `4` | BPB 无效、不是 FAT32 或关键参数错误 |
| `5` | 根目录扇区读取超时 |
| `6` | 根目录中没有足够的 BMP |
| `7` | FAT 表扇区读取超时 |
| `8` | FAT 链无效或提前结束 |
| `9` | 图片数据扇区读取超时 |
| `10` | BMP 头、尺寸、位深或压缩格式不支持 |
| `11` | 图片文件在解码完成前结束 |

## 常见问题

### 上电后 LED 快闪、屏幕黑屏

依次检查：

1. TF 卡是否为 FAT32，且使用 MBR 分区表。
2. 图片是否直接位于根目录，名称是否符合 8.3 格式。
3. 扩展名是否为 `.BMP`，文件是否为 24/32 位未压缩 BMP。
4. 图片尺寸是否不超过 640×480。
5. 根目录中是否至少有一张可识别的 BMP。

### 图片顺序与预期不一致

文件在浏览器中显示的顺序可能来自文件名排序，而硬件按根目录条目顺序
扫描。只保留 `IMAGE0.BMP`～`IMAGE3.BMP` 四张图片可以避免歧义。

### HDMI 无显示，但 VGA 正常

检查 HDMI 线、显示器输入源以及 640×480 信号兼容性。VGA 与 HDMI 使用
同一组视频时序，可以用 VGA 输出帮助区分视频时序问题和 HDMI PHY 问题。

### 图片颜色异常

先用 `prepare_image.ps1` 重新生成 24 位 BMP。索引色、16 位色、RLE 压缩
或带有特殊头的 BMP 可能无法正确显示。

### HDMI 没有声音

确认显示器或采集设备支持 HDMI 音频，并检查其音量和静音状态。当前工程
固定循环播放提示音，不受按键控制。
