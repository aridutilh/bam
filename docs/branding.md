# Bam branding

Bam’s icon is a vivid textured red sale-burst sticker with a peeled white lower-right corner, centered on a light matte pink rounded square. It has no lettering. The generated master was approved for the 0.5.4 rename. Build 17 packaging and exact approved-master identity passed; native main-window, menu and About checks confirmed the installed Bam branding. Broader Dock/Home appearance and display-scale coverage remain open.

The artwork was created with the built-in image-generation tool on October 23, 2026. The final refinement used an earlier Bam icon draft as its edit target, brightening the pink tile and softening the sticker’s shadow while preserving the red burst and peeled corner. The prompt below records the requested edit; it is not a claim that every requested pixel detail was independently verified.

The public master is [Resources/BamIcon.png](../Resources/BamIcon.png). Run `bash scripts/generate-icon.sh` to resize and package it into the ten standard macOS icon representations. The normal build runs that script automatically; packaging does not require an image service or API key. Generated ICNS files are build artifacts.

Bam is an independent project, not affiliated with Arc, The Browser Company or Yab. Releases through 0.5.3 used the former Ark name and icon; their historical changelog and validation entries remain dated evidence.

## Final refinement prompt

```text
Use case: precise-object-edit. Asset type: macOS Dock application icon, local draft. Input image 1 is the exact edit target. Change only the rounded-square pink tile color and associated shadows: make the tile a considerably lighter, brighter, fresh candy pink, approximately #FFD0E3, so the red burst pops vividly at small Dock sizes. Keep the tile matte and flat, almost uniform pale pink, with only subtle dimensional edge shading; no glossy shine or strong gradient. Reduce the dark muddy shadow underneath the red sticker to a short, soft, subtle warm shadow. Preserve exactly the current size, position, silhouette, vivid red color, textured paper surface, thin rim, and curled/peeled white lower-right corner of the smaller red sale sticker. Preserve tile shape and transparent outer padding. Clean antialiased edges: remove any isolated red/pink/white specks or fringe outside the tile, making everything outside its rounded-square silhouette fully transparent. Keep the artwork centered and square, no text, no letters, no extra shapes or objects. Output the icon by itself with a transparent background.
```
