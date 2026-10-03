# Builds the Nexus/GitHub graphics from the in-game summary screenshot.
#
#   pip install pillow
#   python tools/make_graphics.py
#
# Input:  nexus/media/summary-chat.webp  (screenshot of the in-game chat summary)
# Output: nexus/media/header.png         1300x372  Nexus header banner
#         nexus/media/gallery-main.png   1920x1080 first gallery image (also the mod card thumbnail)
#         nexus/media/summary-chat.png   the screenshot as PNG (Nexus doesn't accept .webp)
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MEDIA = os.path.join(ROOT, "nexus", "media")
FONTS = r"C:\Windows\Fonts"

CYAN = (127, 223, 255)
AMBER = (255, 190, 70)
WHITE = (245, 248, 252)
MUTED = (178, 192, 212)
NAVY = (9, 16, 30)

# Region of the screenshot holding the chat lines, with a little margin (x0, y0, x1, y1).
CHAT_BOX = (42, 54, 1294, 400)


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def cover(img, size):
    """Scale and centre-crop img to fill size."""
    w, h = size
    scale = max(w / img.width, h / img.height)
    resized = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    x = (resized.width - w) // 2
    y = (resized.height - h) // 2
    return resized.crop((x, y, x + w, y + h))


def backdrop(shot, size, blur=18, darkness=0.62):
    bg = cover(shot, size).filter(ImageFilter.GaussianBlur(blur))
    return Image.blend(bg, Image.new("RGB", size, NAVY), darkness).convert("RGBA")


def left_fade(canvas, left_alpha, right_alpha):
    """Darkens the canvas with navy, strongest on the left, so text there stays readable."""
    w, h = canvas.size
    mask = Image.new("L", (w, 1))
    for x in range(w):
        mask.putpixel((x, 0), round(left_alpha + (right_alpha - left_alpha) * x / (w - 1)))
    layer = Image.new("RGBA", canvas.size, NAVY + (255,))
    layer.putalpha(mask.resize(canvas.size))
    canvas.alpha_composite(layer)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def paste_card(canvas, card, xy, radius=18, shadow=26, border=CYAN):
    """Pastes a rounded card with a soft shadow and a thin glowing border."""
    card = rounded(card, radius)
    x, y = xy
    sh = Image.new("RGBA", (card.width + shadow * 4, card.height + shadow * 4), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        (shadow * 2, shadow * 2, shadow * 2 + card.width, shadow * 2 + card.height), radius, fill=(0, 0, 0, 190))
    sh = sh.filter(ImageFilter.GaussianBlur(shadow))
    canvas.alpha_composite(sh, (x - shadow * 2, y - shadow * 2 + 10))
    glow = Image.new("RGBA", (card.width + 24, card.height + 24), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((12, 12, 12 + card.width, 12 + card.height), radius + 2,
                                           outline=border + (150,), width=4)
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(6)), (x - 12, y - 12))
    canvas.alpha_composite(card, (x, y))
    ImageDraw.Draw(canvas).rounded_rectangle((x, y, x + card.width - 1, y + card.height - 1), radius,
                                             outline=border + (200,), width=2)


def clock_icon(canvas, cx, cy, r, color, width):
    """A clock face: time passing."""
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=color, width=width)
    draw.line((cx, cy, cx, cy - r * 0.58), fill=color, width=width)
    draw.line((cx, cy, cx + r * 0.42, cy + r * 0.12), fill=color, width=width)
    draw.ellipse((cx - width, cy - width, cx + width, cy + width), fill=color)


def text_shadowed(canvas, xy, text, fnt, fill, offset=3, anchor="la"):
    draw = ImageDraw.Draw(canvas)
    x, y = xy
    draw.text((x + offset, y + offset), text, font=fnt, fill=(0, 0, 0, 170), anchor=anchor)
    draw.text((x, y), text, font=fnt, fill=fill, anchor=anchor)


def text_width(text, fnt):
    l, _, r, _ = ImageDraw.Draw(Image.new("RGB", (1, 1))).textbbox((0, 0), text, font=fnt)
    return r - l


