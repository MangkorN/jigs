<#
.SYNOPSIS
    Browser UI for gitro serve: start, watch and stop gitro servers from a web page,
    picking folders with the Windows folder dialog.

.DESCRIPTION
    Runs a small HTTP API on 127.0.0.1 for the Run page of the jigs site. The page is a file in this clone,
    site\run\index.html, or the hosted copy of the site. Neither depends on this script: without it, the page
    shows that gitro ui isn't running, and it connects by itself once it runs.

    'start', the default, starts this script again in the background, without a window, and returns once it
    answers, so the terminal can be closed. If one is already running, it's used instead. Either way the page
    is opened. With -Foreground this script is the companion itself, in this console, and Ctrl+C stops it.

    The running companion writes its port and token to .gitro-ui\session.js in this clone, which the local page
    reads, and marks the file ended when it stops. The hosted page gets them in the link instead.
    Every API call must carry the token, and must come from a page opened from a file or from the hosted site.

    Each gitro server runs as 'gitro.sh serve -k <repo> <dir>' under Git for Windows' bash,
    inside a job object, so stopping it also ends any git process it started,
    and the servers end with the companion, however it ends.

    Usually started from Git Bash with 'gitro ui', which passes its arguments through.

.PARAMETER Action
    start (the default), stop: stops the running companion and its servers, or status.

.PARAMETER Port
    Port to listen on, on 127.0.0.1 only.

.PARAMETER Open
    Page to open in the default browser: local (this clone's site\run\index.html), hosted, or none.

.PARAMETER SiteUrl
    Address of the hosted site, whose origin may call the companion.
    Defaults to the GitHub Pages address of this clone's origin remote. Pass '' to allow no hosted site.

.PARAMETER GitRoot
    Git for Windows install folder. Found through git on PATH, then the registry, when omitted.

.PARAMETER Foreground
    Run the companion in this console instead of the background.

.PARAMETER LogFile
    Where a companion writes what it would print. 'start' passes .gitro-ui\companion.log to the one it starts.

.EXAMPLE
    gitro ui
    From Git Bash: starts the companion in the background and opens the local Run page.
.EXAMPLE
    .\gitro-ui.ps1 stop
.EXAMPLE
    .\gitro-ui.ps1 -Foreground -Port 47300 -SiteUrl https://tools.example.com/jigs/
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status')]
    [string]$Action = 'start',

    [ValidateRange(1024, 65535)]
    [int]$Port = 47210,

    [ValidateSet('local', 'hosted', 'none')]
    [string]$Open = 'local',

    [string]$SiteUrl,

    [string]$GitRoot,

    [switch]$Foreground,

    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

# Objects are created with ::new(), and lists are copied with ToArray(), never with New-Object and @():
# Windows PowerShell 5.1 fails with "Argument types do not match" on @() over a List that New-Object returned,
# because New-Object wraps it in a PSObject.

# Raised when the HTTP API changes, so a page can tell it's talking to an older or newer companion.
$ApiVersion = 1
$EventLimit = 2000
$LongPollSeconds = 25
$IdleConnectionSeconds = 10
$MaxRequestBytes = 262144
$FolderLimit = 500
$Utf8 = [System.Text.UTF8Encoding]::new($false)

$JigsRoot = Split-Path $PSScriptRoot -Parent
$GitroScript = Join-Path $JigsRoot 'bash\functions\gitro.sh'
$RunPage = Join-Path $JigsRoot 'site\run\index.html'
$StateDir = Join-Path $JigsRoot '.gitro-ui'
$SessionFile = Join-Path $StateDir 'session.js'
$DefaultLogFile = Join-Path $StateDir 'companion.log'
$SiteUrlGiven = $PSBoundParameters.ContainsKey('SiteUrl')
$ScriptPath = $PSCommandPath

<# NATIVE =============================================================================================================== #>

$NativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Jigs.GitroUi
{
    /// <summary>
    /// Job object that ends every process assigned to it, with all of their descendants,
    /// when it's terminated or its last handle closes, including when this process dies.
    /// </summary>
    public static class Job
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimitInformation
        {
            public BasicLimitInformation Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        const int ExtendedLimitInformationClass = 9;
        const uint KillOnJobClose = 0x2000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimitInformation info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        /// <summary>Creates an empty job that kills its processes when its last handle closes.</summary>
        public static IntPtr Create()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception();

            var info = new ExtendedLimitInformation();
            info.Basic.LimitFlags = KillOnJobClose;
            uint size = (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation));
            if (!SetInformationJobObject(job, ExtendedLimitInformationClass, ref info, size))
            {
                var error = new Win32Exception();
                CloseHandle(job);
                throw error;
            }
            return job;
        }

        /// <summary>Adds a process to the job. Processes it starts afterwards join the job too.</summary>
        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process)) throw new Win32Exception();
        }

        /// <summary>Ends every process in the job.</summary>
        public static void Terminate(IntPtr job)
        {
            if (job != IntPtr.Zero) TerminateJobObject(job, 1);
        }

        /// <summary>Closes the handle, which also ends any process still in the job.</summary>
        public static void Close(IntPtr job)
        {
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    /// <summary>
    /// Starts a process that outlives this one and the terminal: no console window, none of this process's
    /// handles, and outside this process's job when the job allows that, since some terminals end the
    /// processes in their job when they close.
    /// </summary>
    public static class Detached
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, Width, Height, CharWidth, CharHeight, FillAttribute, Flags;
            public short ShowWindow, Reserved2;
            public IntPtr Reserved3, StdInput, StdOutput, StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref StartupInfo startup, out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        const uint CreateNoWindow = 0x08000000, CreateNewProcessGroup = 0x200, CreateBreakawayFromJob = 0x01000000;
        const int ErrorAccessDenied = 5;

        /// <summary>Starts <paramref name="commandLine"/> and returns its process id.
        /// <paramref name="application"/> and <paramref name="directory"/> may be <c>null</c>.</summary>
        public static int Start(string application, string commandLine, string directory)
        {
            var startup = new StartupInfo();
            startup.Size = Marshal.SizeOf(typeof(StartupInfo));
            ProcessInformation information;
            uint flags = CreateNoWindow | CreateNewProcessGroup;
            bool started = CreateProcess(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                flags | CreateBreakawayFromJob, IntPtr.Zero, directory, ref startup, out information);
            if (!started && Marshal.GetLastWin32Error() == ErrorAccessDenied)
            {
                started = CreateProcess(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    flags, IntPtr.Zero, directory, ref startup, out information);
            }
            if (!started) throw new Win32Exception();
            CloseHandle(information.Thread);
            CloseHandle(information.Process);
            return information.ProcessId;
        }
    }

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    class FileOpenDialogCoClass
    {
    }

    // Leading part of IFileDialog, up to GetResult. COM calls go by vtable slot, so the order must match shobjidl.h.
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item);
    }

    // Leading part of IShellItem, up to GetDisplayName.
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint form, [MarshalAs(UnmanagedType.LPWStr)] out string name);
    }

    /// <summary>
    /// Explorer-style folder dialog, shown on its own STA thread so the caller keeps running while it's open.
    /// Poll <see cref="Done"/>, then read <see cref="Path"/>, which is <c>null</c> if the dialog was cancelled,
    /// or <see cref="Error"/>.
    /// </summary>
    public sealed class FolderPicker
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style,
            int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

        [DllImport("user32.dll")]
        static extern bool DestroyWindow(IntPtr window);

        const uint FosNoChangeDir = 0x8, FosPickFolders = 0x20, FosForceFileSystem = 0x40, FosPathMustExist = 0x800;
        const uint SigdnFileSysPath = 0x80058000;
        const int ErrorCancelled = unchecked((int)0x800704C7);
        const uint WsExTopmost = 0x8, WsExToolWindow = 0x80, WsPopup = 0x80000000;

        readonly string title, initialPath;
        volatile bool done;
        string path, error;

        FolderPicker(string title, string initialPath)
        {
            this.title = title;
            this.initialPath = initialPath;
        }

        /// <summary>Whether the dialog has closed, after which Path and Error no longer change.</summary>
        public bool Done { get { return done; } }

        /// <summary>The chosen folder, or <c>null</c> if the dialog was cancelled or failed.</summary>
        public string Path { get { return path; } }

        /// <summary>Why the dialog failed, or <c>null</c>.</summary>
        public string Error { get { return error; } }

        /// <summary>Opens the dialog, starting in <paramref name="initialPath"/> if that folder exists.</summary>
        public static FolderPicker Start(string title, string initialPath)
        {
            var picker = new FolderPicker(title, initialPath);
            var thread = new Thread(picker.Run);
            thread.SetApartmentState(ApartmentState.STA);
            thread.IsBackground = true;
            thread.Start();
            return picker;
        }

        void Run()
        {
            IntPtr owner = IntPtr.Zero;
            IFileDialog dialog = null;
            IShellItem folder = null, item = null;
            try
            {
                // The browser holds the foreground, so a dialog without a topmost owner would open behind it.
                owner = CreateWindowEx(WsExTopmost | WsExToolWindow, "STATIC", "", WsPopup, 0, 0, 0, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                dialog = (IFileDialog)new FileOpenDialogCoClass();
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FosPickFolders | FosForceFileSystem | FosPathMustExist | FosNoChangeDir);
                if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);
                if (!string.IsNullOrEmpty(initialPath) && System.IO.Directory.Exists(initialPath))
                {
                    Guid iid = typeof(IShellItem).GUID;
                    if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out folder) == 0) dialog.SetFolder(folder);
                }

                int result = dialog.Show(owner);
                if (result == 0)
                {
                    string chosen;
                    dialog.GetResult(out item);
                    item.GetDisplayName(SigdnFileSysPath, out chosen);
                    path = chosen;
                }
                else if (result != ErrorCancelled)
                {
                    error = "The folder dialog failed with 0x" + result.ToString("X8") + ".";
                }
            }
            catch (Exception e)
            {
                error = e.Message;
            }
            finally
            {
                if (item != null) Marshal.ReleaseComObject(item);
                if (folder != null) Marshal.ReleaseComObject(folder);
                if (dialog != null) Marshal.ReleaseComObject(dialog);
                if (owner != IntPtr.Zero) DestroyWindow(owner);
                done = true;
            }
        }
    }
}
'@

