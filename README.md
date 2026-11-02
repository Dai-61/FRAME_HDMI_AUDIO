# HX4S20 HDMI BMP 图片显示

本工程在原有 640×480 HDMI/VGA + 音频链路基础上增加了 TF 卡图片读取：

```text
TF 卡 (FAT32) -> SPI 扇区读取 -> FAT32 根目录/FAT 链
              -> 24/32 位未压缩 BMP 解码
              -> SDRAM 640×480 帧缓存
              -> HDMI / VGA 显示
```

## TF 卡准备

1. 卡必须格式化为 **FAT32**，不能是 exFAT/NTFS。
2. 图片放在卡的根目录，不放在子目录。
3. 图片使用 8.3 短文件名，扩展名必须是 `.BMP`；根目录按扫描顺序
   识别前四张，例如 `1.BMP`～`4.BMP` 或 `IMAGE0.BMP`～`IMAGE3.BMP`。
4. 图片必须是 24 位或 32 位、未压缩 BMP，最大 640×480。
5. 比 640×480 小的图片会居中显示，四周自动填黑；大图会被拒绝。
6. BMP 可以自底向上或自顶向下存储。

可用下面的脚本把任意常见图片转换成可直接放入卡内的图片：

```powershell
.\tools\prepare_image.ps1 -InputImage .\photo.jpg -Destination E:\ -Index 0
```

脚本会生成 `E:\IMAGE0.BMP`，保持宽高比缩放到 640×480 以内并居中填黑。

## 按键

| 4×4 键盘键码 | 功能 |
|---|---|
| 0、1、2、3 | 读取根目录扫描到的第 1～4 张 BMP |
| 13 | 上一张 |
| 14 | 下一张 |
| 15 | 重新读取当前图片 |

键码定义沿用原工程的矩阵键盘：第一排从左到右通常为 0～3，第二排为
4～7，第三排为 8～11，第四排为 12～15。

## LED 状态

- 慢闪：正在加载图片。
- 快闪：SD/FAT/BMP 读取或格式错误。
- 常亮：图片加载成功。

加载失败时屏幕会显示黑屏；可用键码 15 重试。常见原因包括卡不是 FAT32、
文件名不正确、图片不是未压缩 BMP，或者图片超过 640×480。

## 引脚

TF 卡使用硬木课堂 `板卡和引脚说明.pdf` 与 `EG4S20_综合底板.pdf`
中 Micro SD 插槽的 FPGA 引脚：

| 信号 | FPGA 引脚 |
|---|---|
| `sd_ncs` (`SD_D3/SPI_CS`) | F13 |
| `sd_mosi` (`SD_CMD/SPI_MOSI`) | F14 |
| `sd_dclk` (`SD_CLK/SPI_SCK`) | F15 |
| `sd_miso` (`SD_D0/SPI_MISO`) | D14 |

SD_D1/D16 与 SD_D2/G14 在 SPI 模式下不使用。LED 使用板卡资料中的
LED1/B15。HDMI、VGA、SDRAM、音频和矩阵键盘引脚保持原工程定义。

## 工程与码流

TD 工程：

```text
E:\HX4S20_example2\WORK\WORK\10_FRAME_HDMI_AUDIO\project_frame_hdmi_v2.al
```

布局布线成功后的码流：

```text
E:\HX4S20_example2\WORK\WORK\10_FRAME_HDMI_AUDIO\project_frame_hdmi_v2_Runs\phy_1\project_frame_hdmi_v2.bit
```

## 实现说明

- `rtl/spi_master.v`、`rtl/sd_card_cmd.v`、
  `rtl/sd_card_sec_read_write.v`、`rtl/sd_card_top.v` 基于安路官方
  EG4S20 SD-card 例程，SPI 高速模式修正为 6.25 MHz。
- `rtl/sd_sector_reader.v` 缓存一个 512 字节扇区，并带读取超时。
- `rtl/image_loader.v` 解析 MBR、FAT32 BPB、根目录和 FAT 链，再解码 BMP。
- `top_frame.v` 中的原测试图写入器已从显示链路移除。
- 工程不是 Git 仓库，因此没有生成 Git 提交。
