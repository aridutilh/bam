# Bam branding

Bam’s icon is a vivid textured red sale-burst sticker with a peeled white lower-right corner, centered on a light matte pink rounded square. It has no lettering. The generated master was approved for the 0.5.4 rename. Build 17 packaging and exact approved-master identity passed; native main-window, menu and About checks confirmed the installed Bam branding. Broader Dock/Home appearance and display-scale coverage remain open.

The artwork was created with the built-in image-generation tool on October 23, 2026. The final refinement used an earlier Bam icon draft as its edit target, brightening the pink tile and softening the sticker’s shadow while preserving the red burst and peeled corner. The prompt below records the requested edit; it is not a claim that every requested pixel detail was independently verified.

The public master is [Resources/BamIcon.png](../Resources/BamIcon.png). Run `bash scripts/generate-icon.sh` to resize and package it into the ten standard macOS icon representations. The normal build runs that script automatically; packaging does not require an image service or API key. Generated ICNS files are build artifacts.

Bam is an independent project, not affiliated with Arc, The Browser Company or Yab. Releases through 0.5.3 used the former Ark name and icon; their historical changelog and validation entries remain dated evidence.

## Bam Preview

Preview uses a safety-yellow burst sticker on a matte charcoal tile, with a short hazard-stripe band along the bottom. Its paper texture and white peeled corner retain the Bam family resemblance while separating experimental windows in the Dock.

The master is [Resources/BamPreviewIcon.png](../Resources/BamPreviewIcon.png), created on October 24, 2026 with the built-in image-generation tool in edit mode, using the production master as the reference. Run `bash scripts/generate-icon.sh BamPreviewIcon` to package it. Fresh and persistent development previews choose this icon at runtime; the separate draft bundle also declares it for Finder. Normal launches retain the production icon. This is a local unreleased draft. The PNG is original Bam artwork, not extracted third-party art. The packaging script only resizes the authored master; it cannot recreate the artwork deterministically, so the source PNG is committed and ICNS files are generated at build time.

### Preview generation prompt

```text
Use case: precise-object-edit. Asset type: macOS Dock icon for Bam Preview, an experimental browser build. Input image 1 is the edit target and design reference. Give it a construction/safety color theme. Change the red comic sale-burst sticker to bright saturated safety yellow, approximately #FFD52A, and the pink rounded-square tile to a clean matte dark charcoal, approximately #282A2D. Preserve the sticker size, centered silhouette, tactile paper texture, fine rim, short soft shadow, and peeled white lower-right corner. Keep the tile nearly flat with subtle dimensional edge shading. Add just one restrained construction detail: a short band of three broad alternating safety-yellow/charcoal diagonal hazard stripes along the bottom edge of the tile, confined to the exposed bottom margin beneath the sticker and neatly clipped inside the rounded tile. It must remain an elegant simple icon with excellent small-size legibility, clearly related to Bam but obviously the construction/preview edition. No text, no letters, no hard hat, no tools, no extra badges. Preserve the square canvas, transparent outer padding, and tile geometry. Clean antialiased boundaries and no stray colored specks outside the tile. Output only the icon on a genuinely transparent background.
```

## Production refinement prompt

```text
Use case: precise-object-edit. Asset type: macOS Dock application icon, local draft. Input image 1 is the exact edit target. Change only the rounded-square pink tile color and associated shadows: make the tile a considerably lighter, brighter, fresh candy pink, approximately #FFD0E3, so the red burst pops vividly at small Dock sizes. Keep the tile matte and flat, almost uniform pale pink, with only subtle dimensional edge shading; no glossy shine or strong gradient. Reduce the dark muddy shadow underneath the red sticker to a short, soft, subtle warm shadow. Preserve exactly the current size, position, silhouette, vivid red color, textured paper surface, thin rim, and curled/peeled white lower-right corner of the smaller red sale sticker. Preserve tile shape and transparent outer padding. Clean antialiased edges: remove any isolated red/pink/white specks or fringe outside the tile, making everything outside its rounded-square silhouette fully transparent. Keep the artwork centered and square, no text, no letters, no extra shapes or objects. Output the icon by itself with a transparent background.
```