function Use-Native {
    if (-not ('Jigs.GitroUi.Job' -as [type])) { Add-Type -TypeDefinition $NativeSource -Language CSharp }
}

<# OUTPUT =============================================================================================================== #>

# A companion in the background has no console, so it writes to its log instead.
$Log = $null

function Write-Line([string]$Text, [string]$Color) {
    if ($script:Log) {
        try { $script:Log.WriteLine(('{0:HH:mm:ss}  {1}' -f [DateTime]::Now, $Text)) } catch { }
    }
    elseif ($Color) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}

function Open-Log {
    if (-not $LogFile) { return }
    $directory = Split-Path $LogFile -Parent
    if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
    # Shared for reading, so 'gitro ui start' can show the log of a companion that failed to start.
    $stream = [IO.File]::Open($LogFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:Log = [IO.StreamWriter]::new($stream, $script:Utf8)
    $script:Log.AutoFlush = $true
}

function Close-Log {
    if (-not $script:Log) { return }
    try { $script:Log.Dispose() } catch { }
    $script:Log = $null
}

# The last lines of a log that another process may still be writing.
function Read-LogTail([string]$Path, [int]$Count) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $lines = [IO.StreamReader]::new($stream, $script:Utf8).ReadToEnd() -split "`r?`n" }
    finally { $stream.Dispose() }
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) { if ($line) { $kept.Add($line) } }
    if ($kept.Count -gt $Count) { $kept.RemoveRange(0, $kept.Count - $Count) }
    return $kept.ToArray()
}

<# ENVIRONMENT ========================================================================================================== #>

function Find-GitRoot {
    # The bash.exe found on PATH can be WSL's (C:\Windows\System32\bash.exe), so Git's own is found from git.exe.
    $candidates = [System.Collections.Generic.List[string]]::new()
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $dir = Split-Path $git.Path -Parent
        while ($dir) {
            $candidates.Add($dir)
            $dir = Split-Path $dir -Parent
        }
    }
    foreach ($key in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item -and $item.InstallPath) { $candidates.Add($item.InstallPath) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'usr\bin\bash.exe') -PathType Leaf) { return $candidate }
    }
    throw "Git for Windows wasn't found. Pass -GitRoot with its install folder, such as 'C:\Program Files\Git'."
}

# GitHub Pages address of this clone's origin remote, such as https://owner.github.io/jigs/, or '' if it isn't on GitHub.
function Get-DefaultSiteUrl {
    $git = Join-Path $GitRoot 'cmd\git.exe'
    if (-not (Test-Path -LiteralPath $git -PathType Leaf)) { $git = 'git' }

    # Windows PowerShell 5.1 turns a native command's stderr into errors, which 'Stop' would throw,
    # and a clone may have no origin.
    $ErrorActionPreference = 'Continue'
    $remote = & $git -C $JigsRoot remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and "$remote" -match 'github\.com[:/]+([^/]+)/([^/]+?)(\.git)?/?$') {
        return 'https://{0}.github.io/{1}/' -f $Matches[1].ToLowerInvariant(), $Matches[2]
    }
    return ''
}

# Quotes one argument for a Windows command line, by the rules programs use to split it again:
# backslashes are literal except before a quote, where they double.
function ConvertTo-ArgumentText([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', [Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return ($match.Groups[1].Value * 2) + '\"'
    })
    $escaped = [regex]::Replace($escaped, '(\\+)$', [Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return $match.Groups[1].Value * 2
    })
    return '"' + $escaped + '"'
}

# The default browser's command line, with %1 for the address, or $null.
function Get-BrowserCommand {
    $key = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice'
    $choice = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if (-not $choice -or -not $choice.ProgId) { return $null }
    $command = Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$($choice.ProgId)\shell\open\command" -ErrorAction SilentlyContinue
    if ($command -and $command.'(default)') { return [string]$command.'(default)' }
    return $null
}

# Opens an address in the default browser. A file address goes to the browser directly: opened like a file,
# it would go to whatever opens .html files, which can be an editor.
function Open-Url([string]$Url) {
    $command = Get-BrowserCommand
    if ($command) {
        $line = if ($command.Contains('%1')) { $command.Replace('%1', $Url) } else { "$command $(ConvertTo-ArgumentText $Url)" }
        try {
            Use-Native
            [void][Jigs.GitroUi.Detached]::Start($null, $line, $null)
            return
        }
        catch { }
    }
    Start-Process $Url
}

