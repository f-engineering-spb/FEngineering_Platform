param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [Parameter(Mandatory = $false)][string]$OutputPath = "",
  [Parameter(Mandatory = $false)][string]$FallbackCachePath = "",
  [Parameter(Mandatory = $false)][string]$PythonExe = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
  throw "DWG-              : $InputPath"
}

#                          :            ,          ,            .pdf
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = [System.IO.Path]::ChangeExtension($InputPath, ".pdf")
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
  try {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  } catch {}
}

# 1. ПРИОРИТЕТ — штатный обход листов через AutoCAD COM (многостраничный экспорт).
# Бывший безусловный вызов Invoke-NativeDwgPdfExport (_.-EXPORT _PDF _E, только
# Model space, 1 страница) здесь ОТКЛЮЧЁН: он перехватывал выполнение до COM-печати
# листов и давал одностраничный пустой PDF вместо всех листов чертежа.
# Native-экспорт оставлен только как крайний fallback (см. ниже, после COM).

# Python для склейки страниц: сервер передаёт -PythonExe, для ручного CLI-автоопределение.
if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  foreach ($cmd in @("python", "pythonw", "py")) {
    try {
      $found = (Get-Command $cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
      if ($found) { $PythonExe = $found; break }
    } catch {}
  }
}
if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  throw "Python interpreter not found: pass -PythonExe or install Python."
}

if (-not ([System.Management.Automation.PSTypeName]'LauncherMessageFilter').Type) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[ComImport(), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("00000016-0000-0000-C000-000000000046")]
public interface IOleMessageFilter
{
    [PreserveSig] int HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo);
    [PreserveSig] int RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType);
    [PreserveSig] int MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType);
}

public class LauncherMessageFilter : IOleMessageFilter
{
    [DllImport("ole32.dll")] private static extern int CoRegisterMessageFilter(IOleMessageFilter newFilter, out IOleMessageFilter oldFilter);
    public static void Register() {
        IOleMessageFilter newFilter = new LauncherMessageFilter();
        IOleMessageFilter oldFilter = null;
        CoRegisterMessageFilter(newFilter, out oldFilter);
    }
    public static void Revoke() {
        IOleMessageFilter oldFilter = null;
        CoRegisterMessageFilter(null, out oldFilter);
    }
    public int HandleInComingCall(int dwCallType, IntPtr hTaskCaller, int dwTickCount, IntPtr lpInterfaceInfo) { return 0; }
    public int RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType) {
        if (dwRejectType == 2) return 100;
        return -1;
    }
    public int MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType) { return 2; }
}
"@
}
[LauncherMessageFilter]::Register()

