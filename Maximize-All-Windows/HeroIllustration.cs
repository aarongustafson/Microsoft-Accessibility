using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

internal enum HeroIllustrationStyle
{
    BeforeAfter = 0, // Concept G — bold, top/bottom split
    Stacked     = 1  // Concept F — three windows growing
}

/// <summary>
/// Custom-drawn brand illustration that fills the otherwise-empty right side of
/// the Settings window with "a window being maximized." Theme-aware (light/dark).
/// The tagline is rendered as real, separate text (child labels) so screen readers
/// can read it and it is not an image of text (WCAG 1.4.5). Derives from Panel so
/// the child labels stay properly parented in the accessibility tree (a UserPaint
/// Control let them float up to the form, where the text leaked into the buttons).
/// </summary>
internal sealed class HeroIllustration : Panel
{
    // Internal layout grid the artwork is drawn against. The whole illustration
    // is then uniformly scaled to fit the available ClientSize, preserving aspect
    // ratio.
    private const int DesignWidth  = 400;
    private const int DesignHeight = 600;

    // Design-grid Y positions / font sizes for the tagline, mirrored by the real
    // text labels so they sit exactly where the artwork expects them.
    private const float TitleDesignY    = 28f;
    private const float TitleDesignFont = 17f;
    private const float SubDesignY      = 56f;
    private const float SubDesignFont   = 12f;

    private ThemePalette _palette;
    private HeroIllustrationStyle _style;

    // Separate real text for the tagline, plus a visually-hidden label that carries
    // the picture's alt text. Order matters: tagline first, alt last, so a screen
    // reader in scan mode reads the text before the image description.
    private readonly Label _titleLabel;
    private readonly Label _subtitleLabel;
    private readonly Label _altLabel;

    public HeroIllustration()
    {
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.OptimizedDoubleBuffer
            | ControlStyles.AllPaintingInWmPaint
            | ControlStyles.UserPaint
            | ControlStyles.ResizeRedraw,
            true);
        // Decorative graphic: never take keyboard focus.
        SetStyle(ControlStyles.Selectable, false);
        TabStop = false;
        // The container itself carries no accessible name/role; the child labels
        // provide the text and the alt description in reading order.
        AccessibleRole = AccessibleRole.None;
        AccessibleName = string.Empty;
        _palette = ThemeHelper.GetPalette(false);

        _titleLabel = new Label
        {
            AutoSize = true,
            TextAlign = ContentAlignment.MiddleCenter,
            // StaticText role so WinForms doesn't treat the label as the accessible
            // name of the next control in tab order.
            AccessibleRole = AccessibleRole.StaticText,
            TabIndex = 0
        };
        _subtitleLabel = new Label
        {
            AutoSize = true,
            TextAlign = ContentAlignment.MiddleCenter,
            AccessibleRole = AccessibleRole.StaticText,
            TabIndex = 1
        };
        // Visually hidden (ForeColor == BackColor) but read by AT, ordered last so
        // the image description follows the tagline text in scan mode.
        _altLabel = new Label
        {
            AutoSize = false,
            Size = new Size(1, 1),
            Text = "Illustration of a window being maximized.",
            AccessibleRole = AccessibleRole.StaticText,
            AccessibleName = "Illustration of a window being maximized.",
            TabIndex = 2
        };
        Controls.Add(_titleLabel);
        Controls.Add(_subtitleLabel);
        Controls.Add(_altLabel);