<# SESSION ============================================================================================================== #>

# .gitro-ui\session.js holds the running companion's port and token, as a script the local page loads:
#   window.JIGS_GITRO_UI = {"api":1,"port":47210,"token":"...","pid":1234,...};
# When the companion stops, the value becomes null. The folder ignores itself, so git never sees it.

function New-StateDir {
    [void][IO.Directory]::CreateDirectory($StateDir)
    $ignore = Join-Path $StateDir '.gitignore'
    if (-not (Test-Path -LiteralPath $ignore -PathType Leaf)) {
        [IO.File]::WriteAllText($ignore, "# gitro ui's session and log, never committed.`n*`n", $script:Utf8)
    }
}

# The session in the file, or $null if there's none or it has ended. Says nothing about whether it still runs.
function Read-Session {
    if (-not (Test-Path -LiteralPath $SessionFile -PathType Leaf)) { return $null }
    try { $text = [IO.File]::ReadAllText($SessionFile, $script:Utf8) } catch { return $null }
    if ($text -notmatch '^\s*window\.JIGS_GITRO_UI = (.*);\s*$' -or $Matches[1] -eq 'null') { return $null }
    try { $session = ConvertFrom-Json $Matches[1] } catch { return $null }
    if (-not $session.port -or -not $session.token -or -not $session.pid) { return $null }
    return $session
}

function Write-Session {
    New-StateDir
    $session = [ordered]@{
        api = $ApiVersion; port = $Port; token = $Token; pid = $PID; started = $script:StartedAt
        platform = 'windows'; site = $SiteUrl; log = $LogFile
    }
    $json = ConvertTo-Json -InputObject $session -Compress
    [IO.File]::WriteAllText($SessionFile, "window.JIGS_GITRO_UI = $json;`n", $script:Utf8)
}

# Marks the session ended, if it's this process's, or whoever's with -Force.
function Clear-Session([switch]$Force) {
    $session = Read-Session
    if (-not $session) { return }
    if ($Force -or $session.pid -eq $PID) {
        try { [IO.File]::WriteAllText($SessionFile, "window.JIGS_GITRO_UI = null;`n", $script:Utf8) } catch { }
    }
}

# Calls a running companion's API, the way the page does, and returns the answer.
function Invoke-Companion($Session, [string]$Method, [string]$Path) {
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create("http://127.0.0.1:$($Session.port)$Path")
    $request.Method = $Method
    $request.Proxy = $null
    $request.Timeout = 3000
    $request.Headers.Add('X-Gitro-Token', [string]$Session.token)
    if ($Method -eq 'POST') { $request.ContentLength = 0 }
    $response = $request.GetResponse()
    try {
        $text = [IO.StreamReader]::new($response.GetResponseStream(), $script:Utf8).ReadToEnd()
        return ConvertFrom-Json $text
    }
    finally { $response.Close() }
}

# The session's status if its companion answers, or $null.
function Test-Session($Session) {
    if (-not $Session) { return $null }
    try { return Invoke-Companion $Session 'GET' '/api/status' } catch { return $null }
}

# The session's companion process, or $null if it has ended. A process with the same id that started
# at another time, or isn't PowerShell, isn't it.
function Get-CompanionProcess($Session) {
    $process = Get-Process -Id ([int]$Session.pid) -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -notmatch '^(powershell|pwsh)$') { return $null }
    try {
        $started = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Session.started).UtcDateTime
        $lead = ($started - $process.StartTime.ToUniversalTime()).TotalSeconds
        if ($lead -lt -5 -or $lead -gt 300) { return $null }
    }
    catch { return $null }
    return $process
}

<# ACTIONS ============================================================================================================== #>

function Open-Page($Session) {
    switch ($Open) {
        'local' {
            if (-not (Test-Path -LiteralPath $RunPage -PathType Leaf)) {
                Write-Line '  This clone has no site\run\index.html, so no page was opened.'
                return
            }
            # The page reads the session file, so its address needs no token.
            $url = ([Uri]$RunPage).AbsoluteUri
            Write-Line "  page: $url"
            Open-Url $url
        }
        'hosted' {
            if (-not $Session.site) {
                Write-Line '  There is no hosted site to open. Pass -SiteUrl.'
                return
            }
            # The token travels in the fragment, which browsers never send to a server, and the page removes it.
            Write-Line "  page: $($Session.site)run/ (opened with this session's token)"
            Open-Url ('{0}run/#port={1}&token={2}' -f $Session.site, $Session.port, $Session.token)
        }
    }
}

# 'start': finds the running companion, or starts one in the background and waits until it answers.
function Start-Companion {
    $session = Read-Session
    if (Test-Session $session) {
        Write-Line "gitro ui is already running, on 127.0.0.1:$($session.port) (pid $($session.pid))."
        Open-Page $session
        return 0
    }

    Use-Native
    New-StateDir
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, 'start', '-Foreground',
        '-Open', 'none', '-Port', "$Port", '-LogFile', $DefaultLogFile) { $arguments.Add($argument) }
    if ($SiteUrlGiven) { $arguments.Add('-SiteUrl'); $arguments.Add($SiteUrl) }
    if ($GitRoot) { $arguments.Add('-GitRoot'); $arguments.Add($GitRoot) }
    $executable = (Get-Process -Id $PID).Path
    $line = ConvertTo-ArgumentText $executable
    foreach ($argument in $arguments) { $line += ' ' + (ConvertTo-ArgumentText $argument) }
    $child = [Jigs.GitroUi.Detached]::Start($executable, $line, $JigsRoot)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $session = Read-Session
        if ($session -and $session.pid -eq $child -and (Test-Session $session)) {
            Write-Line "gitro ui is running in the background, on 127.0.0.1:$($session.port) (pid $child)."
            Write-Line "  Stop it with 'gitro ui stop', or with Stop gitro ui on the page. Its servers stop with it."
            Write-Line "  log:  $DefaultLogFile"
            Open-Page $session
            return 0
        }
        if (-not (Get-Process -Id $child -ErrorAction SilentlyContinue)) {
            Write-Line 'gitro ui stopped while starting:' Red
            foreach ($entry in (Read-LogTail $DefaultLogFile 15)) { Write-Line "  $entry" }
            Write-Line "Run 'gitro ui -f' to start it in this terminal and see every message."
            return 1
        }
    }
    Write-Line "gitro ui didn't answer within 20 seconds. Its log is $DefaultLogFile." Red
    return 1
}

# 'stop': asks the running companion to stop, and ends it if it doesn't.
function Stop-Companion {
    $session = Read-Session
    if (-not $session) {
        Write-Line "gitro ui isn't running."
        return 0
    }
    $process = Get-CompanionProcess $session
    if (-not $process) {
        Clear-Session -Force
        Write-Line "gitro ui isn't running. Its last session ended without saying so, which is now cleared."
        return 0
    }
    $answered = $true
    try { [void](Invoke-Companion $session 'POST' '/api/quit') } catch { $answered = $false }
    if ($answered -and $process.WaitForExit(15000)) {
        Write-Line 'gitro ui stopped, with every server it started.'
        return 0
    }
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    [void]$process.WaitForExit(5000)
    Clear-Session -Force
    Write-Line "gitro ui didn't stop when asked, so it was ended. Its servers ended with it."
    return 0
}

