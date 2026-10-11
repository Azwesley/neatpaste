"""Regenerate NeatPaste's original icons. Development only: pip install pillow."""

from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
cream = "#F3F1E8"
green = "#246B51"
paper = "#FFFFFF"
draw.rounded_rectangle((64, 64, 960, 960), radius=216, fill=cream)
draw.rounded_rectangle((275, 206, 749, 841), radius=72, fill=green)
draw.rounded_rectangle((316, 252, 708, 800), radius=34, fill=paper)
draw.rounded_rectangle((415, 174, 609, 300), radius=42, fill=green)
draw.rounded_rectangle((473, 211, 551, 245), radius=17, fill=cream)
for y, end in [(392, 621), (477, 621), (562, 550)]:
    draw.rounded_rectangle((389, y, end, y + 31), radius=15, fill=green)
draw.line([(469, 687), (511, 729), (618, 625)], fill=green, width=34)
for x, y in [(469, 687), (511, 729), (618, 625)]:
    draw.ellipse((x - 17, y - 17, x + 17, y + 17), fill=green)

image.save(HERE / "icon.png")
image.save(HERE / "icon.icns")
image.save(HERE / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
for size, name in [(32, "32x32.png"), (128, "128x128.png"), (256, "128x128@2x.png")]:
    image.resize((size, size), Image.Resampling.LANCZOS).save(HERE / name)

# Template icon uses alpha only on macOS; the Windows tray uses the colored icon.
tray = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
draw = ImageDraw.Draw(tray)
draw.rounded_rectangle((24, 20, 104, 117), radius=15, outline="black", width=9)
draw.rounded_rectangle((44, 10, 84, 35), radius=8, fill="black")
for y, end in [(54, 84), (76, 84), (98, 66)]:
    draw.rounded_rectangle((44, y, end, y + 8), radius=4, fill="black")
tray.resize((32, 32), Image.Resampling.LANCZOS).save(HERE / "tray.png")
