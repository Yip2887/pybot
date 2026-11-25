/* TL;DR Overlay - SpiderSurface.cs
 *
 * The one hot path in this app: spider physics and rendering at 60fps. It lives in
 * C# because PowerShell scriptblocks are far too slow to drive a per-frame loop.
 * Everything else (reading text, scoring, the panel, Claude) stays in PowerShell.
 *
 * Compiled with Add-Type, so this must stay C# 5 compatible:
 * no string interpolation, no expression-bodied members, no null-conditional.
 *
 * Coordinates here are physical screen pixels. OnRender pushes a scale + translate
 * so the result lands correctly on the DIP-based WPF visual tree.
 */
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Tldr
{
    public class SpiderSurface : FrameworkElement
    {
        public const int LegCount = 8;
        public const int LegStride = 8;    // hipX, hipY, kneeX, kneeY, footX, footY, lift, toeDir
        public const int GlitchStride = 6; // x, y, w, h, kind, rotation

        private static readonly double[] HipLocalX = { 10, 4, -4, -10 };
        private static readonly double[] RestLocalX = { 22, 8, -8, -22 };
        private static readonly double[] RestLocalY = { 26, 34, 36, 28 };
        private static readonly double[] BoneL1 = { 28, 30, 30, 28 };
        private static readonly double[] BoneL2 = { 32, 34, 34, 32 };

        private static readonly Brush BodyOutline = Frozen(new SolidColorBrush(Color.FromRgb(0x5a, 0xb8, 0xff)));
        private static readonly Brush BodyFill = Frozen(new SolidColorBrush(Color.FromArgb(0x66, 0x0a, 0x10, 0x18)));
        private static readonly Brush JointBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xff, 0x7a, 0xb8)));
        private static readonly Brush EyeWhite = Frozen(new SolidColorBrush(Colors.White));
        private static readonly Brush EyeDark = Frozen(new SolidColorBrush(Color.FromRgb(0x0f, 0x11, 0x15)));
        private static readonly Brush HighlightBrush = Frozen(new SolidColorBrush(Color.FromArgb(0x5e, 0xff, 0xd6, 0x66)));
        private static readonly Brush HighlightEdge = Frozen(new SolidColorBrush(Color.FromArgb(0xc0, 0xe8, 0xb0, 0x30)));
        private static readonly Brush GlitchBox = Frozen(new SolidColorBrush(Color.FromArgb(0x55, 0x5a, 0xb8, 0xff)));
        private static readonly Brush GlitchTextBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xcf, 0xe8, 0xff)));
        private static readonly Pen BodyPen = FrozenPen(new Pen(BodyOutline, 2.2));
        private static readonly Pen LegPen = FrozenPen(new Pen(BodyOutline, 3.0));
        private static readonly Pen LegPenLifted = FrozenPen(new Pen(BodyOutline, 2.2));
        private static readonly Pen ToePen = FrozenPen(new Pen(BodyOutline, 2.4));
        private static readonly Pen HighlightPen = FrozenPen(new Pen(HighlightEdge, 1.0));
        private static readonly Typeface BodyTypeface = new Typeface("Segoe UI");
        private static readonly Typeface MonoTypeface = new Typeface("Consolas");
        private static readonly Typeface MonoBoldTypeface = new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);

        // ---- state written by PowerShell -------------------------------------
        public double BodyX;
        public double BodyY;
        public double Heading;
        public double TargetX;
        public double TargetY;
        public double SpeedCap = 420;
        public double StepTrigger = 80;
        public double StopDistance = 40;
        public double StepDuration = 0.13;
        public bool Wandering;
        public double ScreenX;
        public double ScreenY;
        public double ScreenW = 1280;
        public double ScreenH = 800;
        public double OriginX;
        public double OriginY;
        public double Scale = 1;
        public bool Running = true;
        public bool Active = true;

        public double[] Legs = new double[LegCount * LegStride];
        public int[] StepCounters = new int[LegCount];
        public double[] Highlights = new double[0];
        public double[] Glitches = new double[0];
        public string[] GlitchText = new string[0];

        private readonly bool[] steppingFlag = new bool[LegCount];
        private readonly double[] stepT = new double[LegCount];
        private readonly double[] stepFromX = new double[LegCount];
        private readonly double[] stepFromY = new double[LegCount];
        private readonly double[] stepToX = new double[LegCount];
        private readonly double[] stepToY = new double[LegCount];

        private double vx, vy, lastTime = -1, acc, wanderUntil;
        private int lastGroup = -1;
        private bool initialised;
        private readonly Random rng = new Random();

        public SpiderSurface()
        {
            Focusable = false;
            IsHitTestVisible = false;
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        private static Brush Frozen(Brush b) { b.Freeze(); return b; }
        private static Pen FrozenPen(Pen p) { p.Freeze(); return p; }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (!initialised) Init();
            CompositionTarget.Rendering += OnFrame;
        }

        private void OnUnloaded(object sender, RoutedEventArgs e)
        {
            CompositionTarget.Rendering -= OnFrame;
        }

        public void Init()
        {
            initialised = true;
            TargetX = BodyX;
            TargetY = BodyY;
            double c = Math.Cos(Heading), sn = Math.Sin(Heading);
            for (int leg = 0; leg < LegCount; leg++)
            {
                int side = leg / 4;
                int i = leg % 4;
                double s = side == 0 ? 1.0 : -1.0;
                double rx = RestLocalX[i];
                double ry = s * RestLocalY[i];
                int b = leg * LegStride;
                Legs[b + 4] = BodyX + rx * c - ry * sn;
                Legs[b + 5] = BodyY + rx * sn + ry * c;
                Legs[b + 6] = 0;
                Legs[b + 7] = Heading;
                steppingFlag[leg] = false;
                stepT[leg] = 0;
            }
        }

        public void ResetLegs()
        {
            initialised = false;
            Init();
        }

        private void OnFrame(object sender, EventArgs e)
        {
            if (!Running || !Active) return;
            RenderingEventArgs args = e as RenderingEventArgs;
            double now = args != null ? args.RenderingTime.TotalSeconds : Environment.TickCount / 1000.0;
            if (lastTime < 0) { lastTime = now; return; }
            double dt = now - lastTime;
            lastTime = now;
            if (dt <= 0) return;
            if (dt > 0.25) dt = 0.25; // the compositor was throttled

            acc += dt;
            int guard = 0;
            while (acc >= 0.0083333333 && guard++ < 24)
            {
                Step(0.0083333333, now);
                acc -= 0.0083333333;
            }
            InvalidateVisual();
        }

        private void Step(double dt, double now)
        {
            if (Wandering && now >= wanderUntil)
            {
                wanderUntil = now + 2.5 + rng.NextDouble() * 2.5;
                double m = 80;
                TargetX = ScreenX + m + rng.NextDouble() * Math.Max(1, ScreenW - 2 * m);
                TargetY = ScreenY + m + rng.NextDouble() * Math.Max(1, ScreenH - 2 * m);
            }

            double dx = TargetX - BodyX;
            double dy = TargetY - BodyY;
            double d = Math.Sqrt(dx * dx + dy * dy);
            double wx = 0, wy = 0;
            if (d > StopDistance)
            {
                double sp = Math.Min(SpeedCap, d * 2.5);
                wx = dx / d * sp;
                wy = dy / d * sp;
            }
            double k = Math.Min(1.0, 6.0 * dt);
            vx += (wx - vx) * k;
            vy += (wy - vy) * k;
            double v = Math.Sqrt(vx * vx + vy * vy);
            if (v > SpeedCap) { double f = SpeedCap / v; vx *= f; vy *= f; v = SpeedCap; }
            BodyX += vx * dt;
            BodyY += vy * dt;

            if (v > 6)
            {
                double want = Math.Atan2(vy, vx);
                double diff = want - Heading;
                while (diff > Math.PI) diff -= Math.PI * 2;
                while (diff < -Math.PI) diff += Math.PI * 2;
                Heading += diff * Math.Min(1.0, 8.0 * dt);
            }
            UpdateLegs(dt);
        }

        private void UpdateLegs(double dt)
        {
            int stepping = -1;
            for (int leg = 0; leg < LegCount; leg++)
            {
                if (steppingFlag[leg]) { stepping = leg; break; }
            }
            if (stepping >= 0)
            {
                int b = stepping * LegStride;
                stepT[stepping] += dt / Math.Max(0.02, StepDuration);
                if (stepT[stepping] >= 1)
                {
                    stepT[stepping] = 1;
                    steppingFlag[stepping] = false;
                    Legs[b + 4] = stepToX[stepping];
                    Legs[b + 5] = stepToY[stepping];
                    Legs[b + 6] = 0;
                    Legs[b + 7] = Heading;      // the toe points the way we walk
                    lastGroup = GroupOf(stepping);
                    StepCounters[stepping]++;
                }
                else
                {
                    double t = stepT[stepping];
                    double ease = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
                    Legs[b + 4] = stepFromX[stepping] + (stepToX[stepping] - stepFromX[stepping]) * ease;
                    Legs[b + 5] = stepFromY[stepping] + (stepToY[stepping] - stepFromY[stepping]) * ease;
                    Legs[b + 6] = Math.Sin(Math.PI * t) * 6;
                }
                return; // one leg in the air at a time
            }

            int best = -1;
            double bestScore = 0, idealX = 0, idealY = 0;
            for (int leg = 0; leg < LegCount; leg++)
            {
                double ix, iy;
                IdealFoot(leg, out ix, out iy);
                int b = leg * LegStride;
                double ex = ix - Legs[b + 4], ey = iy - Legs[b + 5];
                double err = Math.Sqrt(ex * ex + ey * ey);
                double bias = GroupOf(leg) != lastGroup ? 1.15 : 1.0;
                double score = err * bias;
                if (err > StepTrigger && score > bestScore) { bestScore = score; best = leg; idealX = ix; idealY = iy; }
            }
            if (best < 0) return;

            int bb = best * LegStride;
            stepFromX[best] = Legs[bb + 4];
            stepFromY[best] = Legs[bb + 5];
            stepToX[best] = idealX;
            stepToY[best] = idealY;
            stepT[best] = 0;
            steppingFlag[best] = true;
        }

        private static int GroupOf(int leg)
        {
            return ((leg % 4) + (leg / 4)) % 2;
        }

        private void IdealFoot(int leg, out double x, out double y)
        {
            int side = leg / 4;
            int i = leg % 4;
            double s = side == 0 ? 1.0 : -1.0;
            double c = Math.Cos(Heading), sn = Math.Sin(Heading);
            double rx = RestLocalX[i];
            double ry = s * RestLocalY[i];
            x = BodyX + rx * c - ry * sn;
            y = BodyY + rx * sn + ry * c;
        }

        private void HipWorld(int leg, out double x, out double y)
        {
            int side = leg / 4;
            int i = leg % 4;
            double s = side == 0 ? 1.0 : -1.0;
            double c = Math.Cos(Heading), sn = Math.Sin(Heading);
            double rx = HipLocalX[i];
            double ry = s * 5.5;
            x = BodyX + rx * c - ry * sn;
            y = BodyY + rx * sn + ry * c;
        }

        private static void SolveIK(double hipX, double hipY, double footX, double footY, double l1, double l2,
                                   double outX, double outY, out double kneeX, out double kneeY,
                                   out double clampX, out double clampY)
        {
            double dx = footX - hipX, dy = footY - hipY;
            double d = Math.Sqrt(dx * dx + dy * dy);
            double reach = (l1 + l2) * 0.999;
            if (d <= 0.0001) { d = 0.0001; dx = 0.0001; dy = 0; }
            if (d > reach) { double k = reach / d; dx *= k; dy *= k; d = reach; }
            double ux = dx / d, uy = dy / d;
            double a = (l1 * l1 - l2 * l2 + d * d) / (2 * d);
            double h = Math.Sqrt(Math.Max(0, l1 * l1 - a * a));
            double bx = hipX + ux * a, by = hipY + uy * a;
            double k1x = bx - uy * h, k1y = by + ux * h;
            double k2x = bx + uy * h, k2y = by - ux * h;
            double d1 = (k1x - outX) * (k1x - outX) + (k1y - outY) * (k1y - outY);
            double d2 = (k2x - outX) * (k2x - outX) + (k2y - outY) * (k2y - outY);
            if (d1 >= d2) { kneeX = k1x; kneeY = k1y; } else { kneeX = k2x; kneeY = k2y; }
            clampX = hipX + dx;
            clampY = hipY + dy;
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            if (!Active) return;
            double s = Scale > 0 ? Scale : 1.0;
            dc.PushTransform(new ScaleTransform(s, s));
            dc.PushTransform(new TranslateTransform(-OriginX, -OriginY));

            DrawHighlights(dc);
            DrawGlitches(dc);
            DrawSpider(dc);

            dc.Pop();
            dc.Pop();
        }

        private void DrawHighlights(DrawingContext dc)
        {
            double[] h = Highlights;
            if (h == null) return;
            for (int i = 0; i + 3 < h.Length; i += 4)
            {
                if (h[i + 2] < 2 || h[i + 3] < 2) continue;
                dc.DrawRectangle(HighlightBrush, HighlightPen, new Rect(h[i], h[i + 1], h[i + 2], h[i + 3]));
            }
        }

        private void DrawGlitches(DrawingContext dc)
        {
            double[] g = Glitches;
            if (g == null || g.Length == 0) return;
            double pixelsPerDip = 1.0;
            try { pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip; } catch (Exception) { }

            for (int i = 0; i + 5 < g.Length; i += GlitchStride)
            {
                double x = g[i], y = g[i + 1], w = g[i + 2], h = g[i + 3];
                int kind = (int)g[i + 4];
                double rotation = g[i + 5];
                string text = (GlitchText != null && (i / GlitchStride) < GlitchText.Length) ? GlitchText[i / GlitchStride] : null;
                if (w < 2 || h < 2) continue;

                if (kind == 0) // blue highlight box
                {
                    dc.DrawRectangle(GlitchBox, null, new Rect(x, y, w, h));
                }
                else if (kind == 1) // monospace overlay
                {
                    dc.DrawRectangle(GlitchBox, null, new Rect(x, y, w, h));
                    if (!string.IsNullOrEmpty(text)) DrawOverlayText(dc, text, x, y, h, MonoBoldTypeface, pixelsPerDip);
                }
                else if (kind == 2) // blue outline
                {
                    if (!string.IsNullOrEmpty(text))
                    {
                        DrawOverlayText(dc, text, x - 1, y - 1, h, MonoTypeface, pixelsPerDip);
                        DrawOverlayText(dc, text, x + 1, y + 1, h, MonoTypeface, pixelsPerDip);
                    }
                }
                else if (kind == 3) // slight rotation
                {
                    dc.PushTransform(new RotateTransform(rotation, x + w / 2, y + h / 2));
                    dc.DrawRectangle(GlitchBox, null, new Rect(x, y, w, h));
                    if (!string.IsNullOrEmpty(text)) DrawOverlayText(dc, text, x, y, h, MonoTypeface, pixelsPerDip);
                    dc.Pop();
                }
                else if (kind == 4) // letter spacing
                {
                    if (!string.IsNullOrEmpty(text))
                    {
                        double cx = x;
                        for (int c = 0; c < text.Length; c++)
                        {
                            FormattedText ft = MakeText(text.Substring(c, 1), MonoTypeface, h * 0.8, GlitchTextBrush, pixelsPerDip);
                            dc.DrawText(ft, new Point(cx, y + h / 2 - ft.Height / 2));
                            cx += ft.Width + h * 0.25;
                        }
                    }
                }
                else if (kind == 5) // ghost echo
                {
                    if (!string.IsNullOrEmpty(text))
                    {
                        DrawOverlayText(dc, text, x + 2.5, y + 1.5, h, MonoTypeface, pixelsPerDip);
                        DrawOverlayText(dc, text, x, y, h, MonoBoldTypeface, pixelsPerDip);
                    }
                }
            }
        }

        private static FormattedText MakeText(string text, Typeface typeface, double size, Brush brush, double pixelsPerDip)
        {
            return new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, size, brush, pixelsPerDip);
        }

        private static void DrawOverlayText(DrawingContext dc, string text, double x, double y, double lineHeight, Typeface typeface, double pixelsPerDip)
        {
            FormattedText ft = MakeText(text, typeface, lineHeight * 0.72, GlitchTextBrush, pixelsPerDip);
            dc.DrawText(ft, new Point(x, y + lineHeight / 2 - ft.Height / 2));
        }

        private void DrawSpider(DrawingContext dc)
        {
            for (int leg = 0; leg < LegCount; leg++)
            {
                int b = leg * LegStride;
                double hipX, hipY, kneeX, kneeY, clampX, clampY;
                HipWorld(leg, out hipX, out hipY);
                double lift = Legs[b + 6];
                double footX = Legs[b + 4];
                double footY = Legs[b + 5];
                if (lift > 0)
                {
                    double ddx = hipX - footX, ddy = hipY - footY;
                    double dl = Math.Sqrt(ddx * ddx + ddy * ddy);
                    if (dl < 1) dl = 1;    // reads as the foot leaving the ground
                    footX += ddx / dl * lift;
                    footY += ddy / dl * lift;
                }
                int i = leg % 4;
                SolveIK(hipX, hipY, footX, footY, BoneL1[i], BoneL2[i], BodyX, BodyY, out kneeX, out kneeY, out clampX, out clampY);

                StreamGeometry geo = new StreamGeometry();
                using (StreamGeometryContext ctx = geo.Open())
                {
                    ctx.BeginFigure(new Point(hipX, hipY), false, false);
                    ctx.LineTo(new Point(kneeX, kneeY), true, false);
                    ctx.LineTo(new Point(footX, footY), true, false);
                }
                geo.Freeze();
                dc.DrawGeometry(null, lift > 0 ? LegPenLifted : LegPen, geo);

                dc.DrawEllipse(JointBrush, null, new Point(kneeX, kneeY), 2.6, 2.6);
                dc.DrawEllipse(JointBrush, null, new Point(hipX, hipY), 2.0, 2.0);

                if (lift <= 0)
                {
                    double toe = Legs[b + 7];
                    StreamGeometry toeGeo = new StreamGeometry();
                    using (StreamGeometryContext ctx = toeGeo.Open())
                    {
                        ctx.BeginFigure(new Point(Legs[b + 4], Legs[b + 5]), false, false);
                        ctx.LineTo(new Point(Legs[b + 4] + Math.Cos(toe) * 5, Legs[b + 5] + Math.Sin(toe) * 5), true, false);
                    }
                    toeGeo.Freeze();
                    dc.DrawGeometry(null, ToePen, toeGeo);
                }

                Legs[b] = hipX;
                Legs[b + 1] = hipY;
                Legs[b + 2] = kneeX;
                Legs[b + 3] = kneeY;
            }

            dc.PushTransform(new TranslateTransform(BodyX, BodyY));
            dc.PushTransform(new RotateTransform(Heading * 180.0 / Math.PI));
            dc.DrawEllipse(BodyFill, BodyPen, new Point(-11, 0), 9.5, 7.5);
            dc.DrawRoundedRectangle(BodyFill, BodyPen, new Rect(-8, -5, 15, 10), 3.5, 3.5);
            dc.DrawEllipse(BodyFill, BodyPen, new Point(9, 0), 5, 5);
            dc.DrawEllipse(EyeWhite, null, new Point(10, -2.4), 1.9, 1.9);
            dc.DrawEllipse(EyeWhite, null, new Point(10, 2.4), 1.9, 1.9);
            dc.DrawEllipse(EyeDark, null, new Point(10.8, -2.4), 0.85, 0.85);
            dc.DrawEllipse(EyeDark, null, new Point(10.8, 2.4), 0.85, 0.85);
            dc.Pop();
            dc.Pop();
        }
    }
}