def chip(canvas, x, y, text, fnt, pad_x=18, pad_y=9, fill=(255, 255, 255, 30), outline=(127, 223, 255, 140)):
    """A translucent pill with text, drawn on its own layer so the transparency blends."""
    l, t, r, b = ImageDraw.Draw(canvas).textbbox((0, 0), text, font=fnt)
    w, h = r - l + pad_x * 2, b - t + pad_y * 2
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle((x, y, x + w, y + h), h // 2, fill=fill, outline=outline, width=2)
    canvas.alpha_composite(layer)
    ImageDraw.Draw(canvas).text((x + pad_x - l, y + pad_y - t), text, font=fnt, fill=WHITE)
    return x + w


def header(shot, chat):
    size = (1300, 372)
    canvas = backdrop(shot, size)
    left_fade(canvas, 235, 60)

    clock_icon(canvas, 78, 112, 30, AMBER, 6)
    text_shadowed(canvas, (124, 76), "OFFLINE PROGRESS", font("seguibl.ttf", 54), WHITE)
    text_shadowed(canvas, (127, 150), "Your bases keep working while the game is closed.",
                  font("seguisb.ttf", 22), CYAN, offset=2)
    small = font("seguisb.ttf", 17)
    x = chip(canvas, 127, 202, "Palworld 1.0.5", small) + 10
    x = chip(canvas, x, 202, "UE4SS", small) + 10
    chip(canvas, x, 202, "Host-only \u00b7 crossplay friendly", small)
    ImageDraw.Draw(canvas).text((127, 272), "Per-base catch-up \u2022 Private \u201cwhile you were away\u201d summaries",
                                font=font("segoeui.ttf", 17), fill=MUTED)

    card_w = 500
    card = chat.resize((card_w, round(chat.height * card_w / chat.width)), Image.LANCZOS)
    paste_card(canvas, card, (size[0] - card_w - 40, (size[1] - card.height) // 2), radius=14, shadow=18)
    return canvas.convert("RGB")


def gallery(shot, chat):
    size = (1920, 1080)
    canvas = backdrop(shot, size, blur=24, darkness=0.68)

    clock_icon(canvas, 960 - 520, 190, 46, AMBER, 8)
    text_shadowed(canvas, (960 + 40, 190), "OFFLINE PROGRESS", font("seguibl.ttf", 104), WHITE, offset=4, anchor="mm")
    text_shadowed(canvas, (960, 292), "Your bases keep working while the game is closed.",
                  font("seguisb.ttf", 42), CYAN, offset=3, anchor="mm")

    card_w = 1440
    card = chat.resize((card_w, round(chat.height * card_w / chat.width)), Image.LANCZOS)
    card_y = 372
    paste_card(canvas, card, ((size[0] - card_w) // 2, card_y), radius=22, shadow=30)

    chips = ["Learns each base's real production", "Private summary for every player",
             "Only the host needs it \u00b7 works with PS5 crossplay"]
    fnt = font("seguisb.ttf", 30)
    pad = 22
    widths = [text_width(c, fnt) + pad * 2 for c in chips]
    gap = 26
    x = (size[0] - (sum(widths) + gap * (len(chips) - 1))) // 2
    y = card_y + card.height + 64
    for c in chips:
        x = chip(canvas, x, y, c, fnt, pad_x=pad, pad_y=12) + gap
    ImageDraw.Draw(canvas).text((960, y + 112),
                                "Palworld 1.0.5  \u00b7  UE4SS  \u00b7  github.com/imyog1/PalworldOfflineProgress",
                                font=font("segoeui.ttf", 26), fill=MUTED, anchor="mm")
    return canvas.convert("RGB")


def main():
    shot = Image.open(os.path.join(MEDIA, "summary-chat.webp")).convert("RGB")
    chat = shot.crop(CHAT_BOX)
    shot.save(os.path.join(MEDIA, "summary-chat.png"), optimize=True)
    header(shot, chat).save(os.path.join(MEDIA, "header.png"), optimize=True)
    gallery(shot, chat).save(os.path.join(MEDIA, "gallery-main.png"), optimize=True)
    for name in ("header.png", "gallery-main.png", "summary-chat.png"):
        path = os.path.join(MEDIA, name)
        with Image.open(path) as im:
            print(f"{name}: {im.size[0]}x{im.size[1]}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
