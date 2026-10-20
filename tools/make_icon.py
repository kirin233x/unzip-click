#!/usr/bin/env python3
"""生成 Resources/AppIcon.icns（纯 Python + Pillow，不依赖 macOS 工具）。
用法：python3 tools/make_icon.py
"""
import io
import struct
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # 2x 超采样，最后缩到 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def master():
    k = S / 1024
    body = [int(100 * k), int(100 * k), int(924 * k), int(924 * k)]

    # 圆角方块 + 上下渐变
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius=int(190 * k), fill=255)
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    top, bottom = (96, 165, 250), (37, 70, 200)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # 柔和投影
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        [body[0], body[1] + int(14 * k), body[2], body[3] + int(14 * k)], radius=int(190 * k), fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(16 * k)))
    img.paste((0, 0, 40, 255), (0, 0), shadow)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    cx = S // 2
    white = (255, 255, 255, 255)
    soft = (255, 255, 255, 235)

    # 拉链：滑块以上咬合（左右交错），滑块以下张开（左右并排）
    tw, th, gap = int(58 * k), int(34 * k), int(16 * k)
    step = th + gap
    top_y, slider_top, slider_h, bottom_y = int(190 * k), int(450 * k), int(190 * k), int(850 * k)
    r = int(9 * k)

    y, left = top_y, True
    while y + th <= slider_top - int(10 * k):
        x = cx - tw if left else cx
        d.rounded_rectangle([x, y, x + tw, y + th], radius=r, fill=soft)
        left = not left
        y += step

    out = int(26 * k)
    y = slider_top + slider_h + int(14 * k)
    while y + th <= bottom_y:
        d.rounded_rectangle([cx - tw - out, y, cx - out, y + th], radius=r, fill=soft)
        d.rounded_rectangle([cx + out, y, cx + out + tw, y + th], radius=r, fill=soft)
        y += step

    # 滑块：上窄下宽的白色拉头，中间留孔
    sw = int(170 * k)
    d.rounded_rectangle([cx - sw // 2, slider_top, cx + sw // 2, slider_top + slider_h], radius=int(46 * k), fill=white)
    hole = int(46 * k)
    d.rounded_rectangle([cx - hole, slider_top + int(48 * k), cx + hole, slider_top + slider_h - int(48 * k)],
                        radius=int(22 * k), fill=(52, 104, 228, 255))
    return img.resize((1024, 1024), Image.LANCZOS)


def build_icns(path):
    base = master()
    base.save("/tmp/appicon_preview.png")
    chunks = []
    # ICNS 内嵌 PNG：类型 -> 像素边长
    for tag, px in [(b"icp4", 16), (b"icp5", 32), (b"ic07", 128), (b"ic08", 256), (b"ic09", 512),
                    (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512)]:
        buf = io.BytesIO()
        base.resize((px, px), Image.LANCZOS).save(buf, "PNG")
        data = buf.getvalue()
        chunks.append(tag + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    build_icns("Resources/AppIcon.icns")
    print("wrote Resources/AppIcon.icns")