        UpdateText();
        UpdateTextColors();
    }

    public ThemePalette Palette
    {
        get => _palette;
        set
        {
            _palette = value;
            UpdateTextColors();
            Invalidate();
        }
    }

    public HeroIllustrationStyle Style
    {
        get => _style;
        set
        {
            if (_style == value)
            {
                return;
            }
            _style = value;
            UpdateText();
            UpdateTextColors();
            LayoutText();
            Invalidate();
        }
    }

    private void UpdateText()
    {
        _titleLabel.Text = "Every window, full screen.";
        _subtitleLabel.Text = _style == HeroIllustrationStyle.BeforeAfter
            ? "Automatically."
            : "Less hunting. More focus.";
    }

    private void UpdateTextColors()
    {
        Color back, title, subtitle;
        if (_style == HeroIllustrationStyle.BeforeAfter)
        {
            // Matches the top of the deep-blue gradient drawn in DrawBeforeAfter.
            back = Color.FromArgb(10, 73, 120);
            title = Color.White;
            subtitle = Color.FromArgb(207, 227, 245);
        }
        else
        {
            back = _palette.IsDark
                ? Color.FromArgb(20, 32, 50)
                : Color.FromArgb(234, 243, 251);
            title = _palette.IsDark
                ? Color.FromArgb(207, 227, 245)
                : Color.FromArgb(10, 73, 120);
            subtitle = _palette.IsDark
                ? Color.FromArgb(160, 188, 215)
                : Color.FromArgb(55, 96, 126);
        }

        _titleLabel.BackColor = back;
        _subtitleLabel.BackColor = back;
        _titleLabel.ForeColor = title;
        _subtitleLabel.ForeColor = subtitle;

        // Keep the alt label invisible to sighted users but present for AT.
        _altLabel.BackColor = back;
        _altLabel.ForeColor = back;
    }

    private void LayoutText()
    {
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0 || _titleLabel is null)
        {
            return;
        }

        // Use the same scale/offset as the artwork so the text lands exactly where
        // the painted version used to (accounting for the letterbox).
        var scale = Math.Min(
            (float)ClientSize.Width / DesignWidth,
            (float)ClientSize.Height / DesignHeight);
        if (scale <= 0)
        {
            return;
        }
        var offsetY = (ClientSize.Height - DesignHeight * scale) / 2f;

        _titleLabel.Font = new Font("Segoe UI", Math.Max(8f, TitleDesignFont * scale), FontStyle.Bold, GraphicsUnit.Pixel);
        _subtitleLabel.Font = new Font("Segoe UI", Math.Max(7f, SubDesignFont * scale), FontStyle.Regular, GraphicsUnit.Pixel);

        _titleLabel.MaximumSize = new Size(ClientSize.Width - 16, 0);
        _subtitleLabel.MaximumSize = new Size(ClientSize.Width - 16, 0);

        _titleLabel.Location = new Point(
            Math.Max(0, (ClientSize.Width - _titleLabel.Width) / 2),
            (int)Math.Round(offsetY + TitleDesignY * scale));
        _subtitleLabel.Location = new Point(
            Math.Max(0, (ClientSize.Width - _subtitleLabel.Width) / 2),
            (int)Math.Round(offsetY + SubDesignY * scale));
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        LayoutText();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode    = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.PixelOffsetMode  = PixelOffsetMode.HighQuality;

        // Letterbox to surface color so the surrounding page never bleeds through.
        using (var surface = new SolidBrush(_palette.Surface))
        {
            g.FillRectangle(surface, ClientRectangle);
        }

        if (ClientSize.Width <= 0 || ClientSize.Height <= 0)
        {
            return;
        }

        var scale = Math.Min(
            (float)ClientSize.Width  / DesignWidth,
            (float)ClientSize.Height / DesignHeight);
        if (scale <= 0)
        {
            return;
        }

        var renderW = DesignWidth  * scale;
        var renderH = DesignHeight * scale;
        var offsetX = (ClientSize.Width  - renderW) / 2f;
        var offsetY = (ClientSize.Height - renderH) / 2f;

        var state = g.Save();
        try
        {
            g.TranslateTransform(offsetX, offsetY);
            g.ScaleTransform(scale, scale);

            if (_style == HeroIllustrationStyle.Stacked)
            {
                DrawStacked(g);
            }
            else
            {
                DrawBeforeAfter(g);
            }
        }
        finally
        {
            g.Restore(state);
        }
    }

    // ===================================================================
    // Concept G — Before / After split
    // ===================================================================
    private void DrawBeforeAfter(Graphics g)
    {
        var bgTop    = Color.FromArgb(10,  73, 120);
        var bgBottom = Color.FromArgb( 0, 120, 212);
        using (var bg = new LinearGradientBrush(
            new Rectangle(0, 0, DesignWidth, DesignHeight),
            bgTop, bgBottom, LinearGradientMode.Vertical))
        {
            g.FillRectangle(bg, 0, 0, DesignWidth, DesignHeight);
        }

        // Tagline is rendered as real text by the title/subtitle labels.

        DrawMiniDesktopScattered(g, new RectangleF(40, 100, 320, 180));

        // Arrow disk
        using (var disk = new SolidBrush(Color.FromArgb(45, 255, 255, 255)))
        {
            g.FillEllipse(disk, 170, 300, 60, 60);
        }
        using (var arrowFill = new SolidBrush(Color.White))
        {
            var points = new[]
            {
                new PointF(190, 313),
                new PointF(210, 313),
                new PointF(210, 333),
                new PointF(222, 333),
                new PointF(200, 354),
                new PointF(178, 333),
                new PointF(190, 333)
            };
            g.FillPolygon(arrowFill, points);
        }

        DrawMiniDesktopMaximized(g, new RectangleF(40, 380, 320, 180));
    }

    private static void DrawMiniDesktopScattered(Graphics g, RectangleF rect)
    {
        DrawMiniDesktopFrame(g, rect);
        DrawMiniWindow(g, new RectangleF(rect.X +  18, rect.Y +  22, 100, 64), highlighted: false);
        DrawMiniWindow(g, new RectangleF(rect.X + 150, rect.Y +  50, 120, 72), highlighted: false);
        DrawMiniWindow(g, new RectangleF(rect.X +  60, rect.Y + 100, 110, 46), highlighted: false);
    }

    private static void DrawMiniDesktopMaximized(Graphics g, RectangleF rect)
    {
        DrawMiniDesktopFrame(g, rect);
        DrawMiniWindow(
            g,
            new RectangleF(rect.X + 6, rect.Y + 6, rect.Width - 12, rect.Height - 26),
            highlighted: true);
    }

    private static void DrawMiniDesktopFrame(Graphics g, RectangleF rect)
    {
        using (var path = RoundedRect(rect, 6))
        {
            using var bg     = new SolidBrush(Color.FromArgb(31, 58, 95));
            using var stroke = new Pen(Color.FromArgb(39, 74, 118), 1f);
            g.FillPath(bg, path);
            g.DrawPath(stroke, path);
        }

        // Taskbar
        var tb = new RectangleF(rect.X, rect.Bottom - 20, rect.Width, 20);
        using (var tbBrush = new SolidBrush(Color.FromArgb(15, 31, 51)))
        {
            g.FillRectangle(tbBrush, tb);
        }
        using var btnBlue = new SolidBrush(Color.FromArgb(  0, 120, 212));
        using var btnGrey = new SolidBrush(Color.FromArgb( 58,  90, 130));
        var bx = rect.X + (rect.Width - 50) / 2;
        g.FillRectangle(btnBlue, bx,      rect.Bottom - 16, 14, 12);
        g.FillRectangle(btnGrey, bx + 18, rect.Bottom - 16, 14, 12);
        g.FillRectangle(btnGrey, bx + 36, rect.Bottom - 16, 14, 12);
    }

    private static void DrawMiniWindow(Graphics g, RectangleF rect, bool highlighted)
    {
        using (var path = RoundedRect(rect, 3))
        {
            using var bg = new SolidBrush(Color.White);
            g.FillPath(bg, path);
            using var stroke = new Pen(
                highlighted
                    ? Color.FromArgb(  0, 120, 212)
                    : Color.FromArgb(170, 192, 216),
                highlighted ? 1.5f : 1f);
            g.DrawPath(stroke, path);
        }

        var tbHeight = Math.Min(14f, rect.Height * 0.28f);
        var tbRect   = new RectangleF(rect.X, rect.Y, rect.Width, tbHeight);
        using (var tbPath = RoundedRectTop(tbRect, 3))
        {
            using var tbBrush = new SolidBrush(highlighted
                ? Color.FromArgb(  0, 120, 212)
                : Color.FromArgb(221, 230, 240));
            g.FillPath(tbBrush, tbPath);
        }

        // Content lines
        using var lineBrush = new SolidBrush(Color.FromArgb(225, 232, 240));
        var widths = new[] { 0.7f, 0.9f, 0.8f, 0.6f, 0.85f, 0.75f, 0.65f, 0.8f, 0.55f };
        var ly = rect.Y + tbHeight + 4;
        var i  = 0;
        while (ly + 3 < rect.Bottom - 3)
        {
            var w = widths[i % widths.Length] * (rect.Width - 16);
            g.FillRectangle(lineBrush, rect.X + 8, ly, w, 3);
            ly += 7;
            i++;
        }
    }

    // ===================================================================
    // Concept F — Three windows growing (with arrows)
    // ===================================================================
    private void DrawStacked(Graphics g)
    {
        var bgTop = _palette.IsDark
            ? Color.FromArgb( 20, 32, 50)
            : Color.FromArgb(234, 243, 251);
        var bgBottom = _palette.IsDark
            ? Color.FromArgb( 15, 22, 36)
            : Color.FromArgb(207, 227, 245);
        using (var bg = new LinearGradientBrush(
            new Rectangle(0, 0, DesignWidth, DesignHeight),
            bgTop, bgBottom, LinearGradientMode.Vertical))
        {
            g.FillRectangle(bg, 0, 0, DesignWidth, DesignHeight);
        }

        // Tagline is rendered as real text by the title/subtitle labels.

        // Smallest (top-left), medium (overlapping), then large "maximized".
        DrawStackedWindow(g, new RectangleF( 60, 110, 130,  90), opacity: 0.55f, highlighted: false);
        DrawStackedWindow(g, new RectangleF( 80, 200, 200, 140), opacity: 0.85f, highlighted: false);
        DrawStackedWindow(g, new RectangleF( 40, 360, 320, 220), opacity: 1.00f, highlighted: true);

        using var arrowPen = new Pen(Color.FromArgb(0, 120, 212), 2.2f);
        DrawArrow(g, new PointF(195, 175), new PointF(195, 220), arrowPen);
        DrawArrow(g, new PointF(220, 340), new PointF(220, 380), arrowPen);
    }

    private void DrawStackedWindow(Graphics g, RectangleF rect, float opacity, bool highlighted)
    {
        var alpha = (int)Math.Round(255 * opacity);

        var bodyBase   = _palette.IsDark ? Color.FromArgb(60, 70, 90) : Color.White;
        var borderBase = highlighted
            ? Color.FromArgb(0, 120, 212)
            : (_palette.IsDark
                ? Color.FromArgb( 90, 110, 140)
                : Color.FromArgb(150, 170, 200));

        var fill   = Color.FromArgb(alpha, bodyBase);
        var border = Color.FromArgb(alpha, borderBase);

        using (var path = RoundedRect(rect, 6))
        {
            using var bg = new SolidBrush(fill);
            g.FillPath(bg, path);
            using var stroke = new Pen(border, highlighted ? 2f : 1.2f);
            g.DrawPath(stroke, path);
        }

        var tbBase = highlighted
            ? Color.FromArgb(0, 120, 212)
            : (_palette.IsDark
                ? Color.FromArgb( 75,  90, 115)
                : Color.FromArgb(205, 219, 235));
        var tbColor  = Color.FromArgb(alpha, tbBase);
        var tbHeight = Math.Min(22f, rect.Height * 0.18f);
        var tbRect   = new RectangleF(rect.X, rect.Y, rect.Width, tbHeight);
        using (var tbPath = RoundedRectTop(tbRect, 6))
        {
            using var tbBrush = new SolidBrush(tbColor);
            g.FillPath(tbBrush, tbPath);
        }

        // Traffic-light dots (only on the wider frames)
        if (rect.Width > 80)
        {
            var dotY = rect.Y + tbHeight / 2 - 3;
            using var red    = new SolidBrush(Color.FromArgb(alpha, 255,  95,  87));
            using var yellow = new SolidBrush(Color.FromArgb(alpha, 254, 188,  46));
            using var green  = new SolidBrush(Color.FromArgb(alpha,  40, 200,  64));
            g.FillEllipse(red,    rect.X +  8, dotY, 6, 6);
            g.FillEllipse(yellow, rect.X + 18, dotY, 6, 6);
            g.FillEllipse(green,  rect.X + 28, dotY, 6, 6);
        }

        // Content lines
        var lineBase = _palette.IsDark
            ? Color.FromArgb(140, 160, 185)
            : Color.FromArgb(220, 230, 240);
        var lineColor = Color.FromArgb((int)(alpha * 0.7f), lineBase);
        using var lineBrush = new SolidBrush(lineColor);

        var widths = new[] { 0.7f, 0.55f, 0.85f, 0.65f, 0.8f, 0.5f, 0.75f, 0.6f };
        var ly = rect.Y + tbHeight + 8;
        var i  = 0;
        var contentLimit = highlighted ? rect.Bottom - 26 : rect.Bottom - 8;
        while (ly + 4 < contentLimit)
        {
            var w = widths[i % widths.Length] * (rect.Width - 24);
            g.FillRectangle(lineBrush, rect.X + 12, ly, w, 4);
            ly += 10;
            i++;
        }

        if (highlighted)
        {
            using var badgeFont = new Font("Segoe UI", 10f, FontStyle.Bold, GraphicsUnit.Pixel);
            const string badgeText = "Maximized";
            var size = g.MeasureString(badgeText, badgeFont);
            var pillRect = new RectangleF(
                rect.X + (rect.Width - size.Width - 16) / 2,
                rect.Bottom - size.Height - 12,
                size.Width + 16,
                size.Height + 6);
            using (var pillPath = RoundedRect(pillRect, 3))
            {
                using var pillBrush = new SolidBrush(Color.FromArgb(0, 120, 212));
                g.FillPath(pillBrush, pillPath);
            }
            using var textBrush = new SolidBrush(Color.White);
            g.DrawString(badgeText, badgeFont, textBrush,
                pillRect.X + 8, pillRect.Y + 3);
        }
    }

    // ===================================================================
    // Drawing helpers
    // ===================================================================
    private static void DrawArrow(Graphics g, PointF from, PointF to, Pen pen)
    {
        g.DrawLine(pen, from, to);
        var dx = to.X - from.X;
        var dy = to.Y - from.Y;
        var len = (float)Math.Sqrt(dx * dx + dy * dy);
        if (len < 0.1f)
        {
            return;
        }
        dx /= len; dy /= len;
        const float head = 7f;
        var perpX = -dy * head;
        var perpY =  dx * head;
        var basePt = new PointF(to.X - dx * head * 1.5f, to.Y - dy * head * 1.5f);
        var p1 = new PointF(basePt.X + perpX, basePt.Y + perpY);
        var p2 = new PointF(basePt.X - perpX, basePt.Y - perpY);
        using var brush = new SolidBrush(pen.Color);
        g.FillPolygon(brush, new[] { to, p1, p2 });
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.StartFigure();
        path.AddArc(r.X,           r.Y,           d, d, 180, 90);
        path.AddArc(r.Right - d,   r.Y,           d, d, 270, 90);
        path.AddArc(r.Right - d,   r.Bottom - d,  d, d,   0, 90);
        path.AddArc(r.X,           r.Bottom - d,  d, d,  90, 90);
        path.CloseFigure();
        return path;
    }

    private static GraphicsPath RoundedRectTop(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.StartFigure();
        path.AddArc(r.X,         r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddLine(r.Right, r.Bottom, r.X, r.Bottom);
        path.CloseFigure();
        return path;
    }
}