# 'status': whether the companion runs, and its servers. Returns 1 if it isn't running.
function Show-Companion {
    $session = Read-Session
    $status = Test-Session $session
    if (-not $status) {
        Write-Line "gitro ui isn't running."
        return 1
    }
    $since = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$session.started).LocalDateTime
    Write-Line ('gitro ui is running on 127.0.0.1:{0} (pid {1}), since {2:yyyy-MM-dd HH:mm}.' -f $session.port, $session.pid, $since)
    if ($session.log) { Write-Line "  log:  $($session.log)" }
    if (@($status.servers).Count -eq 0) { Write-Line '  No servers.' }
    foreach ($server in $status.servers) {
        $state = $server.state
        if ($state -eq 'exited') { $state = "exited ($($server.exitCode))" }
        Write-Line ('  #{0}  {1,-12} {2} -> {3}' -f $server.id, $state, $server.repo, $server.dir)
    }
    return 0
}

<# EVENTS =============================================================================================================== #>

# Everything the page shows, numbered in order. A page asks for the events after the last number it has seen.
$Events = [System.Collections.Generic.List[object]]::new()
$Seq = 0

function Add-Event([hashtable]$Entry) {
    $script:Seq++
    $Entry.seq = $script:Seq
    $Entry.time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $script:Events.Add($Entry)
    if ($script:Events.Count -gt $EventLimit) { $script:Events.RemoveRange(0, $script:Events.Count - $EventLimit) }
}

function Add-ServerEvent($Server, [hashtable]$Entry) {
    $Entry.server = $Server.Id
    Add-Event $Entry
}

<# SERVERS ============================================================================================================== #>

$Servers = [System.Collections.Generic.List[object]]::new()
$NextServerId = 1

function New-ServerView($Server) {
    return @{
        id = $Server.Id; repo = $Server.Repo; dir = $Server.Dir
        state = $Server.State; exitCode = $Server.ExitCode; startedAt = $Server.StartedAt
    }
}

function Get-Server($Id) {
    $number = 0
    if ([int]::TryParse("$Id", [ref]$number)) {
        foreach ($server in $script:Servers) {
            if ($server.Id -eq $number) { return $server }
        }
    }
    throw [Collections.Generic.KeyNotFoundException]::new("There's no server #$Id.")
}

# Full Windows path of a folder named in a request, without a trailing separator.
# Git Bash paths (/d/Repos/MyProject) are accepted too.
function Resolve-FolderArgument([string]$Value, [string]$Label) {
    $Value = "$Value".Trim().Trim('"')
    if ($Value -match '^/([A-Za-z])(/.*)?$') { $Value = $Matches[1].ToUpperInvariant() + ':\' + ("$($Matches[2])" -replace '/', '\').TrimStart('\') }
    if ($Value -notmatch '^([A-Za-z]:[\\/]|\\\\[^\\])') {
        throw [ArgumentException]::new("$Label must be a full path, such as D:\Repos\MyProject or /d/Repos/MyProject.")
    }
    $full = [IO.Path]::GetFullPath($Value)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# The subfolders of a folder, for the page's path suggestions: names sorted without regard to case,
# each marked if it's a git repository, and at most $FolderLimit of them. Hidden and system folders
# are left out, as Explorer leaves them out.
function Get-Subfolders([string]$Path) {
    $full = Resolve-FolderArgument $Path 'The folder'
    if (-not [IO.Directory]::Exists($full)) { throw [Collections.Generic.KeyNotFoundException]::new("There's no folder $full.") }
    $skipped = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
    $names = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in [IO.DirectoryInfo]::new($full).GetDirectories()) {
            if (($entry.Attributes -band $skipped) -eq 0) { $names.Add($entry.Name) }
        }
    }
    catch { throw [InvalidOperationException]::new("$full can't be read ($($_.Exception.Message)).") }
    $names.Sort([StringComparer]::OrdinalIgnoreCase)
    $truncated = $names.Count -gt $FolderLimit
    if ($truncated) { $names.RemoveRange($FolderLimit, $names.Count - $FolderLimit) }
    $folders = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        $git = [IO.Path]::Combine($full, $name, '.git')
        $folders.Add(@{ name = $name; repo = ([IO.Directory]::Exists($git) -or [IO.File]::Exists($git)) })
    }
    return @{ path = $full; folders = $folders.ToArray(); truncated = $truncated }
}

# Two servers answering in one folder would take each other's requests.
function Assert-FolderFree([string]$Dir, $Except) {
    foreach ($other in $script:Servers) {
        if (-not [object]::ReferenceEquals($other, $Except) -and $other.State -eq 'running' -and $other.Dir -eq $Dir) {
            throw [InvalidOperationException]::new("Server #$($other.Id) already answers requests in $Dir.")
        }
    }
}

# A gitro serve started elsewhere, such as in a terminal, may already answer in the folder, and would make
# a new one refuse to start. gitro itself decides whether the folder's gitro-server.json belongs to a running
# server, since only bash can check its process id, and this says so before starting.
function Assert-FolderUnclaimed([string]$Dir) {
    $presence = Join-Path $Dir 'gitro-server.json'
    if (-not (Test-Path -LiteralPath $presence -PathType Leaf)) { return }
    # No quotes, which Join-CommandLine refuses: an empty IFS and no globbing keep each path one word.
    $owner = Invoke-Bash 'IFS=; set -f; source $1 && _gitro_presence_owner $2' $script:GitroScript, $presence
    if ($owner) {
        throw [InvalidOperationException]::new("$Dir is already served by $owner. Stop that server first, or use another folder.")
    }
}

# The process id in a folder's gitro-server.json, or $null.
function Get-PresencePid([string]$Dir) {
    $presence = Join-Path $Dir 'gitro-server.json'
    try { $text = [IO.File]::ReadAllText($presence) } catch { return $null }
    if ($text -match '"pid": (\d+)') { return [int]$Matches[1] }
    return $null
}

# Ending a job doesn't let gitro serve run its cleanup, so its gitro-server.json is removed here,
# if it's still the one this server wrote.
function Remove-ServerPresence($Server) {
    if ($null -eq $Server.PresencePid) { return }
    if ((Get-PresencePid $Server.Dir) -eq $Server.PresencePid) {
        Remove-Item -LiteralPath (Join-Path $Server.Dir 'gitro-server.json') -ErrorAction SilentlyContinue
    }
    $Server.PresencePid = $null
}

# Start information for Git's bash with these arguments, with Git's folders first on PATH and output redirected.
function New-BashStartInfo([string[]]$Arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $script:Bash
    $info.Arguments = Join-CommandLine -Arguments $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    $info.EnvironmentVariables['PATH'] = $script:BashPath
    $info.EnvironmentVariables.Remove('BASH_ENV')
    return $info
}

# Runs a short bash script and returns what it printed, trimmed. Gives up after 10 seconds.
function Invoke-Bash([string]$Script, [string[]]$Arguments) {
    $all = [System.Collections.Generic.List[string]]::new()
    $all.Add('-c'); $all.Add($Script); $all.Add('gitro-ui')
    foreach ($argument in $Arguments) { $all.Add($argument) }
    $process = [System.Diagnostics.Process]::Start((New-BashStartInfo -Arguments $all.ToArray()))
    try {
        $process.StandardInput.Close()
        $errors = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch { }
            return ''
        }
        Wait-Task $errors
        if (-not $output.Wait(1000)) { return '' }
        return $output.Result.Trim()
    }
    finally { $process.Dispose() }
}

