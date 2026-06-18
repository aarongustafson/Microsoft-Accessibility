# Magnifier-friendly layout — design concepts

The Settings window opens **maximized** by default — that's the app's identity. The right ~60% of the surface is currently empty white. For a Windows Magnifier user at typical zoom (2×–4×), panning right reveals nothing.

**Decision constraints:**
- Stay maximized by default.
- No assistive-technology detection (no Magnifier sniffing, no special modes).
- The fix must work the same for every user.

The two concepts that best meet those constraints are **F** and **G** — fill the right side with a static brand illustration of "a window maximizing." The others are kept for reference.

| # | Concept | Mockup | Meets constraints? |
|---|---|---|---|
| 0 | Baseline — today (shows the problem) | [00-current-state.svg](00-current-state.svg) | — |
| F | **Hero illustration: small → big window** | [06-hero-illustration.svg](06-hero-illustration.svg) | recommended |
| G | **Before / after split illustration** | [07-before-after-hero.svg](07-before-after-hero.svg) | recommended (bolder) |
| C | Contextual help pane | [03-context-help-pane.svg](03-context-help-pane.svg) | yes (text, not illustration) |
| D | Live preview pane | [04-live-preview-pane.svg](04-live-preview-pane.svg) | yes |
| A | Centered content column | [01-centered-column.svg](01-centered-column.svg) | partial — still empty right side |
| B | Don't open maximized | [02-compact-window.svg](02-compact-window.svg) | no — violates "stay maximized" |
| E | Magnifier-friendly mode (auto-detect) | [05-magnifier-friendly-mode.svg](05-magnifier-friendly-mode.svg) | no — violates "no AT detection" |

## Recommended: F or G — hero illustration on the right

Add a third column to the body `TableLayoutPanel` (after the sidebar and content panes) that hosts a single illustration. The right side stops being dead space and becomes a brand moment that says *"this is what the app does."*

**Concept F — three stacked window frames** ([06-hero-illustration.svg](06-hero-illustration.svg))
A faint small window in the corner, a medium translucent one overlapping, and a full opaque "maximized" window with a `Maximized` badge. Two arrows trace the growth. Soft blue gradient background. Subtitle: *"Every window, full screen. Less hunting for tiny windows. More focus."*

**Concept G — before / after** ([07-before-after-hero.svg](07-before-after-hero.svg))
Bolder, simpler. Top: a tiny mock desktop with three scattered small windows. Big white up-arrow. Bottom: the same mock desktop with one window filling it. Strong blue background so it reads at any zoom. Title: *"Every window, full screen. Automatically."*

Both:
- Are static assets — no runtime detection, no per-user code paths
- Use high color contrast against the white settings panel so they're discoverable even at low zoom
- Scale with window resizing (`PictureBox.SizeMode = Zoom`)
- Reinforce the app's value proposition for *every* user, not just Magnifier users

## Implementation sketch (F or G)

```csharp
// In CreateControlWindow, change the body from 2 columns to 3:
var body = new TableLayoutPanel
{
    Dock = DockStyle.Fill,
    ColumnCount = 3,
    RowCount = 1,
};
body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220));   // sidebar
body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,  100));   // settings/about
body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 420));   // hero illustration

var heroImage = new PictureBox
{
    Dock = DockStyle.Fill,
    SizeMode = PictureBoxSizeMode.Zoom,
    Image = LoadEmbeddedImage("MaximizeAllWindows.Assets.hero.png"),
    BackColor = Color.FromArgb(234, 243, 251),
};
// Accessibility: surface it as a decorative graphic, not focusable.
heroImage.AccessibleRole = AccessibleRole.Graphic;
heroImage.AccessibleName = "Illustration of a window being maximized";

body.Controls.Add(sidebarHost, 0, 0);
body.Controls.Add(contentHost, 1, 0);
body.Controls.Add(heroImage,   2, 0);
```

Drop the asset into `Assets/hero.png` (or `.svg` rasterized to a few sizes) and mark it as `EmbeddedResource` in the `.csproj`, same pattern already used for `tray-icon.ico`.

**Theming:** prepare two versions — `hero-light.png` and `hero-dark.png` — and swap inside `ApplyTheme(palette)`. Concept G's deep-blue background works well in both modes; Concept F needs a dark-mode variant.

**Responsiveness:** if the window is restored to a small size and the third column would crowd the settings, collapse it once the form width drops below, say, 1000 px:

```csharp
form.SizeChanged += (_, _) =>
    body.ColumnStyles[2].Width = form.ClientSize.Width < 1000 ? 0 : 420;
```

## Magnifier-viewport markers in the mockups

The dashed yellow rectangle in each SVG approximates a Magnifier viewport at the noted zoom level, parked where a user might pan to. With concepts F and G, panning right lands on rich, high-contrast illustration instead of empty white.
