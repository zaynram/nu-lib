# ~/library/nushell/_internal/disp/utils.psm1
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")]
  public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

Add-Type -AssemblyName System.Windows.Forms

function Set-WSLgFullscreen {
  param([string]$Match = 'Debian')
    Get-Process msrdc -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$Match*" } |
    ForEach-Object { [Win]::ShowWindow($_.MainWindowHandle, 3) }
}

Export-ModuleMember -Function Set-WSLgFullscreen