# Quotes arguments for bash's command line. Forward slashes avoid the backslash-before-quote ambiguity,
# and gitro accepts paths in that form.
function Join-CommandLine([string[]]$Arguments) {
    $quoted = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        if ($argument.Contains('"')) { throw [ArgumentException]::new("Paths can't contain double quotes: $argument") }
        $quoted.Add('"' + ($argument -replace '\\', '/') + '"')
    }
    return $quoted -join ' '
}

function Set-ServerState($Server, [string]$State, $ExitCode) {
    $Server.State = $State
    $Server.ExitCode = $ExitCode
    $text = if ($null -ne $ExitCode) { "$State (exit $ExitCode)" } else { $State }
    Write-Line ('#{0}  {1}' -f $Server.Id, $text)
    Add-ServerEvent $Server @{ kind = 'state'; state = $State; exitCode = $ExitCode }
}

function Add-Server([string]$Repo, [string]$Dir) {
    $Repo = Resolve-FolderArgument $Repo 'The repository'
    $Dir = Resolve-FolderArgument $Dir 'The request folder'
    if (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
        throw [ArgumentException]::new("The repository folder $Repo doesn't exist.")
    }
    Assert-FolderFree $Dir $null
    Assert-FolderUnclaimed $Dir

    $server = @{
        Id = $script:NextServerId; Repo = $Repo; Dir = $Dir
        State = 'stopped'; ExitCode = $null; StartedAt = $null; Stopping = $false
        Process = $null; Job = [IntPtr]::Zero; OutTask = $null; ErrTask = $null; PresencePid = $null
        OwnRequests = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $script:NextServerId++
    $script:Servers.Add($server)
    Write-Line ('#{0}  added: {1} -> {2}' -f $server.Id, $Repo, $Dir)
    Add-ServerEvent $server @{ kind = 'added'; view = (New-ServerView $server) }
    Start-Server $server
    return $server
}

function Start-Server($Server) {
    if ($Server.Process) { return }
    Assert-FolderFree $Server.Dir $Server
    Assert-FolderUnclaimed $Server.Dir

    $info = New-BashStartInfo -Arguments $script:GitroScript, 'serve', '-k', $Server.Repo, $Server.Dir

    $job = [Jigs.GitroUi.Job]::Create()
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        [Jigs.GitroUi.Job]::Assign($job, $process.Handle)
    }
    catch {
        if ($process) { try { $process.Kill() } catch { } }
        [Jigs.GitroUi.Job]::Close($job)
        throw
    }
    $process.StandardInput.Close()

    $Server.Process = $process
    $Server.Job = $job
    $Server.OutTask = $process.StandardOutput.ReadLineAsync()
    $Server.ErrTask = $process.StandardError.ReadLineAsync()
    $Server.Stopping = $false
    $Server.StartedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Set-ServerState $Server 'running' $null
}

function Stop-Server($Server) {
    if (-not $Server.Process) { return }
    $Server.Stopping = $true
    [Jigs.GitroUi.Job]::Terminate($Server.Job)
    [void]$Server.Process.WaitForExit(3000)
    Wait-Task $Server.OutTask
    Wait-Task $Server.ErrTask
    Update-Server $Server
    if ($Server.Process) { Complete-ServerExit $Server }
}

function Remove-Server($Server) {
    Stop-Server $Server
    [void]$script:Servers.Remove($Server)
    Write-Line ('#{0}  removed' -f $Server.Id)
    Add-ServerEvent $Server @{ kind = 'removed' }
}

# Reads whatever output has arrived, and records the exit once both streams have ended.
function Update-Server($Server) {
    if (-not $Server.Process) { return }
    $Server.OutTask = Receive-ServerOutput $Server $Server.OutTask $Server.Process.StandardOutput
    $Server.ErrTask = Receive-ServerOutput $Server $Server.ErrTask $Server.Process.StandardError
    if (-not $Server.OutTask -and -not $Server.ErrTask -and $Server.Process.HasExited) { Complete-ServerExit $Server }
}

# Hands every line that read $Task and the reads after it have finished to Receive-ServerLine,
# and returns the read still in progress, or $null once the stream has ended.
function Receive-ServerOutput($Server, $Task, $Reader) {
    $reading = $true
    while ($reading -and $Task -and $Task.IsCompleted) {
        $line = Get-TaskLine $Task
        if ($null -eq $line) {
            $Task = $null
            $reading = $false
        }
        else {
            Receive-ServerLine $Server $line
            $Task = $Reader.ReadLineAsync()
        }
    }
    return $Task
}

# The line a finished read returned, or $null at the end of the stream or if the read failed.
function Get-TaskLine($Task) {
    try { return $Task.Result } catch { return $null }
}

# Waits up to a second for a read to finish, ignoring a failed one. $Task may be $null.
function Wait-Task($Task) {
    if (-not $Task) { return }
    try { [void]$Task.Wait(1000) } catch { }
}

function Complete-ServerExit($Server) {
    $code = $null
    try { $code = $Server.Process.ExitCode } catch { }
    [Jigs.GitroUi.Job]::Close($Server.Job)
    Remove-ServerPresence $Server
    $Server.Process.Dispose()
    $Server.Process = $null
    $Server.Job = [IntPtr]::Zero
    $Server.OutTask = $null
    $Server.ErrTask = $null
    if ($Server.Stopping) { Set-ServerState $Server 'stopped' $null } else { Set-ServerState $Server 'exited' $code }
    $Server.Stopping = $false
}

# gitro serve logs each request as '<time>  <name>: <request> (exit <code>)'. Anything else is passed on as text.
function Receive-ServerLine($Server, [string]$Line) {
    Write-Line ('#{0}  {1}' -f $Server.Id, $Line)
    # The startup line comes once gitro-server.json is written.
    if ($Line.StartsWith('gitro: serving ')) { $Server.PresencePid = Get-PresencePid $Server.Dir }
    if ($Line -match '^(\d\d:\d\d:\d\d)  (.+?): (.*) \(exit (\d+)\)$') {
        $name = $Matches[2]
        $entry = @{ kind = 'request'; clock = $Matches[1]; name = $name; request = $Matches[3]; 'exit' = [int]$Matches[4] }
        # This script is the caller for its own requests, so it removes their responses as a caller would.
        $entry.own = $Server.OwnRequests.Remove($name)
        if ($entry.own) { Remove-Item -LiteralPath (Join-Path $Server.Dir "$name.out") -ErrorAction SilentlyContinue }
        Add-ServerEvent $Server $entry
    }
    else {
        Add-ServerEvent $Server @{ kind = 'log'; text = $Line }
    }
}

