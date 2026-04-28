# PocketMai App Store assets

All icons are generated from `PocketMai/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024×1024, RGB, no alpha).

## App Store Connect submission

The only icon App Store Connect *requires* you to upload is the marketing icon:

- `icon-1024.png` — App Store marketing icon (1024×1024, PNG, no alpha, no transparency)

Xcode's modern asset catalog uses a single 1024×1024 universal icon and downsizes at build time, so the project itself only ships `AppIcon.png`. The per-size files below are provided for cases where you need them outside Xcode (legacy build systems, marketing material, third-party stores, web).

## iPhone

| File             | Size      | Use                              |
|------------------|-----------|----------------------------------|
| `icon-40.png`    | 40×40     | Notification 20pt @2x            |
| `icon-60.png`    | 60×60     | Notification 20pt @3x            |
| `icon-58.png`    | 58×58     | Settings 29pt @2x                |
| `icon-87.png`    | 87×87     | Settings 29pt @3x                |
| `icon-80.png`    | 80×80     | Spotlight 40pt @2x               |
| `icon-120.png`   | 120×120   | Spotlight 40pt @3x / App 60pt @2x |
| `icon-180.png`   | 180×180   | App 60pt @3x                     |

## iPad

| File             | Size      | Use                              |
|------------------|-----------|----------------------------------|
| `icon-20.png`    | 20×20     | Notification 20pt @1x            |
| `icon-29.png`    | 29×29     | Settings 29pt @1x                |
| `icon-76.png`    | 76×76     | App 76pt @1x                     |
| `icon-152.png`   | 152×152   | App 76pt @2x                     |
| `icon-167.png`   | 167×167   | iPad Pro app 83.5pt @2x          |

## Marketing / store

| File             | Size        | Use                            |
|------------------|-------------|--------------------------------|
| `icon-1024.png`  | 1024×1024   | App Store marketing icon       |
| `icon-512.png`   | 512×512     | Generic web / press            |
| `icon-256.png`   | 256×256     | Generic web / press            |
| `icon-192.png`   | 192×192     | Web manifest / Android-style   |
| `icon-128.png`   | 128×128     | Generic web / press            |
| `icon-114.png`   | 114×114     | Legacy iOS                     |

## Other things you still need before publishing

These cannot be generated from the icon — produce them separately:

- **Screenshots** (App Store Connect requires at least one size set):
  - 6.9" iPhone: 1290×2796 portrait or 2796×1290 landscape (iPhone 16 Pro Max / 15 Pro Max)
  - 6.5" iPhone: 1242×2688 or 1284×2778 (fallback for older review tooling)
  - 13" iPad: 2064×2752 portrait (iPad Pro M4) — only required if the app supports iPad
- **App Preview videos** (optional)
- **App description, keywords, support URL, privacy policy URL** (entered in App Store Connect)
- **Privacy nutrition labels** (declared in App Store Connect)
- **Build uploaded via Xcode → Product → Archive → Distribute App** (or `xcodebuild -exportArchive`)

## Regenerating

```sh
SRC=PocketMai/Assets.xcassets/AppIcon.appiconset/AppIcon.png
for sz in 20 29 40 58 60 76 80 87 114 120 128 152 167 180 192 256 512 1024; do
  sips -s format png -z $sz $sz "$SRC" --out "appIcons/icon-${sz}.png"
done
```
