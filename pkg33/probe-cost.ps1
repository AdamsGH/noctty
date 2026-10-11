#requires -Version 7.0
# Cost of probeNativeCapability's four LoadLibrary/GetProcAddress/FreeLibrary pairs in a fresh process.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class P {
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi)] static extern IntPtr LoadLibraryA(string n);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr m, string n);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr m);
    public static double[] Run() {
        var names = new[] { "d3d11.dll","dcomp.dll","d2d1.dll","dwrite.dll" };
        var syms = new[] { "D3D11CreateDevice","DCompositionCreateDevice","D2D1CreateFactory","DWriteCreateFactory" };
        var times = new double[names.Length + 1]; double total = 0;
        for (int i = 0; i < names.Length; i++) {
            var sw = Stopwatch.StartNew();
            var m = LoadLibraryA(names[i]); if (m != IntPtr.Zero) { GetProcAddress(m, syms[i]); FreeLibrary(m); }
            sw.Stop(); times[i] = sw.Elapsed.TotalMilliseconds; total += times[i];
        }
        times[names.Length] = total; return times;
    }
}
'@
$t = [P]::Run()
('{0:N1} {1:N1} {2:N1} {3:N1} total {4:N1}' -f $t[0], $t[1], $t[2], $t[3], $t[4])