# Drops a request into the server's folder the way any caller would, and returns its name.
function Send-GitroRequest($Server, $Arguments) {
    if ($Server.State -ne 'running') { throw [InvalidOperationException]::new("Server #$($Server.Id) isn't running.") }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        if ($null -ne $argument) { $lines.Add([string]$argument) }
    }
    if ($lines.Count -eq 0 -or -not $lines[0]) { throw [ArgumentException]::new('The request needs a command.') }
    foreach ($line in $lines) {
        if ($line -match '[\r\n]') { throw [ArgumentException]::new('Each argument must be a single line.') }
    }

    $name = 'ui-{0}-{1}' -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), (Get-Random -Maximum 100000)
    $temporary = Join-Path $Server.Dir "$name.tmp"
    # $Utf8 writes no BOM, which gitro would otherwise read as part of the command.
    [IO.File]::WriteAllText($temporary, (($lines -join "`n") + "`n"), $script:Utf8)
    [void]$Server.OwnRequests.Add($name)
    [IO.File]::Move($temporary, (Join-Path $Server.Dir "$name.req"))
    return $name
}

<# HTTP ================================================================================================================= #>

# Connections still sending their request, and requests waiting for an event or the folder dialog.
$Incoming = [System.Collections.Generic.List[object]]::new()
$Parked = [System.Collections.Generic.List[object]]::new()
$ReadBuffer = [byte[]]::new(16384)

$Reasons = @{
    200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 401 = 'Unauthorized'
    403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 500 = 'Internal Server Error'
}

# Reads what has arrived on a connection without blocking. Returns the parsed request once it's complete,
# $null while more is expected, or 'drop' for a connection to close unanswered.
function Receive-Request($Connection) {
    if (-not (Read-Available $Connection)) { return 'drop' }

    $bytes = $Connection.Data.ToArray()
    $expired = ([DateTime]::UtcNow - $Connection.Since).TotalSeconds -gt $IdleConnectionSeconds
    if ($bytes.Length -gt $MaxRequestBytes) { return 'drop' }

    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $end = $text.IndexOf("`r`n`r`n")
    if ($end -lt 0) {
        if ($expired) { return 'drop' }
        return $null
    }

    $lines = $text.Substring(0, $end) -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -ne 3) { return 'drop' }
    $headers = @{}
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
    }
    if ($headers.ContainsKey('transfer-encoding')) { return 'drop' }

    $length = 0
    if ($headers.ContainsKey('content-length')) {
        if (-not [int]::TryParse($headers['content-length'], [ref]$length) -or $length -lt 0) { return 'drop' }
    }
    $bodyStart = $end + 4
    if ($bytes.Length - $bodyStart -lt $length) {
        if ($expired) { return 'drop' }
        return $null
    }

    $target = $parts[1]
    $path = $target
    $query = @{}
    $question = $target.IndexOf('?')
    if ($question -ge 0) {
        $path = $target.Substring(0, $question)
        foreach ($pair in $target.Substring($question + 1).Split('&')) {
            $keyValue = $pair.Split([char[]]'=', 2)
            if ($keyValue[0]) {
                $value = ''
                if ($keyValue.Count -gt 1) { $value = [Uri]::UnescapeDataString($keyValue[1].Replace('+', ' ')) }
                $query[[Uri]::UnescapeDataString($keyValue[0])] = $value
            }
        }
    }

    return @{
        Client = $Connection.Client; Method = $parts[0].ToUpperInvariant(); Path = $path; Query = $query
        Headers = $headers; Body = $Utf8.GetString($bytes, $bodyStart, $length)
    }
}

# Copies whatever has arrived on the connection into its buffer.
# Returns $false once the connection has failed or the other side has closed it.
function Read-Available($Connection) {
    try {
        $open = $true
        while ($open -and $Connection.Stream.DataAvailable) {
            $count = $Connection.Stream.Read($script:ReadBuffer, 0, $script:ReadBuffer.Length)
            if ($count -gt 0) { $Connection.Data.Write($script:ReadBuffer, 0, $count) }
            else { $open = $false }
        }
        return $open
    }
    catch {
        return $false
    }
}

function Close-Client($Client) {
    try { $Client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) } catch { }
    try { $Client.Close() } catch { }
}

# Writes a complete response and closes the connection. Write errors mean the page went away, so they're ignored.
function Send-Response($Request, [int]$Status, [string]$ContentType, [byte[]]$Body, [hashtable]$Headers) {
    if ($null -eq $Body) { $Body = [byte[]]::new(0) }
    $head = [System.Text.StringBuilder]::new()
    [void]$head.Append("HTTP/1.1 $Status $($script:Reasons[$Status])`r`n")
    [void]$head.Append("Content-Length: $($Body.Length)`r`nConnection: close`r`nX-Content-Type-Options: nosniff`r`n")
    if ($ContentType) { [void]$head.Append("Content-Type: $ContentType`r`n") }
    if ($Headers) {
        foreach ($key in $Headers.Keys) { [void]$head.Append("${key}: $($Headers[$key])`r`n") }
    }
    [void]$head.Append("`r`n")
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head.ToString())
    try {
        $stream = $Request.Client.GetStream()
        $stream.Write($headBytes, 0, $headBytes.Length)
        if ($Body.Length -gt 0) { $stream.Write($Body, 0, $Body.Length) }
    }
    catch {
    }
    Close-Client $Request.Client
}

# CORS headers for an allowed origin; responses to other origins carry none, so browsers withhold them.
# A page opened from a file sends the origin 'null', which is allowed back as 'null'.
function Get-ApiHeaders($Request, [switch]$Preflight) {
    $headers = @{ 'Cache-Control' = 'no-store' }
    $origin = $Request.Headers['origin']
    if ($origin -and $script:AllowedOrigins -contains $origin) {
        $headers['Access-Control-Allow-Origin'] = $origin
        $headers['Vary'] = 'Origin'
        if ($Preflight) {
            $headers['Access-Control-Allow-Methods'] = 'GET, POST'
            $headers['Access-Control-Allow-Headers'] = 'Content-Type, X-Gitro-Token'
            $headers['Access-Control-Allow-Private-Network'] = 'true'
            $headers['Access-Control-Max-Age'] = '600'
        }
    }
    return $headers
}

function Send-Json($Request, [int]$Status, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    $bytes = $script:Utf8.GetBytes($json)
    Send-Response $Request $Status 'application/json; charset=utf-8' $bytes (Get-ApiHeaders $Request)
}

function Send-Text($Request, [int]$Status, [string]$Text) {
    $bytes = $script:Utf8.GetBytes($Text)
    Send-Response $Request $Status 'text/plain; charset=utf-8' $bytes (Get-ApiHeaders $Request)
}

function Add-Parked([hashtable]$Entry) {
    if ($Entry.Kind -eq 'events') {
        $oldest = $null
        $count = 0
        foreach ($parked in $script:Parked.ToArray()) {
            if ($parked.Kind -eq 'events') {
                if ($count -eq 0) { $oldest = $parked }
                $count++
            }
        }
        if ($count -ge 16) {
            [void]$script:Parked.Remove($oldest)
            Complete-Parked $oldest
        }
    }
    $script:Parked.Add($Entry)
}

function Update-Parked {
    if ($script:Parked.Count -eq 0) { return }
    $now = [DateTime]::UtcNow
    foreach ($entry in $script:Parked.ToArray()) {
        if ($entry.Kind -eq 'events') { $ready = $script:Seq -gt $entry.After -or $now -ge $entry.Deadline }
        else { $ready = $entry.Picker.Done }
        if ($ready) {
            [void]$script:Parked.Remove($entry)
            Complete-Parked $entry
        }
    }
}

