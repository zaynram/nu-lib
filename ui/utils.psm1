# /work/dev/nu/ui/utils.psm1
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
  param(
    [string]$Match = 'Debian',
    [bool]$PrimaryDisplay = $false
  )
  begin {
    [object]$bounds = [System.Windows.Forms.Screen]::AllScreens |
      Select-Object -Property DeviceName, Bounds, Primary |
      Where-Object -Property Primary -EQ $PrimaryDisplay |
      Select-Object -ExpandProperty Bounds
  }
  process {
    Get-Process msrdc -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$Match*" } |
    ForEach-Object {
      [Win]::ShowWindow($_.MainWindowHandle, 4)
      [Win]::MoveWindow(
        $_.MainWindowHandle,
        $bounds.X,
        $bounds.Y,
        $bounds.Width,
        $bounds.Height,
        $true
      )
      [Win]::ShowWindow($_.MainWindowHandle, 3)
    }
  }
}

Export-ModuleMember -Function Set-WSLgFullscreen
