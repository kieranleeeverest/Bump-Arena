from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

out_dir = Path(r"E:\杂项\怼球复刻\diagnostics\ui_design_v3_2026-11-22")
items = [
    ("01_profile_first", "首次设置资料"),
    ("02_name_empty", "昵称为空"),
    ("03_name_long", "昵称过长"),
    ("04_name_invalid", "昵称含非法字符"),
    ("05_avatar_choose", "选择头像图片"),
    ("06_avatar_crop", "圆形裁剪"),
    ("07_avatar_error", "头像保存失败"),
    ("08_avatar_on_ball", "头像应用到球体"),
    ("09_four_avatars_blue", "四人头像·蓝方在下"),
    ("10_four_avatars_red", "四人头像·红方在下"),
    ("11_current_turn", "当前行动"),
    ("12_tower_damage", "塔受到伤害"),
    ("13_vampire_heal", "吸血与回血"),
    ("14_round_change", "完整回合切换"),
    ("15_special_spawn", "特殊球刷新"),
    ("16_black_hole", "黑洞剩余回合"),
    ("17_swallowed_waiting", "吞噬等待重生"),
    ("18_respawn", "玩家球重生"),
    ("19_chat_preview", "新消息预览"),
    ("20_emoji_recent", "最近表情"),
    ("21_music_playing", "共享音乐播放"),
    ("22_music_failure", "音乐播放失败"),
    ("23_room_ready", "房间四人准备"),
    ("24_room_unready", "玩家未准备齐"),
    ("25_room_disconnected", "房间断线重连"),
    ("26_pause", "暂停菜单"),
    ("27_settings", "设置"),
    ("28_result", "四人结算"),
    ("29_match_disconnected", "对局中断线"),
    ("30_match_away", "对局中暂离"),
]
font = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 18)

for first, last, filename in [
    (0, 10, "01_profile_views.png"),
    (10, 20, "02_match_feedback.png"),
    (20, 30, "03_social_and_room.png"),
]:
    sheet = Image.new("RGB", (1400, 1056), (15, 10, 27))
    draw = ImageDraw.Draw(sheet)
    for position, (stem, label) in enumerate(items[first:last]):
        x, y = (position % 5) * 280, (position // 5) * 528
        preview = Image.open(out_dir / f"{stem}.png").convert("RGB")
        sheet.paste(preview.resize((270, 480)), (x, y + 33))
        draw.text((x + 6, y + 5), label, font=font, fill="white")
    sheet.save(out_dir / filename)