function Complete-Parked($Entry) {
    if ($Entry.Kind -eq 'events') {
        Send-Events $Entry.Request $Entry.After
        return
    }
    $picker = $Entry.Picker
    if ($picker.Error) { Send-Json $Entry.Request 500 @{ error = $picker.Error } }
    elseif ($picker.Path) { Send-Json $Entry.Request 200 @{ path = $picker.Path } }
    else { Send-Json $Entry.Request 200 @{ cancelled = $true } }
}

# 'missed' tells a page that fell further behind than the events kept here to reload the status instead.
function Send-Events($Request, [int]$After) {
    $batch = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $script:Events.ToArray()) {
        if ($entry.seq -gt $After) { $batch.Add($entry) }
    }
    $oldest = $script:Seq + 1
    if ($script:Events.Count -gt 0) { $oldest = $script:Events[0].seq }
    Send-Json $Request 200 @{ events = $batch.ToArray(); last = $script:Seq; missed = ($After + 1 -lt $oldest) }
}

<# API ================================================================================================================== #>

# 'platform' and 'picker' let a page adapt: path examples, and a Browse button only where a folder dialog exists.
function Get-Status {
    $views = [System.Collections.Generic.List[object]]::new()
    foreach ($server in $script:Servers.ToArray()) { $views.Add((New-ServerView $server)) }
    return @{
        api = $ApiVersion; platform = 'windows'; picker = $true; port = $Port; site = $SiteUrl; jigs = $JigsRoot
        gitRoot = $GitRoot; bash = $Bash; pid = $PID; started = $script:StartedAt; background = [bool]$LogFile
        seq = $script:Seq; servers = $views.ToArray()
    }
}

# Checks where a request comes from, then routes it. Validation errors become 400, unknown ids 404,
# conflicts with the current state 409, and anything else 500.
function Invoke-Request($Request) {
    $headers = $Request.Headers
    # A Host check stops DNS rebinding, where a hostile domain resolves to 127.0.0.1 to look same-origin.
    if ($script:AllowedHosts -notcontains $headers['host']) { Send-Text $Request 403 'Unexpected Host header.'; return }
    $origin = $headers['origin']
    if ($origin -and $script:AllowedOrigins -notcontains $origin) { Send-Text $Request 403 "Origin $origin isn't allowed."; return }

    if ($Request.Method -eq 'OPTIONS') {
        Send-Response $Request 204 $null $null (Get-ApiHeaders $Request -Preflight)
        return
    }
    if (-not $Request.Path.StartsWith('/api/')) {
        Send-Text $Request 404 "gitro ui answers only its API. Open the Run page from this clone's site\run\index.html."
        return
    }
    # Every project site on one github.io account shares an origin, so the origin check alone isn't enough.
    if ($headers['x-gitro-token'] -cne $script:Token) {
        Send-Json $Request 401 @{ error = 'Missing or wrong token. gitro ui was probably restarted, which gives it a new one.' }
        return
    }

    try {
        $body = $null
        if ($Request.Method -eq 'POST' -and $Request.Body.Trim()) {
            try { $body = ConvertFrom-Json $Request.Body }
            catch { throw [ArgumentException]::new("The request body isn't valid JSON.") }
        }
        Invoke-ApiCall $Request $body
    }
    catch {
        $failure = Get-ApiFailure $_.Exception
        Send-Json $Request $failure.Status @{ error = $failure.Message }
    }
}

# The HTTP status and message for an API call that threw: 409 for a conflict with the current state, 400 for bad input,
# 404 for an unknown id, and 500 for anything else. Each type is tested with -is, along the chain of inner exceptions
# that PowerShell may wrap around one, rather than with typed catch clauses.
function Get-ApiFailure($Exception) {
    for ($current = $Exception; $current; $current = $current.InnerException) {
        $status = 0
        if ($current -is [System.InvalidOperationException]) { $status = 409 }
        elseif ($current -is [System.ArgumentException]) { $status = 400 }
        elseif ($current -is [System.Collections.Generic.KeyNotFoundException]) { $status = 404 }
        if ($status) { return @{ Status = $status; Message = $current.Message } }
    }
    return @{ Status = 500; Message = $Exception.Message }
}

# API calls, all JSON unless noted:
#   GET  /api/status                         versions, platform, paths and servers, with the current event number
#   GET  /api/events?after=<n>               events after n, waiting up to 25 seconds for one
#   POST /api/pick-folder {title, start}     {path} or {cancelled}, once the folder dialog closes
#   GET  /api/folders?path=<folder>          {path, folders: [{name, repo}], truncated}: its subfolders
#   POST /api/servers {repo, dir}            adds and starts a server
#   POST /api/servers/<id>/stop|restart|remove
#   POST /api/request {server, args}         drops a request into the server's folder, returns {name}
#   GET  /api/response?server=<id>&name=<n>  a kept response, as text
#   POST /api/quit                           stops every server and this script
function Invoke-ApiCall($Request, $Body) {
    $route = '{0} {1}' -f $Request.Method, $Request.Path
    switch -Regex ($route) {
        '^GET /api/status$' {
            Send-Json $Request 200 (Get-Status)
            return
        }
        '^GET /api/events$' {
            [int]$after = 0
            [void][int]::TryParse([string]$Request.Query['after'], [ref]$after)
            if ($script:Seq -gt $after) { Send-Events $Request $after }
            else {
                $deadline = [DateTime]::UtcNow.AddSeconds($LongPollSeconds)
                Add-Parked @{ Kind = 'events'; Request = $Request; After = $after; Deadline = $deadline }
            }
            return
        }
        '^POST /api/pick-folder$' {
            if ($script:Picker -and -not $script:Picker.Done) { throw [InvalidOperationException]::new('A folder dialog is already open.') }
            $title = 'Choose a folder'
            $start = ''
            if ($Body -and $Body.title) { $title = [string]$Body.title }
            if ($Body -and $Body.start) { $start = [string]$Body.start }
            $script:Picker = [Jigs.GitroUi.FolderPicker]::Start($title, $start)
            Add-Parked @{ Kind = 'pick'; Request = $Request; Picker = $script:Picker }
            return
        }
        '^GET /api/folders$' {
            Send-Json $Request 200 (Get-Subfolders ([string]$Request.Query['path']))
            return
        }
        '^POST /api/servers$' {
            if (-not $Body) { throw [ArgumentException]::new('Send {repo, dir}.') }
            $server = Add-Server $Body.repo $Body.dir
            Send-Json $Request 200 (New-ServerView $server)
            return
        }
        '^POST /api/servers/(\d+)/(stop|restart|remove)$' {
            $server = Get-Server $Matches[1]
            switch ($Matches[2]) {
                'stop' { Stop-Server $server }
                'restart' { Stop-Server $server; Start-Server $server }
                'remove' { Remove-Server $server }
            }
            Send-Json $Request 200 (New-ServerView $server)
            return
        }
        '^POST /api/request$' {
            if (-not $Body) { throw [ArgumentException]::new('Send {server, args}.') }
            $server = Get-Server $Body.server
            $name = Send-GitroRequest $server $Body.args
            Send-Json $Request 200 @{ name = $name }
            return
        }
        '^GET /api/response$' {
            $server = Get-Server $Request.Query['server']
            $name = [string]$Request.Query['name']
            if ($name -notmatch '^[^\\/:*?"<>|]+$' -or $name -match '^\.+$') {
                throw [ArgumentException]::new('That isn''t a response name.')
            }
            $file = Join-Path (Join-Path $server.Dir 'kept') "$name.out"
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                $message = "No kept response is named $name. Kept responses are removed after an hour."
                throw [Collections.Generic.KeyNotFoundException]::new($message)
            }
            Send-Text $Request 200 ([IO.File]::ReadAllText($file, $script:Utf8))
            return
        }
        '^POST /api/quit$' {
            Send-Json $Request 200 @{ ok = $true }
            $script:Quit = $true
            return
        }
    }
    throw [Collections.Generic.KeyNotFoundException]::new("There's no API call '$route'.")
}

