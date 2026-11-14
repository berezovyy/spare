# Review — draft 1

Storyline B ("Cut on the beat"), 42 s, 1920×1080, 30 fps. A and C are in STORYLINES.md.

## Creative calls
- The palette is rebuilt from Theme.swift and RowViews.swift at 2× (sizes, radii, the ↵ chip, ⌘1–9
  numbers, the hint capsule, the "Images ×" tag, the "Deleted · ⌘Z Undo" toast, the filter menu
  items). It was not compared with a screenshot of the running app. Clip contents are illustrative.
- The cut into the product is a morph: the V key's white closes onto the palette on the music's drop.
- Numbers: "< 25 MB" and "< 0.05%" are rounded up from X11 (18–22 MB, ≤ 0.042%). "0 network
  connections" comes from the code (the app has no networking).
- Music: "Electro Dreams" (Arulo, Mixkit, 120 BPM) enters at 10.035 s so the drop falls on 6.0.

## Measured vs looked at
- `hyperframes check`: no errors. Kept warnings:
  - `line_unread` on the history rows that stream past (texture, not meant to be read);
  - `text_below_floor` on palette meta text (22 px, the real UI's secondary size at 2×).
- Looked at: QA frames, every seam (−0.2/+0.2 s) and the phone sheet. The sound was placed from
  measured peaks but nobody has heard it yet.

## Weakest shot
The opening of the payoff (28–29 s): blurred rows pouring into a palette. With more time it should
build to something bigger, for example the rows landing on the beat grid.

## Delivery render
- `renders/spare.mp4`: 1920×1080, 30 fps, H.264 + AAC, 42.0 s, 5.4 MB (`render -q delivery`).
- Audio measured on the file: −15.6 LUFS integrated, true peak −1.3 dBTP, no clipping; the drop
  lands at 6.0 s. Still not heard by anyone.
- README copies: `../demo.mp4` (the render) and `../demo.webp` (1280 wide, 25 fps, lossy q75,
  3.7 MB), made with `ffmpeg -vf fps=25,scale=1280:-2` and `img2webp -lossy -q 75 -m 6 -d 40`.

## v2 — faster, harder (current)
- 25.0 s render, 5.2 MB; README WebP 2.4 MB. Audio measured: −14.3 LUFS, true peak −1.0 dBTP, no
  clipping. Still not heard.
- Fixed after looking at the render: the glass palette went grey on the ink field (Delete is on
  white now); the icon landed before the violet flood had filled the frame (flood now ends on the
  downbeat).
- Kept on purpose: many `line_unread` warnings in the montage; the user asked for faster.