function Set-DocOptimizationSettings($doc) {
  if (-not $doc) { return }
  try { $doc.SetVariable("LAYOUTREGENCTL", 2) } catch {}
  try { $doc.SetVariable("REGENMODE", 0) } catch {}
  try { $doc.SetVariable("BACKGROUNDPLOT", 0) } catch {}
  try { $doc.SetVariable("EXPERT", 5) } catch {}
  try { $doc.SetVariable("ONLINESTATUS", 0) } catch {}
  try { $doc.SetVariable("WSCOMMNTR", 0) } catch {}
  try { $doc.SetVariable("VIEWDOC", 0) } catch {}
  try { $doc.SetVariable("RASTERPREVIEW", 0) } catch {}
  try { $doc.SendCommand("(setvar `"VIEWDOC`" 0) ") } catch {}
  try { $doc.SendCommand("(setvar `"RASTERPREVIEW`" 0) ") } catch {}
}

# SINGLE-INSTANCE: межпроцессная блокировка — запросы печати разных DWG
# выполняются последовательно через одну сессию, не порождая дубли acad.exe.
# Имя Mutex глобальное, чтобы сериализовать и параллельные powershell-процессы.
$cadMutex = $null
$cadMutexOwned = $false
try {
  $cadMutex = New-Object System.Threading.Mutex($false, "Global\FEngineering_AutoCAD_Render")
  $cadMutexOwned = $cadMutex.WaitOne([TimeSpan]::FromMinutes(10))
  if (-not $cadMutexOwned) { throw "Не удалось захватить Mutex AutoCAD-рендера за 10 минут." }
} catch {
  throw "AutoCAD single-instance lock failed: $_"
}

#               CAD       COM-
$comProgIds = @(
  "AutoCAD.Application.25",
  "AutoCAD.Application.24.3",
  "AutoCAD.Application.24.2",
  "AutoCAD.Application.24.1",
  "AutoCAD.Application.24.0",
  "AutoCAD.Application.24",
  "AutoCAD.Application.23.1",
  "AutoCAD.Application.23",
  "AutoCAD.Application.22",
  "AutoCAD.Application"
)

# SINGLE-INSTANCE: строгое переиспользование уже запущенной сессии.
# Сначала пробуем подключиться к активному экземпляру (без нового процесса).
# Если в системе уже есть запущенные процессы acad.exe, но подключиться к ним через COM
# не удается — это зависшие зомби-процессы от прошлых сбоев: принудительно гасим их перед
# созданием нового экземпляра, чтобы НЕ плодить параллельные процессы и не исчерпывать RAM!
$app = $null
$usedProgId = ""
$ownedSession = $false
$reusedSession = $false

$existingAcad = @(Get-Process -Name 'acad' -ErrorAction SilentlyContinue)
if ($existingAcad.Count -gt 0) {
  Write-Output ("CHECK: Detected {0} running acad.exe process(es)." -f $existingAcad.Count)
  foreach ($progId in $comProgIds) {
    try {
      $candidate = [System.Runtime.InteropServices.Marshal]::GetActiveObject($progId)
      if ($candidate) {
        $app = $candidate
        $usedProgId = $progId
        $reusedSession = $true
        $ownedSession = $false
        Write-Output ("REUSE active AutoCAD session progId={0} (no new acad.exe)" -f $progId)
        break
      }
    } catch {}
  }
  if (-not $app) {
    Write-Output "AutoCAD process(es) exist but are unresponsive to COM. Terminating zombie instances before creating new one..."
    foreach ($p in $existingAcad) {
      try {
        if ($p.MainWindowHandle -eq 0 -or [string]::IsNullOrWhiteSpace($p.MainWindowTitle)) {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
      } catch {}
    }
    Start-Sleep -Milliseconds 500
  }
}

if (-not $app) {
  foreach ($progId in $comProgIds) {
    try {
      $app = New-Object -ComObject $progId -ErrorAction Stop
      if ($app) {
        $usedProgId = $progId
        $ownedSession = $true
        $reusedSession = $false
        Write-Output ("CREATE new AutoCAD session progId={0} (none was running)" -f $progId)
        break
      }
    } catch {}
  }
}

if (-not $app) {
  throw "                          AutoCAD       COM (         : $($comProgIds -join ', '))."
}

if (-not ([System.Management.Automation.PSTypeName]'LauncherWin32').Type) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class LauncherWin32 {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@
}

$cadPid = 0
try {
  $hwnd = [IntPtr]::new([long]$app.HWND)
  [uint32]$pidOut = 0
  [void][LauncherWin32]::GetWindowThreadProcessId($hwnd, [ref]$pidOut)
  if ($pidOut -gt 0) { $cadPid = [int]$pidOut }
} catch {}

$app.Visible = $false
$document = $null

# RESUME: детерминированная рабочая папка на основе MD5-хэша пути файла.
# Повторный запуск подхватывает уже отпечатанные page_*.pdf и допечатывает остальное.
$fileId = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($InputPath))).Replace("-","").Substring(0,12)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "FEng_dwg_$fileId"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
  #                   '             '
  $document = $app.Documents.Open($InputPath, $true)
  # BENCH-WINNER (5.1s): freeze screen regen during batch plot, no per-sheet redraws.
  $document.SetVariable("LAYOUTREGENCTL", 2)
  $document.SetVariable("REGENMODE", 0)
  $document.SetVariable("BACKGROUNDPLOT", 0)
  $document.SetVariable("EXPERT", 5)
  # SILENT-NET: cut Autodesk online traffic so Proxifier never sees it.
  # Wrapped: unknown names must never abort a render (see ee84966).
  try { $document.SetVariable("ONLINESTATUS", 0) } catch {}
  try { $document.SetVariable("WSCOMMNTR", 0) } catch {}
  # NO-VIEWER (жесткий запрет автооткрытия PDF просмотрщиком):
  # По умолчанию в Autodesk PC3-драйверах (DWG To PDF.pc3, AutoCAD PDF.pc3) параметр
  # View_New_File=TRUE, из-за чего pdfplot16.hdi вызывает ShellExecute (открывает Edge/Acrobat).
  # Программно патчим все PC3 в папке Plotters AutoCAD, выставляя View_New_File=FALSE,
  # и создаем/обновляем специализированный silent-драйвер FEng_Silent_DWG_To_PDF.pc3.
  try {
    $plotterDirs = @()
    if ($app -and $app.Preferences -and $app.Preferences.Files) {
      $cadPlotterPath = $app.Preferences.Files.PrinterConfigPath
      if ($cadPlotterPath -and (Test-Path -LiteralPath $cadPlotterPath)) {
        $plotterDirs += $cadPlotterPath
      }
    }
    $patchScript = Join-Path $PSScriptRoot "patch_silent_plotters.py"
    if ((Test-Path -LiteralPath $patchScript) -and (-not [string]::IsNullOrWhiteSpace($PythonExe)) -and (Test-Path -LiteralPath $PythonExe)) {
      & $PythonExe $patchScript $plotterDirs | Out-Null
    }
  } catch {
    Write-Output ("DEBUG: silent plotter patch exception: $_")
  }

  try { $document.Plot.QuietErrorMode = $true } catch {}
  try { $document.Plot.BatchPlotProgress = $false } catch {}

  #                 (Layouts)
  $rawCandidateLayouts = @($document.Layouts | Where-Object { -not $_.ModelType } | Sort-Object TabOrder)
  $layoutEntries = @()
  foreach ($cl in $rawCandidateLayouts) {
    try {
      if ($cl.Block.Count -gt 1) {
        $layoutEntries += [PSCustomObject]@{
          Name = [string]$cl.Name
          TabOrder = [int]$cl.TabOrder
        }
      }
    } catch {}
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($cl) | Out-Null } catch {}
  }

  $pagePdfPaths = [System.Collections.Generic.List[string]]::new()
  Write-Output ("START layouts_total={0} layouts_nonempty={1} input={2}" -f $rawCandidateLayouts.Count, $layoutEntries.Count, $InputPath)

  $cacheDir = ".\cache"
  if (-not (Test-Path -LiteralPath $cacheDir)) {
    try { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null } catch {}
  }
  $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)

  if ($layoutEntries.Count -gt 0) {
    foreach ($entry in $layoutEntries) {
      $layoutName = $entry.Name
      $tabOrder = $entry.TabOrder
      $pageFile = Join-Path $tempDir ("page_{0:D4}.pdf" -f $tabOrder)
      $sheetPngPath = Join-Path $cacheDir ("{0}_sheet_{1:D2}.png" -f $inputBaseName, $tabOrder)

      # RESUME: готовая страница из прошлого запуска — пропускаем печать, берём из кэша.
      if ((Test-Path -LiteralPath $pageFile) -and (Get-Item -LiteralPath $pageFile).Length -gt 1024) {
        Write-Output ("PAGE_EXISTS: {0} skipping render, using cached page" -f $tabOrder)
        $pagePdfPaths.Add($pageFile)
        continue
      }

      $layout = $null
      try {
        $layout = $document.Layouts.Item($layoutName)
      } catch {
        Write-Output ("DEBUG: Could not access layout '{0}': $_" -f $layoutName)
        continue
      }

      $document.ActiveLayout = $layout

      # ENSURE SILENT PLOTTER: гарантируем использование плоттера с View_New_File=FALSE
      $devices = @($layout.GetPlotDeviceNames())
      $preferredSilentDevices = @(
        "FEng_Silent_DWG_To_PDF.pc3",
        "DWG To PDF.pc3",
        "AutoCAD PDF (General Documentation).pc3",
        "AutoCAD PDF (High Quality Print).pc3",
        "AutoCAD PDF (Smallest File).pc3",
        "AutoCAD PDF (Web and Mobile).pc3"
      )
      $chosenDevice = $null
      foreach ($dev in $preferredSilentDevices) {
        if ($devices -contains $dev) {
          $chosenDevice = $dev
          break
        }
      }
      if ($chosenDevice -and ($layout.ConfigName -ne $chosenDevice)) {
        try {
          $layout.ConfigName = $chosenDevice
          $layout.RefreshPlotDeviceInfo()
        } catch {
          Write-Output ("DEBUG: ConfigName {0} rejected, keeping stored device" -f $chosenDevice)
        }
      }

      #                       
      $availableMedia = @($layout.GetCanonicalMediaNames())
      if ($availableMedia.Count -gt 0) {
        $curMedia = $layout.CanonicalMediaName
        if (-not ($curMedia -and ($availableMedia -contains $curMedia))) {
          $matched = $null
          foreach ($code in @("A0", "A1", "A2", "A3", "A4")) {
            if ($curMedia -match $code) {
              $matched = @($availableMedia | Where-Object { $_ -match $code } | Select-Object -First 1)
              if ($matched.Count -gt 0) { break }
            }
          }
          if ($matched -and $matched.Count -gt 0) {
            try { $layout.CanonicalMediaName = $matched[0] } catch {
              Write-Output "DEBUG: CanonicalMediaName rejected, keeping stored media"
            }
          } elseif ($availableMedia -contains "ISO_full_bleed_A3_(420.00_x_297.00_MM)") {
            try { $layout.CanonicalMediaName = "ISO_full_bleed_A3_(420.00_x_297.00_MM)" } catch {
              Write-Output "DEBUG: CanonicalMediaName rejected, keeping stored media"
            }
          } else {
            try { $layout.CanonicalMediaName = $availableMedia[0] } catch {
              Write-Output "DEBUG: CanonicalMediaName rejected, keeping stored media"
            }
          }
        }
      }

      try {
        $layout.PlotType = 4 # acLayout
      } catch {
        # Если плоттер отвергает acLayout (4), продолжаем с текущим типом листа
        Write-Output "DEBUG: PlotType 4 rejected, using default layout plot type"
      }
      $layout.PlotWithLineweights = $true
      $layout.PlotWithPlotStyles = $true
      try { $document.Plot.QuietErrorMode = $true } catch {}
      try { $document.Plot.BatchPlotProgress = $false } catch {}

      if ($document.Plot.PlotToFile($pageFile)) {
        if ((Test-Path -LiteralPath $pageFile) -and (Get-Item -LiteralPath $pageFile).Length -gt 1024) {
          $pagePdfPaths.Add($pageFile)

          # 2. ПОЛИСТНО: СРАЗУ сохраняем PNG на диск в .\cache\
          try {
            if (-not [string]::IsNullOrWhiteSpace($PythonExe) -and (Test-Path -LiteralPath $PythonExe)) {
              & $PythonExe -c "import sys, fitz; doc = fitz.open(sys.argv[1]); page = doc.load_page(0); page.get_pixmap(dpi=150).save(sys.argv[2]); doc.close()" "$pageFile" "$sheetPngPath"
            }
          } catch {
            Write-Output ("DEBUG: failed to render sheet PNG: $_")
          }

          Write-Output ("PROGRESS layout={0} done={1}/{2} file={3} png={4}" -f $tabOrder, $pagePdfPaths.Count, $layoutEntries.Count, [System.IO.Path]::GetFileName($pageFile), [System.IO.Path]::GetFileName($sheetPngPath))
        }
      }

      # СБРОС COM-ОБЪЕКТА ЛИСТА И ПАМЯТИ ПОСЛЕ КАЖДОГО ЛИСТА
      try {
        if ($layout) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($layout) | Out-Null }
      } catch {}
      $layout = $null
      [System.GC]::Collect()
      [System.GC]::WaitForPendingFinalizers()

      # 3. ЖЕСТКИЙ КОНТРОЛЬ ПАМЯТИ: если процесс acad.exe превышает 2.5 ГБ RAM — перезапуск!
      if ($cadPid -and $cadPid -gt 0) {
        try {
          $procCheck = Get-Process -Id $cadPid -ErrorAction SilentlyContinue
          if ($procCheck) {
            $wsMB = [math]::Round($procCheck.WorkingSet64 / 1MB, 1)
            $privMB = [math]::Round($procCheck.PrivateMemorySize64 / 1MB, 1)
            Write-Output ("CAD MEM CHECK layout={0}: RAM={1} MB, Private={2} MB" -f $tabOrder, $wsMB, $privMB)
            if ($wsMB -gt 2500 -or $privMB -gt 2500) {
              Write-Output ("WARNING: acad.exe (PID {0}) exceeded 2.5 GB memory limit (RAM={1}MB, Private={2}MB)! Restarting AutoCAD to prevent memory leak and swap freeze..." -f $cadPid, $wsMB, $privMB)

              try { if ($document) { $document.Close($false) } } catch {}
              try { if ($document) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($document) | Out-Null } } catch {}
              $document = $null

              if ($app) {
                try { $app.Quit() } catch {}
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null } catch {}
                $app = $null
              }

              try {
                $oldP = Get-Process -Id $cadPid -ErrorAction SilentlyContinue
                if ($oldP -and -not $oldP.HasExited) {
                  Stop-Process -Id $cadPid -Force -ErrorAction SilentlyContinue
                }
              } catch {}

              [System.GC]::Collect()
              [System.GC]::WaitForPendingFinalizers()
              Start-Sleep -Seconds 1

              # Пересоздаем сессию AutoCAD
              $app = New-Object -ComObject $usedProgId -ErrorAction Stop
              $ownedSession = $true
              $reusedSession = $false
              $app.Visible = $false

              try {
                $hwnd = [IntPtr]::new([long]$app.HWND)
                [uint32]$newPid = 0
                [void][LauncherWin32]::GetWindowThreadProcessId($hwnd, [ref]$newPid)
                if ($newPid -gt 0) { $cadPid = [int]$newPid }
              } catch {}
              Write-Output ("AutoCAD session refreshed successfully with PID {0}. Resuming..." -f $cadPid)

              $document = $app.Documents.Open($InputPath, $true)
              Set-DocOptimizationSettings $document
            }
          }
        } catch {
          Write-Output ("DEBUG: Memory check error: $_")
        }
      }
    }
  }

  #                                           (Model Space)
  if ($pagePdfPaths.Count -eq 0) {
    $layout = $document.ModelSpace.Layout
    $devices = @($layout.GetPlotDeviceNames())
    $preferredSilentDevices = @(
      "FEng_Silent_DWG_To_PDF.pc3",
      "DWG To PDF.pc3",
      "AutoCAD PDF (General Documentation).pc3",
      "AutoCAD PDF (High Quality Print).pc3",
      "AutoCAD PDF (Smallest File).pc3",
      "AutoCAD PDF (Web and Mobile).pc3"
    )
    $chosenDevice = $null
    foreach ($dev in $preferredSilentDevices) {
      if ($devices -contains $dev) {
        $chosenDevice = $dev
        break
      }
    }
    if ($chosenDevice -and ($layout.ConfigName -ne $chosenDevice)) {
      try {
        $layout.ConfigName = $chosenDevice
        $layout.RefreshPlotDeviceInfo()
      } catch {
        Write-Output ("DEBUG: model ConfigName {0} rejected, keeping stored device" -f $chosenDevice)
      }
    }
    $allMedia = @($layout.GetCanonicalMediaNames())
    $a0 = @($allMedia | Where-Object { $_ -match "A0" } | Select-Object -First 1)
    if ($a0.Count -gt 0) {
      try { $layout.CanonicalMediaName = $a0[0] } catch {
        Write-Output "DEBUG: model CanonicalMediaName rejected, keeping stored media"
      }
    } elseif ($allMedia.Count -gt 0) {
      try { $layout.CanonicalMediaName = $allMedia[0] } catch {
        Write-Output "DEBUG: model CanonicalMediaName rejected, keeping stored media"
      }
    }

    try { $layout.PlotType = 1 } catch { # acExtents
      Write-Output "DEBUG: model PlotType 1 rejected, using default plot type"
    }
    $layout.CenterPlot = $true
    $layout.UseStandardScale = $true
    $layout.StandardScale = 0 # acScaleToFit
    $layout.PlotWithLineweights = $false
    $layout.PlotWithPlotStyles = $true
    try { $document.Plot.QuietErrorMode = $true } catch {}
    try { $document.Plot.BatchPlotProgress = $false } catch {}

    $modelPageFile = Join-Path $tempDir "page_model.pdf"
    if ($document.Plot.PlotToFile($modelPageFile)) {
      if ((Test-Path -LiteralPath $modelPageFile) -and (Get-Item -LiteralPath $modelPageFile).Length -gt 1024) {
        $pagePdfPaths.Add($modelPageFile)
        $sheetPngPath = Join-Path $cacheDir ("{0}_sheet_model.png" -f $inputBaseName)
        try {
          if (-not [string]::IsNullOrWhiteSpace($PythonExe) -and (Test-Path -LiteralPath $PythonExe)) {
            & $PythonExe -c "import sys, fitz; doc = fitz.open(sys.argv[1]); page = doc.load_page(0); page.get_pixmap(dpi=150).save(sys.argv[2]); doc.close()" "$modelPageFile" "$sheetPngPath"
          }
        } catch {}
      }
    }
    try { if ($layout) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($layout) | Out-Null } } catch {}
    $layout = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
  }

  # КРАЙНИЙ FALLBACK — native accoreconsole (_.-EXPORT _PDF, только Model, 1 стр.).
  # Выполняется ТОЛЬКО если: нет печатаемых листов И COM-печать модели не удалась.
  # Документ COM уже закрываем, чтобы снять блокировку файла перед accoreconsole.
  if ($pagePdfPaths.Count -eq 0) {
    try { if ($document) { $document.Close($false) } } catch {}
    $document = $null
    $nativeExportScript = Join-Path $PSScriptRoot 'Invoke-NativeDwgPdfExport.ps1'
    if (Test-Path -LiteralPath $nativeExportScript) {
      try {
        . $nativeExportScript
        $nativePdf = Join-Path $tempDir "native_fallback.pdf"
        $null = Invoke-NativeDwgPdfExport -InputPath $InputPath -OutputPdf $nativePdf -WorkDir $tempDir -TimeoutSec 600
        if ((Test-Path -LiteralPath $nativePdf) -and (Get-Item -LiteralPath $nativePdf).Length -gt 1024) {
          $pagePdfPaths.Add($nativePdf)
        }
      } catch {}
    }
  }

  if ($pagePdfPaths.Count -eq 0) {
    throw "AutoCAD                                       PDF            ."
  }

  #                                              PDF
  $tempCombinedPdf = Join-Path $tempDir "combined.pdf"
  if ($pagePdfPaths.Count -eq 1) {
    Copy-Item -LiteralPath $pagePdfPaths[0] -Destination $tempCombinedPdf -Force
  } else {
    $mergeScript = @'
import sys
try:
    import fitz
    doc = fitz.open()
    for p in sys.argv[2:]:
        with fitz.open(p) as page_doc:
            doc.insert_pdf(page_doc)
    doc.save(sys.argv[1])
    doc.close()
except ImportError:
    import pypdf
    writer = pypdf.PdfWriter()
    for p in sys.argv[2:]:
        reader = pypdf.PdfReader(p)
        for page in reader.pages:
            writer.add_page(page)
    with open(sys.argv[1], "wb") as f:
        writer.write(f)
'@
    $mergePyFile = Join-Path $tempDir "merge.py"
    [System.IO.File]::WriteAllText($mergePyFile, $mergeScript, [System.Text.Encoding]::UTF8)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PythonExe
    $psi.Arguments = "`"$mergePyFile`" `"$tempCombinedPdf`" " + (($pagePdfPaths | ForEach-Object { "`"$_`"" }) -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardError = $true
    $pyProc = [System.Diagnostics.Process]::Start($psi)
    $pyProc.WaitForExit(120000)
    if ($pyProc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempCombinedPdf)) {
      $err = $pyProc.StandardError.ReadToEnd()
      throw "                           PDF: $err"
    }
  }

  #                                    DWG                  
  $finalDestination = $OutputPath
  $writeSuccess = $false
  try {
    Copy-Item -LiteralPath $tempCombinedPdf -Destination $OutputPath -Force -ErrorAction Stop
    $writeSuccess = $true
  } catch {
    if (-not [string]::IsNullOrWhiteSpace($FallbackCachePath)) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FallbackCachePath) | Out-Null
      Copy-Item -LiteralPath $tempCombinedPdf -Destination $FallbackCachePath -Force
      $finalDestination = $FallbackCachePath
      $writeSuccess = $true
    } else {
      throw "                     PDF                 '$OutputPath': $_"
    }
  }

  $result = @{
    ok = $true
    finalPath = $finalDestination
    isLocalFolder = ($finalDestination -eq $OutputPath)
    pageCount = $pagePdfPaths.Count
    progId = $usedProgId
  }
  Write-Output ($result | ConvertTo-Json -Compress)
} finally {
  try { [LauncherMessageFilter]::Revoke() } catch {}
  if ($document) {
    try { $document.Close($false) } catch {}
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($document) | Out-Null } catch {}
  }
  # SINGLE-INSTANCE: чужую (переиспользованную) сессию НЕ гасим — только
  # отсоединяемся от COM, процесс acad.exe остаётся жить для следующего DWG.
  # Quit + kill PID разрешены ТОЛЬКО если сессию создали мы сами ($ownedSession).
  if ($app) {
    if ($ownedSession) {
      try { $app.Quit() } catch {}
    }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null } catch {}
  }
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()

  # NO-AUTO-OPEN: сгенерированный PDF НИКОГДА не открывается внешним просмотрщиком.
  # Здесь запрещены Start-Process / Invoke-Item / & $OutputPath при любых условиях,
  # включая плоттер "DWG To PDF.pc3" (его "Show results in viewer" глушится выше
  # через VIEWDOC=0 и реестр ShowPlotViewer=0). Печать идёт только через
  # Plot.PlotToFile($pageFile), параметр «открывать файл после печати» всегда
  # выключен (PlotToFile его не выставляет). EXPORTPDF не используется;
  # если он появится — передавать OpenInViewer = False.
  if ($ownedSession -and $cadPid -and $cadPid -gt 0) {
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
      $p = Get-Process -Id $cadPid -ErrorAction SilentlyContinue
      if (-not $p -or $p.HasExited) { break }
      Start-Sleep -Milliseconds 200
    }
    try {
      $p = Get-Process -Id $cadPid -ErrorAction SilentlyContinue
      if ($p -and -not $p.HasExited) {
        Stop-Process -Id $cadPid -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }

  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Освобождаем single-instance Mutex всегда (и при reuse, и при own).
  if ($cadMutex) {
    try { if ($cadMutexOwned) { $cadMutex.ReleaseMutex() } } catch {}
    try { $cadMutex.Dispose() } catch {}
  }
}