<# LOOP ================================================================================================================= #>

# One pass of the main loop: accepts connections, answers requests that have fully arrived, reads server output,
# and answers requests that were waiting. Returns $true if there was anything to do.
function Invoke-Tick {
    $busy = $false
    while ($script:listener.Pending()) {
        $null = Add-Connection
        $busy = $true
    }
    foreach ($connection in $script:Incoming.ToArray()) {
        if ((Receive-Connection $connection) -eq $true) { $busy = $true }
    }
    foreach ($server in $script:Servers.ToArray()) { $null = Update-ServerQuietly $server }
    $null = Update-ParkedQuietly
    return $busy
}

function Add-Connection {
    $client = $script:listener.AcceptTcpClient()
    $client.NoDelay = $true
    $script:Incoming.Add(@{
        Client = $client; Stream = $client.GetStream(); Data = [System.IO.MemoryStream]::new(); Since = [DateTime]::UtcNow
    })
}

# Answers the connection's request once it has fully arrived. Returns $true if it did.
function Receive-Connection($Connection) {
    $request = Receive-Request $Connection
    if ($null -eq $request) { return $false }
    [void]$script:Incoming.Remove($Connection)
    if ($request -is [string]) {
        Close-Client $Connection.Client
        return $false
    }
    try { $null = Invoke-Request $request }
    catch {
        Write-Line "warning: $($request.Method) $($request.Path) failed: $(Format-Failure $_)" Yellow
        Close-Client $request.Client
    }
    return $true
}

function Update-ServerQuietly($Server) {
    try { Update-Server $Server }
    catch { Write-Line "warning: server #$($Server.Id): $(Format-Failure $_)" Yellow }
}

function Update-ParkedQuietly {
    try { Update-Parked }
    catch { Write-Line "warning: answering a waiting request failed: $(Format-Failure $_)" Yellow }
}

function Stop-ServerQuietly($Server) {
    try { Stop-Server $Server }
    catch { Write-Line "warning: stopping server #$($Server.Id) failed: $(Format-Failure $_)" Yellow }
}

# An error's message with the script line it came from.
function Format-Failure($ErrorRecord) {
    return '{0} (line {1})' -f $ErrorRecord.Exception.Message, $ErrorRecord.InvocationInfo.ScriptLineNumber
}

<# MAIN ================================================================================================================= #>

# Ends this process for certain once its action is done. When it was started as a script (-File), as 'gitro ui'
# and 'start' do, a plain exit could leave it waiting on a thread it started. In a PowerShell session, exit is enough.
function Exit-Companion([int]$Code) {
    $launchedAsFile = $false
    foreach ($argument in [Environment]::GetCommandLineArgs()) { if ($argument -eq '-File') { $launchedAsFile = $true } }
    if ($LogFile -or $launchedAsFile) { [Environment]::Exit($Code) }
    exit $Code
}

switch ($Action) {
    'stop' { Exit-Companion (Stop-Companion) }
    'status' { Exit-Companion (Show-Companion) }
}
if (-not $Foreground) { Exit-Companion (Start-Companion) }

# From here on, this process is the companion.
$Picker = $null
$Quit = $false
$Ready = $false
$listener = $null
$exitCode = 0
try {
    Open-Log
    Use-Native

    $running = Read-Session
    if ($running -and $running.pid -ne $PID -and (Test-Session $running)) {
        throw "gitro ui is already running, on 127.0.0.1:$($running.port) (pid $($running.pid)). Stop it first with 'gitro ui stop'."
    }

    if (-not (Test-Path -LiteralPath $GitroScript -PathType Leaf)) { throw "gitro.sh isn't at $GitroScript." }
    if (-not $GitRoot) { $GitRoot = Find-GitRoot }
    $GitRoot = $GitRoot.TrimEnd('\')
    $Bash = Join-Path $GitRoot 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $Bash -PathType Leaf)) {
        throw "There's no bash.exe in $GitRoot\usr\bin. Pass -GitRoot with the Git for Windows install folder."
    }

    # Git's own folders go first on bash's PATH, so gitro finds its tools even when this script didn't start from Git Bash.
    $gitBinDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($folder in 'usr\bin', 'mingw64\bin', 'clangarm64\bin', 'mingw32\bin') {
        $full = Join-Path $GitRoot $folder
        if (Test-Path -LiteralPath $full -PathType Container) { $gitBinDirs.Add($full) }
    }
    $gitBinDirs.Add($env:PATH)
    $BashPath = $gitBinDirs.ToArray() -join ';'

    if (-not $SiteUrlGiven) { $SiteUrl = Get-DefaultSiteUrl }
    if ($SiteUrl -and -not $SiteUrl.EndsWith('/')) { $SiteUrl += '/' }

    $AllowedHosts = @("127.0.0.1:$Port", "localhost:$Port")
    $AllowedOrigins = @('null')
    if ($SiteUrl) { $AllowedOrigins += ([Uri]$SiteUrl).GetLeftPart([UriPartial]::Authority) }

    $tokenBytes = [byte[]]::new(24)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $random.GetBytes($tokenBytes)
    $random.Dispose()
    $Token = [BitConverter]::ToString($tokenBytes).Replace('-', '').ToLowerInvariant()

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() }
    catch {
        $listener = $null
        throw "Can't listen on 127.0.0.1:$Port, which another program uses. Pass another port with -p. ($($_.Exception.Message))"
    }
    $StartedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-Session

    $stopHint = if ($LogFile) { "Stop it with 'gitro ui stop'" } else { 'Ctrl+C stops it' }
    Write-Line "gitro ui is listening on http://127.0.0.1:$Port, pid $PID. $stopHint, and every server it started."
    Write-Line "  session: $SessionFile"
    if ($SiteUrl) { Write-Line "  hosted:  $($SiteUrl)run/#port=$Port&token=$Token" }
    Write-Line "  bash:    $Bash"
    Open-Page (Read-Session)

    $Ready = $true
    while (-not $Quit) {
        if (-not (Invoke-Tick)) { Start-Sleep -Milliseconds 30 }
    }
}
catch {
    $exitCode = 1
    Write-Line "gitro ui failed: $(Format-Failure $_)" Red
    # A failure while setting up is explained by its message. One while running needs the details.
    if ($Ready) {
        Write-Line $_.ScriptStackTrace
        Write-Line $_.Exception.ToString()
    }
}
finally {
    foreach ($server in $Servers.ToArray()) { Stop-ServerQuietly $server }
    foreach ($entry in $Parked.ToArray()) { Close-Client $entry.Request.Client }
    foreach ($connection in $Incoming.ToArray()) { Close-Client $connection.Client }
    if ($listener) {
        $listener.Stop()
        Clear-Session
    }
    Write-Line 'gitro ui stopped.'
    Close-Log
    Exit-Companion $exitCode
}
