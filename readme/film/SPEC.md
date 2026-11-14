# SPEC — "Cut on the beat" (storyline B)

## v2 (current): 25 s, faster and harder

Asked for: faster than v1's 42 s, more epic, no API key as the example.
- 25 s = 750 frames. Track enters at 13.035 s so the drop lands on film 3.0.
- Example clip: "Flight to Lisbon · booking KX7Q2M", found by typing "lisbon" (folds at "lis").
- Shots: 0-3 hook (line on 16ths, 40 copies tear past, ⌘ ⇧ V slam on 16ths, V zooms through);
  3-6 search (stage shake on the drop, paste lands at 4.6); 6-11 one chord per second, fields wipe
  in from the left, a stage kick on every press; 11-12.5 passwords; 12.5-15.5 three numbers at
  1 s each (count-up, letters on frames, zoom slam); 15.5-19.5 payoff (camera rips back from 3.4x
  inside the palette, lands with a kick, Return bursts into white from the ↵ chip); 19.5-25 claim
  on 16ths, violet circle flood, icon slam + shake, name per letter, ⌘⇧V pressed.
- Render-time motion blur is on (`data-motion-blur="on"` on the root).
- Line holds are deliberately under the reading floor in the montage; the payoff line, the paste
  and the end card keep theirs.

## v1 (superseded): the 42 s cut below

GOAL:    a developer watching the README knows in 40 s that ⌘⇧V brings back anything they copied,
         that every action is one chord, and that it costs nothing to keep running.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps.
TIME:    42 s x 30 = 1260 frames. Music "Electro Dreams" (Arulo, Mixkit), 120 BPM, 15 frames a
         beat, 60 a bar. Track enters at 10.035 s so film 0.000 is a beat; the drop (track 16.035)
         lands on film 6.000; the breakdown (track 48.3) lands on 38.3 under the end card.
LOOK:    flat colour fields, no gradients on grounds:
           violet #5A4FFD (the icon's tile), deep #4B3CD8 (the icon's lines), white #FFFFFF,
           ink #0E0C1F. Field swaps on half beats in the chord section, on bars elsewhere.
         Accent: white on violet, violet on white; the selection fill is violet at 20% (the
         product's own accent at its light-mode alpha).
         Display: SF Pro (SFNS.ttf, the product's face), 700, 150-220 px, tracking -4%.
         Body/UI: SF Pro 400/600 at 2x the palette's real sizes.
         Medium: keycaps and the product's own glass panel.
           keycap: 300 px square, radius 60, top #FFFFFF, lip 18 px #C9C4FF, drop shadow
             0 34 60 rgba(14,12,31,.28); glyph 150 px ink 600. Press: y +14 px, lip 4 px, 4 frames
             down (expo.out), 6 frames up.
           palette: Theme.swift at 2x - 1120 x 720, radius 36, header 88, rows 72, title 26 px,
             meta 22 px, keycap chip 36 px radius 10; glass = rgba(255,255,255,.74) +
             blur 40 px, 1.5 px rim rgba(255,255,255,.9), shadow 0 40 90 rgba(20,10,80,.35).
OBJECTS: keycap (white cap with a visible lip, reads as a Mac key); the Spare palette (search
         row with magnifier, rows with glyph + one-line title, selected row shows "app · age"
         and a ↵ chip); hint capsules under it (⌘1–9 Paste · ⌘P Pin · ⌘⌫ Delete · ⌘C Copy ·
         ⌘F Filter); filter tag "Images ×"; toast "Deleted · ⌘Z Undo"; the icon PNG.
MOTION:  enter expo.out 0.35 s; camera/field power2.inOut 0.4 s; exits power3.in 0.2 s;
         palette summon = the app's own: scale .96 → 1, 0.34 s, no overshoot, fade 0.12 s;
         selection glide 0.2 s cubic(.22,1,.36,1); rows stagger 2 frames; letters 1 frame;
         words on beats or 8ths. Slams: whole word blur 10 → 0 in 4 frames, scale 1.08 → 1.
SHOTS (beat = 0.5 s):
  0.0-2.0   white field. "You copied it an hour ago" per word on 8ths, ink, 120 px. Key tick.
  2.0-4.0   ink field. Clip titles stream upward behind "40 copies later" (white 150 px); a counter
            1 → 40 ticks on 16ths. Soft whoosh at 2.0.
  4.0-6.0   violet field. Three keycaps ⌘ ⇧ V drop in on beats 4.0/4.5/5.0, pressed together on 5.5,
            the V cap zooms through (scale 1 → 9, power3.in) into white at 5.9. Riser 4.0-6.0.
  6.0-10.0  DROP. Palette summons on 6.0 over violet, 8 history rows. Typing "stag key" 6.75-7.9
            on 16ths; rows fold 8 → 2 → 1; matched words go semibold. Return chip pressed 8.5;
            the row's text flies right and lands in a message line "staging key: sk_test_…" 9.0.
  10.0-20.0 chords, one bar each: beat 1 a keycap chord slams full-frame on a swapped field,
            beats 2-4 the palette does it.
              10 hold ⌘: ⌘1…⌘9 chips replace meta, hint capsule fades in under the palette.
              12 ⌘P: third row rises to the top, pin glyph appears.
              14 ⌘F: filter tag "Images ×" pops in, list becomes image rows.
              16 ⌘⌫: selected row collapses, toast "Deleted · ⌘Z Undo".
              18 ⌘Z: row comes back in place.
  20.0-22.0 white field. A copy of "••••••••••" from a password manager flies at the palette and
            is refused (shakes, dissolves). "Passwords never recorded".
  22.0-28.0 numbers, one bar each, violet/white/ink swaps: "< 25 MB" memory, "< 0.05%" CPU at
            rest, "0" network connections. Each number lands on the bar's first beat.
  28.0-34.0 payoff: history stream of ~30 clips pours upward and decelerates over 3 bars onto the
            palette; selection lands on row 1 on 33.0; Return; thock at 33.5.
  34.0-38.0 claim on white: "Everything you copied" (bar 1), "one keystroke away" (bar 2), violet
            word "one keystroke".
  38.0-42.0 end card on violet: the icon drops in on 38.0 (spring, damping .75), "Spare" wipes in
            beside it, "⌘⇧V · free for macOS 26" under it, hold to 42.0. Music fades from 40.5.
BANNED:  dark void; glow, bloom, particles; mesh or purple gradient grounds (the icon's own tile is
         the only gradient, inside the icon); three cards in a row; KPI grid; corner labels;
         everything fading and sliding up; titles moving after they land; the logo docked in a
         corner; invented app UI beyond one message line; numbers not measured (X11 measured
         18–22 MB and ≤ 0.042% CPU; no network is a code fact).
QA:      0.0 (thumbnail not empty), 5.6 (three caps), 6.3 (palette on the drop), 7.9 (one row
         left, "stag key" semibold), 9.2 (pasted line), 10.6, 12.8, 14.8, 16.8, 18.8 (each chord),
         21.0, 22.6, 24.6, 26.6, 33.2, 36.0, 40.0.
