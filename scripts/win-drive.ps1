# Drives the Windows app window by hand for end-to-end checks: clicks, typed
# text, keys and screenshots of the window, in physical pixels relative to the
# window's top-left corner. One action per call:
#
#   powershell -ExecutionPolicy Bypass -File scripts\win-drive.ps1 -Action launch -Exe app\build\windows\x64\runner\Release\family_messenger_e2e.exe
#   powershell -File scripts\win-drive.ps1 -Action rect                 # window position and size
#   powershell -File scripts\win-drive.ps1 -Action click -X 400 -Y 300  # relative to the window
#   powershell -File scripts\win-drive.ps1 -Action type -Text "hello"   # into the focused field
#   powershell -File scripts\win-drive.ps1 -Action key -Text "{ENTER}"  # SendKeys syntax
#   powershell -File scripts\win-drive.ps1 -Action shot -File out.png   # screenshot of the window
param(
  [ValidateSet('launch', 'rect', 'click', 'type', 'key', 'shot', 'peek', 'close')][string]$Action = 'rect',
  [string]$Exe,
  [string]$Process = 'family_messenger_e2e',
  [int]$X,
  [int]$Y,
  [string]$Text,
  [string]$File
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinDrive {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  public static void TypeText(string text) {
    foreach (char c in text) {
      var down = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = c, dwFlags = 4 } };
      var up = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = c, dwFlags = 4 | 2 } };
      SendInput(2, new INPUT[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(8);
    }
  }
}
"@
[void][WinDrive]::SetProcessDPIAware()

function Get-AppWindow {
  $p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "no window for process $Process" }
  $r = New-Object WinDrive+RECT
  [void][WinDrive]::GetWindowRect($p.MainWindowHandle, [ref]$r)
  return @{ Handle = $p.MainWindowHandle; Left = $r.Left; Top = $r.Top; Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
}

# Brings the app to the front and refuses to continue when that fails, so
# that clicks and keystrokes never land in somebody else's window.
function Focus-AppWindow($w) {
  [void][WinDrive]::ShowWindow($w.Handle, 9) # restore if minimised
  foreach ($attempt in 1..3) {
    if ($attempt -gt 1) {
      # Windows lets a background process take the foreground after a key press.
      [WinDrive]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
      [WinDrive]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    }
    [void][WinDrive]::SetForegroundWindow($w.Handle)
    Start-Sleep -Milliseconds 200
    if ([WinDrive]::GetForegroundWindow() -eq $w.Handle) { return }
  }
  throw "the app window is not in the foreground; nothing was sent"
}

switch ($Action) {
  'launch' {
    if (-not $Exe) { throw '-Exe is required' }
    $proc = Start-Process -FilePath (Resolve-Path $Exe) -PassThru
    foreach ($i in 1..60) { Start-Sleep -Milliseconds 500; $proc.Refresh(); if ($proc.MainWindowHandle -ne 0) { break } }
    $w = Get-AppWindow
    "launched pid=$($proc.Id) window=$($w.Left),$($w.Top) $($w.Width)x$($w.Height)"
  }
  'rect' { $w = Get-AppWindow; "$($w.Left),$($w.Top) $($w.Width)x$($w.Height)" }
  'click' {
    $w = Get-AppWindow
    Focus-AppWindow $w
    [void][WinDrive]::SetCursorPos($w.Left + $X, $w.Top + $Y)
    Start-Sleep -Milliseconds 80
    [WinDrive]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WinDrive]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    "clicked $X,$Y"
  }
  'type' { $w = Get-AppWindow; Focus-AppWindow $w; [WinDrive]::TypeText($Text); "typed $($Text.Length) chars" }
  'key' { $w = Get-AppWindow; Focus-AppWindow $w; [System.Windows.Forms.SendKeys]::SendWait($Text); "sent $Text" }
  'shot' {
    if (-not $File) { throw '-File is required' }
    $w = Get-AppWindow
    Focus-AppWindow $w
    Start-Sleep -Milliseconds 250
    $bmp = New-Object System.Drawing.Bitmap $w.Width, $w.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($w.Left, $w.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($File, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "saved $File ($($w.Width)x$($w.Height))"
  }
  'peek' {
    # A screenshot without touching the focus (for windows driven by an
    # integration test): PrintWindow renders the window itself, even when
    # other windows cover it.
    if (-not $File) { throw '-File is required' }
    $w = Get-AppWindow
    $bmp = New-Object System.Drawing.Bitmap $w.Width, $w.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][WinDrive]::PrintWindow($w.Handle, $hdc, 2) # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($File, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "saved $File"
  }
  'close' { Get-Process -Name $Process -ErrorAction SilentlyContinue | Stop-Process -Force; 'closed' }
}
