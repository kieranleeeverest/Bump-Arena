from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

out_dir = Path(r"E:\杂项\怼球复刻\diagnostics\ui_design_v2_2026-11-22")
names = [
    "01_normal_blue", "02_normal_red", "03_aiming", "04_special_spawn",
    "05_black_hole", "06_pause", "07_settings", "08_result",
    "09_social_home", "10_chat_open", "11_keyboard_open", "12_image_select",
    "13_emoji_picker", "14_reaction_sent", "15_shared_music", "16_leave_confirm",
    "17_music_select", "18_image_failed", "19_waiting_room",
]
labels = [
    "常规·蓝方在下", "常规·红方在下", "蓄力瞄准", "特殊球刷新",
    "黑洞状态", "暂停", "设置", "结算",
    "社交入口常态", "展开聊天", "键盘弹出", "图片选择",
    "表情面板", "表情发送", "共享音乐", "返回房间确认",
    "选择歌曲", "图片失败", "等待房间",
]
font = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 18)

for first, last, output_name in [
    (0, 8, "core_views_v2.png"),
    (8, 19, "social_views_v2.png"),
    (0, 19, "ui_overview_v2.png"),
]:
    selected = list(range(first, last))
    sheet = Image.new("RGB", (1120, ((len(selected) + 3) // 4) * 528), (15, 10, 27))
    draw = ImageDraw.Draw(sheet)
    for position, index in enumerate(selected):
        x, y = (position % 4) * 280, (position // 4) * 528
        preview = Image.open(out_dir / f"{names[index]}.png").convert("RGB")
        sheet.paste(preview.resize((270, 480)), (x, y + 33))
        draw.text((x + 6, y + 5), labels[index], font=font, fill="white")
    sheet.save(out_dir / output_name)
