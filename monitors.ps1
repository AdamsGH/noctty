Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Mon {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }
    public delegate bool MonEnum(IntPtr h, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonEnum cb, IntPtr p);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    public static List<string> List() {
        var l = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref Rect r, IntPtr p) => {
            uint x, y; GetDpiForMonitor(h, 0, out x, out y);
            l.Add(string.Format("{0},{1} {2}x{3} dpi={4}", r.L, r.T, r.R - r.L, r.B - r.T, x)); return true; }, IntPtr.Zero);
        return l;
    }
}
'@
[void][Mon]::SetThreadDpiAwarenessContext([IntPtr](-4))
[Mon]::List()
