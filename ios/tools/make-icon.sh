#!/usr/bin/env bash
# 从 server/icon-512.png 或模板生成 iOS App 图标集
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="BgoPanel/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="../server/icon-512.png"
if [ -f "$SRC" ]; then
  # 居中缩放到 1024x1024，底色近黑 #0b0b0f，移除透明通道（App Store / iOS 要求不透明）
  convert "$SRC" -resize 768x768 -background '#0b0b0f' -gravity center -extent 1024x1024 \
    -alpha remove -alpha off -depth 8 "$OUT/icon-1024.png"
else
  # 降级纯绘制
  convert -size 1024x1024 xc:'#0b0b0f' -fill '#34C759' -draw 'circle 512,512 512,312' \
    -alpha remove -alpha off -depth 8 "$OUT/icon-1024.png"
fi

for spec in 40:icon-40 60:icon-60 58:icon-58 87:icon-87 80:icon-80 120:icon-120 180:icon-180 120:icon-120b; do
  size="${spec%%:*}"
  name="${spec##*:}"
  convert "$OUT/icon-1024.png" -resize "${size}x${size}" \
    -background '#0b0b0f' -alpha remove -alpha off -depth 8 "$OUT/$name.png"
done

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon-40.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "20x20"
    },
    {
      "filename" : "icon-60.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "20x20"
    },
    {
      "filename" : "icon-58.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "29x29"
    },
    {
      "filename" : "icon-87.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "29x29"
    },
    {
      "filename" : "icon-80.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "40x40"
    },
    {
      "filename" : "icon-120b.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "40x40"
    },
    {
      "filename" : "icon-120.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60"
    },
    {
      "filename" : "icon-180.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60"
    },
    {
      "filename" : "icon-1024.png",
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "App icons generated -> $OUT"
