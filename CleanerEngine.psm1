#requires -Version 5.1
<#
.SYNOPSIS
    Cleaner engine: the built-in list of safe cleanup locations, plus analysis and deletion.

.DESCRIPTION
    This module has no user interface. Cleaner.ps1 (the app) and Tests\Test-CleanerEngine.ps1 use it.

    A file is removed only when EVERY one of these checks passes - otherwise it is kept:

      1. It lives inside one of the fixed, built-in locations from Get-CleanerRule (no user-typed paths).
         A location is refused when it is (or contains) a personal or system folder, when it or any
         parent folder is a link (junction / symbolic link), or when it is not on a fixed local drive.
      2. Links found inside a location are never followed and never deleted.
      3. It is older than the location's age limit. The NEWER of "created" and "modified" counts, so a
         file that an installer has just unpacked with an old date is still treated as new.
      4. It is not read-only, system, a cloud placeholder or hard-linked, and its type is not on the
         never-delete list (AI models, disk images, keys, databases, office documents).
      5. The app that owns the cache is not running (browsers and apps).
      6. At deletion time the file is opened exclusively - if any program has it open, it is kept.
         Through that same handle Cleaner checks that the file is still inside its location (this defeats
         folder-swap tricks), is unchanged since the analysis, and only then deletes it.
      7. Only empty folders are removed, never the location itself.

    Every deletion is written to the log in %LOCALAPPDATA%\Cleaner\Logs.
#>

Set-StrictMode -Version 2.0

$script:EngineVersion = '2.1.0'

# ----------------------------------------------------------------------------------------------
#  Native helpers (compiled once per process; C# 5 so Windows PowerShell 5.1 can compile it)
# ----------------------------------------------------------------------------------------------
$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CleanerNative
{
    /// <summary>A file found by the analysis that may be deleted later.</summary>
    public sealed class Candidate
    {
        public readonly string Path;
        public readonly long Size;
        public readonly long WriteTime;   // last-write FILETIME (UTC) seen during the analysis
        public readonly long Stamp;       // newest of created / modified (FILETIME UTC)
        public readonly int Root;         // index of the location this file belongs to

        public Candidate(string path, long size, long writeTime, long stamp, int root)
        {
            Path = path; Size = size; WriteTime = writeTime; Stamp = stamp; Root = root;
        }

        public DateTime LastChanged { get { return DateTime.FromFileTimeUtc(Stamp).ToLocalTime(); } }
    }

    /// <summary>A folder that may be removed if it is empty after cleaning.</summary>
    public sealed class FolderCandidate
    {
        public readonly string Path;
        public readonly int Depth;
        public readonly int Root;

        public FolderCandidate(string path, int depth, int root)
        {
            Path = path; Depth = depth; Root = root;
        }
    }

    public enum DeleteStatus
    {
        Deleted = 0,    // removed
        Missing = 1,    // already gone
        InUse = 2,      // another program has it open
        Denied = 3,     // no permission
        Changed = 4,    // modified since the analysis or not old enough any more
        Outside = 5,    // the opened file is not inside the expected location (link or swap trick)
        Unsafe = 6,     // read-only, system, link, hard link, cloud file ...
        NotEmpty = 7,   // folder still has content
        Failed = 8      // any other error
    }

    public static class SafeIO
    {
        private const uint DELETE = 0x00010000;
        private const uint FILE_READ_ATTRIBUTES = 0x00000080;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint SHARE_ALL = 0x00000007;
        private const uint OPEN_EXISTING = 3;
        private const uint FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const int FILE_DISPOSITION_INFO = 4;

        private const uint ATTR_READONLY = 0x00000001;
        private const uint ATTR_SYSTEM = 0x00000004;
        private const uint ATTR_DIRECTORY = 0x00000010;
        private const uint ATTR_REPARSE_POINT = 0x00000400;
        private const uint ATTR_OFFLINE = 0x00001000;
        private const uint ATTR_RECALL_ON_OPEN = 0x00040000;
        private const uint ATTR_PINNED = 0x00080000;
        private const uint ATTR_UNPINNED = 0x00100000;
        private const uint ATTR_RECALL_ON_DATA_ACCESS = 0x00400000;
        private const uint CLOUD_OR_LINK = ATTR_REPARSE_POINT | ATTR_OFFLINE | ATTR_RECALL_ON_OPEN | ATTR_PINNED | ATTR_UNPINNED | ATTR_RECALL_ON_DATA_ACCESS;
        private const uint FILE_KEEP = CLOUD_OR_LINK | ATTR_DIRECTORY | ATTR_READONLY | ATTR_SYSTEM;
        private const uint FOLDER_KEEP = CLOUD_OR_LINK | ATTR_READONLY | ATTR_SYSTEM;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public uint CreationLow;
            public uint CreationHigh;
            public uint AccessLow;
            public uint AccessHigh;
            public uint WriteLow;
            public uint WriteHigh;
            public uint VolumeSerial;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess, uint shareMode,
            IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint length, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle file, int informationClass, ref byte information, uint size);

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        private static string StripPrefix(string path)
        {
            if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + path.Substring(8);
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path.Substring(4);
            return path;
        }

        private static string FinalPathOf(SafeFileHandle handle)
        {
            StringBuilder buffer = new StringBuilder(520);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0) return null;
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 2);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity) return null;
            }
            return StripPrefix(buffer.ToString(0, (int)length));
        }

        private static long Join(uint high, uint low)
        {
            return ((long)high << 32) | low;
        }

        private static DeleteStatus FromError(int error)
        {
            switch (error)
            {
                case 2: case 3: return DeleteStatus.Missing;    // file / path not found
                case 32: case 33: return DeleteStatus.InUse;    // sharing / lock violation
                case 5: return DeleteStatus.Denied;             // access denied (also: delete pending)
                case 145: return DeleteStatus.NotEmpty;         // directory not empty
                default: return DeleteStatus.Failed;
            }
        }

        /// <summary>True when path is strictly inside root (never equal to it).</summary>
        public static bool IsStrictlyUnder(string path, string root)
        {
            if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(root)) return false;
            string r = root.TrimEnd('\\');
            if (r.Length < 3) return false;    // never a drive root
            return path.Length > r.Length + 1 && path.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>The real, fully resolved path of an existing folder or file (links resolved, long names).</summary>
        public static string GetFinalPath(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            using (SafeFileHandle handle = CreateFileW(ToExtendedPath(path), FILE_READ_ATTRIBUTES, SHARE_ALL,
                IntPtr.Zero, OPEN_EXISTING, FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (handle.IsInvalid) return null;
                return FinalPathOf(handle);
            }
        }

        /// <summary>
        /// Deletes one file only if nobody else has it open, it is still inside rootFinal, it is unchanged
        /// since the analysis (size + last write) and both its timestamps are older than cutoff.
        /// All checks and the deletion use the same exclusive handle, so the file cannot be swapped in between.
        /// </summary>
        public static DeleteStatus DeleteFileChecked(string path, string rootFinal, long expectedSize, long expectedWrite, long cutoff)
        {
            if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(rootFinal)) return DeleteStatus.Unsafe;
            using (SafeFileHandle handle = CreateFileW(ToExtendedPath(path), DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                0 /* no sharing: fails if any other program has the file open */,
                IntPtr.Zero, OPEN_EXISTING, FLAG_OPEN_REPARSE_POINT, IntPtr.Zero))
            {
                if (handle.IsInvalid) return FromError(Marshal.GetLastWin32Error());

                FileInformation info;
                if (!GetFileInformationByHandle(handle, out info)) return DeleteStatus.Failed;
                if ((info.Attributes & FILE_KEEP) != 0) return DeleteStatus.Unsafe;
                if (info.Links != 1) return DeleteStatus.Unsafe;

                long size = Join(info.SizeHigh, info.SizeLow);
                long write = Join(info.WriteHigh, info.WriteLow);
                long created = Join(info.CreationHigh, info.CreationLow);
                if (size != expectedSize || write != expectedWrite) return DeleteStatus.Changed;
                if (write >= cutoff || created >= cutoff) return DeleteStatus.Changed;

                if (!IsStrictlyUnder(FinalPathOf(handle), rootFinal)) return DeleteStatus.Outside;

                byte deleteFlag = 1;
                if (!SetFileInformationByHandle(handle, FILE_DISPOSITION_INFO, ref deleteFlag, 1))
                    return FromError(Marshal.GetLastWin32Error());
                return DeleteStatus.Deleted;
            }
        }

        /// <summary>Removes a folder only if it is empty, not a link, not in use and strictly inside rootFinal.</summary>
        public static DeleteStatus DeleteEmptyFolderChecked(string path, string rootFinal)
        {
            if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(rootFinal)) return DeleteStatus.Unsafe;
            using (SafeFileHandle handle = CreateFileW(ToExtendedPath(path), DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                0, IntPtr.Zero, OPEN_EXISTING, FLAG_BACKUP_SEMANTICS | FLAG_OPEN_REPARSE_POINT, IntPtr.Zero))
            {
                if (handle.IsInvalid) return FromError(Marshal.GetLastWin32Error());

                FileInformation info;
                if (!GetFileInformationByHandle(handle, out info)) return DeleteStatus.Failed;
                if ((info.Attributes & ATTR_DIRECTORY) == 0 || (info.Attributes & FOLDER_KEEP) != 0) return DeleteStatus.Unsafe;
                if (!IsStrictlyUnder(FinalPathOf(handle), rootFinal)) return DeleteStatus.Outside;

                byte deleteFlag = 1;   // Windows refuses this for a folder that is not empty
                if (!SetFileInformationByHandle(handle, FILE_DISPOSITION_INFO, ref deleteFlag, 1))
                    return FromError(Marshal.GetLastWin32Error());
                return DeleteStatus.Deleted;
            }
        }

        /// <summary>The largest candidates first (for the details view).</summary>
        public static Candidate[] Largest(IList<Candidate> items, int count)
        {
            if (items == null) return new Candidate[0];
            Candidate[] all = new Candidate[items.Count];
            items.CopyTo(all, 0);
            Array.Sort(all, delegate (Candidate a, Candidate b) { return b.Size.CompareTo(a.Size); });
            if (count >= 0 && all.Length > count) Array.Resize(ref all, count);
            return all;
        }

        /// <summary>Folders ordered deepest first, so children are removed before their parents.</summary>
        public static FolderCandidate[] DeepestFirst(IList<FolderCandidate> items)
        {
            if (items == null) return new FolderCandidate[0];
            FolderCandidate[] all = new FolderCandidate[items.Count];
            items.CopyTo(all, 0);
            Array.Sort(all, delegate (FolderCandidate a, FolderCandidate b) { return b.Depth.CompareTo(a.Depth); });
            return all;
        }

        // ---- Recycle Bin (official shell API) ----

        [StructLayout(LayoutKind.Sequential)]
        private struct RecycleBinInfo { public uint Size; public long Bytes; public long Items; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct RecycleBinInfoPacked { public uint Size; public long Bytes; public long Items; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
        private static extern int QueryRecycleBinNative(string rootPath, ref RecycleBinInfo info);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
        private static extern int QueryRecycleBinPacked(string rootPath, ref RecycleBinInfoPacked info);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHEmptyRecycleBinW")]
        private static extern int EmptyRecycleBinNative(IntPtr owner, string rootPath, uint flags);

        /// <summary>Returns { bytes, items } for the Recycle Bin on all drives, or null.</summary>
        public static long[] QueryRecycleBin()
        {
            RecycleBinInfo info = new RecycleBinInfo();
            info.Size = (uint)Marshal.SizeOf(typeof(RecycleBinInfo));
            if (QueryRecycleBinNative(null, ref info) == 0) return new long[] { info.Bytes, info.Items };

            RecycleBinInfoPacked packed = new RecycleBinInfoPacked();
            packed.Size = (uint)Marshal.SizeOf(typeof(RecycleBinInfoPacked));
            if (QueryRecycleBinPacked(null, ref packed) == 0) return new long[] { packed.Bytes, packed.Items };
            return null;
        }

        /// <summary>Empties the Recycle Bin on all drives without any dialog. Returns the HRESULT.</summary>
        public static int EmptyRecycleBin()
        {
            const uint NoConfirmation = 0x1, NoProgressUi = 0x2, NoSound = 0x4;
            return EmptyRecycleBinNative(IntPtr.Zero, null, NoConfirmation | NoProgressUi | NoSound);
        }
    }

    /// <summary>Asks the windows of running apps to close, exactly like clicking their X button.</summary>
    public static class Apps
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

        /// <summary>Sends a normal close request to every visible top-level window of these processes.</summary>
        public static int CloseWindows(int[] processIds)
        {
            HashSet<uint> ids = new HashSet<uint>();
            foreach (int id in processIds) ids.Add((uint)id);
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate (IntPtr hwnd, IntPtr lParam)
            {
                uint processId;
                GetWindowThreadProcessId(hwnd, out processId);
                if (ids.Contains(processId) && IsWindowVisible(hwnd) && GetWindow(hwnd, 4) == IntPtr.Zero) windows.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            foreach (IntPtr hwnd in windows) PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
            return windows.Count;
        }
    }

    /// <summary>Small window helpers used by the app (DPI, dark title bar, console window).</summary>
    public static class Ui
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hwnd, string appName, string idList);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("kernel32.dll")]
        private static extern uint GetConsoleProcessList(uint[] processList, uint count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr hwnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hwnd, int command);

        public static bool EnableDpiAwareness()
        {
            try { return SetProcessDPIAware(); } catch { return false; }
        }

        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(hwnd, 20, ref value, 4) != 0)   // DWMWA_USE_IMMERSIVE_DARK_MODE
                    DwmSetWindowAttribute(hwnd, 19, ref value, 4);        // same, older Windows 10 builds
            }
            catch { }
        }

        public static void SetControlTheme(IntPtr hwnd, bool dark)
        {
            try { SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : "Explorer", null); } catch { }
        }

        /// <summary>
        /// Hides the console window, but only a classic console that belongs to this process alone,
        /// so a terminal the user is working in is never hidden.
        /// </summary>
        public static bool HideOwnConsoleWindow()
        {
            try
            {
                IntPtr console = GetConsoleWindow();
                if (console == IntPtr.Zero) return false;
                StringBuilder name = new StringBuilder(64);
                GetClassNameW(console, name, name.Capacity);
                if (name.ToString() != "ConsoleWindowClass") return false;
                uint[] ids = new uint[4];
                if (GetConsoleProcessList(ids, (uint)ids.Length) != 1) return false;
                return ShowWindow(console, 0);
            }
            catch { return false; }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ThemeOptions { public uint Flags; public uint Mask; }

        [DllImport("uxtheme.dll")]
        private static extern int SetWindowThemeAttribute(IntPtr hwnd, int attribute, ref ThemeOptions options, uint size);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

        /// <summary>
        /// Colors the title bar like the app (Windows 11; older Windows keep a dark or light title bar)
        /// and optionally hides the caption text and icon. They still show in the taskbar and Alt+Tab.
        /// Colors are COLORREF values (0x00BBGGRR).
        /// </summary>
        public static void StyleTitleBar(IntPtr hwnd, bool dark, int captionColor, int borderColor, bool hideCaption)
        {
            SetDarkTitleBar(hwnd, dark);
            try { DwmSetWindowAttribute(hwnd, 35, ref captionColor, 4); } catch { }   // DWMWA_CAPTION_COLOR
            try { DwmSetWindowAttribute(hwnd, 34, ref borderColor, 4); } catch { }    // DWMWA_BORDER_COLOR
            if (hideCaption)
            {
                try
                {
                    ThemeOptions options = new ThemeOptions();
                    options.Flags = 3;   // WTNCA_NODRAWCAPTION | WTNCA_NODRAWICON
                    options.Mask = 3;
                    SetWindowThemeAttribute(hwnd, 1, ref options, (uint)Marshal.SizeOf(typeof(ThemeOptions)));
                }
                catch { }
            }
            // Redraw the frame now, so the changes also show on a window that is already visible.
            try { SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020); } catch { }
        }
    }

    [ComImport, Guid("3c594f9f-9f30-47a1-979a-c9e83d3d0a06"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationDocumentLists
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);
        [PreserveSig] int GetList(int listType, uint itemsDesired, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
    }

    [ComImport, Guid("12337d35-94c6-48a0-bce7-6a9c69d4d600"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationDestinations
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);
        void RemoveDestination([MarshalAs(UnmanagedType.IUnknown)] object punk);
        void RemoveAllDestinations();   // never used: it is not limited to the entries Cleaner chose
    }

    [ComImport, Guid("92ca9dcd-5622-4bba-a805-5e9f541bd8c9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IObjectArray
    {
        void GetCount(out uint count);
        void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    /// <summary>
    /// Reads and removes entries of an app's taskbar Jump List (Recent and Frequent) through the official
    /// Windows interfaces. Only the exact entries passed to Remove are removed; pinned entries are left to the caller to exclude.
    /// </summary>
    public static class JumpList
    {
        private static readonly Guid DocumentListsClsid = new Guid("86bec222-30f2-47e0-9f25-60d11cd75c28");
        private static readonly Guid DestinationsClsid = new Guid("86c14003-4d6b-4ef3-a7b4-0506663b2e68");
        private const uint ParsingName = 0x80028000;   // SIGDN_DESKTOPABSOLUTEPARSING

        private static List<KeyValuePair<string, object>> Read(string appId)
        {
            var entries = new List<KeyValuePair<string, object>>();
            var lists = (IApplicationDocumentLists)Activator.CreateInstance(Type.GetTypeFromCLSID(DocumentListsClsid));
            lists.SetAppID(appId);
            Guid arrayId = typeof(IObjectArray).GUID;
            Guid itemId = typeof(IShellItem).GUID;
            foreach (int listType in new int[] { 0, 1 })   // ADLT_RECENT, ADLT_FREQUENT
            {
                object raw;
                if (lists.GetList(listType, 0, ref arrayId, out raw) != 0 || raw == null) continue;
                var array = (IObjectArray)raw;
                uint count;
                array.GetCount(out count);
                for (uint i = 0; i < count; i++)
                {
                    try
                    {
                        object item;
                        array.GetAt(i, ref itemId, out item);
                        string name;
                        ((IShellItem)item).GetDisplayName(ParsingName, out name);
                        if (!string.IsNullOrEmpty(name)) entries.Add(new KeyValuePair<string, object>(name, item));
                    }
                    catch { }
                }
            }
            return entries;
        }

        public static string[] GetEntries(string appId)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var names = new List<string>();
            foreach (var entry in Read(appId)) { if (seen.Add(entry.Key)) names.Add(entry.Key); }
            return names.ToArray();
        }

        public static int Remove(string appId, string[] names)
        {
            var wanted = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
            if (wanted.Count == 0) return 0;
            var destinations = (IApplicationDestinations)Activator.CreateInstance(Type.GetTypeFromCLSID(DestinationsClsid));
            destinations.SetAppID(appId);
            var done = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in Read(appId))
            {
                if (!wanted.Contains(entry.Key)) continue;
                try { destinations.RemoveDestination(entry.Value); done.Add(entry.Key); } catch { }
            }
            return done.Count;
        }
    }
}
'@

if (-not ('CleanerNative.SafeIO' -as [type])) {
    Add-Type -TypeDefinition $script:NativeSource -ErrorAction Stop
}

# ----------------------------------------------------------------------------------------------
#  Constants
# ----------------------------------------------------------------------------------------------

# File types that are never deleted, wherever they are found.
$script:NeverDeleteExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(
        # AI / machine-learning models and weights
        '.safetensors', '.gguf', '.ggml', '.ckpt', '.pt', '.pth', '.onnx', '.bin', '.h5', '.keras', '.tflite', '.pb', '.mlmodel',
        # Virtual machine and disk images
        '.vhd', '.vhdx', '.vmdk', '.vdi', '.qcow2', '.iso',
        # Keys, certificates and password stores
        '.key', '.pem', '.pfx', '.p12', '.ppk', '.kdbx',
        # Databases
        '.db', '.sqlite', '.sqlite3', '.mdf', '.ldf', '.accdb',
        # Documents (in case you edited a file you opened from an e-mail or a ZIP file)
        '.doc', '.docx', '.docm', '.xls', '.xlsx', '.xlsm', '.ppt', '.pptx', '.pptm', '.odt', '.ods', '.odp', '.rtf', '.pdf', '.psd'
    )) { [void]$script:NeverDeleteExtensions.Add($extension) }

# ReadOnly | System | Offline | RecallOnOpen | Pinned | Unpinned | RecallOnDataAccess
$script:KeepAttributes = 0x1 -bor 0x4 -bor 0x1000 -bor 0x40000 -bor 0x80000 -bor 0x100000 -bor 0x400000
$script:MaxFilesPerRule = 400000

$script:Groups = [ordered]@{
    System    = 'System'
    Browsers  = 'Web browsers'
    Activity  = 'Browsing activity'
    Apps      = 'Apps'
    Privacy   = 'Privacy'
    Developer = 'Developer tools'
    Graphics  = 'Graphics'
    Admin     = 'Windows (administrator)'
}

$script:ChromiumCacheFolders = @(
    'Cache\Cache_Data', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
    'GrShaderCache', 'GraphiteDawnCache', 'ShaderCache', 'Media Cache'
)
# Only in the browser's main data folder: downloaded copies of browser components (re-downloaded when needed).
$script:ChromiumRootCacheFolders = @('component_crx_cache')
# The exact files that hold browsing activity. Only these names can ever match: passwords (Login Data), cookies,
# bookmarks, form data (Web Data), settings, extensions and open tabs (Sessions) live in other files and are never listed here.
$script:ChromiumHistoryFiles = @(
    'History', 'History-journal', 'Visited Links', 'Top Sites', 'Top Sites-journal',
    'Shortcuts', 'Shortcuts-journal', 'Network Action Predictor', 'Network Action Predictor-journal'
)

$script:IsAdmin = $null
$script:ProtectedPaths = $null

# ----------------------------------------------------------------------------------------------
#  General helpers
# ----------------------------------------------------------------------------------------------

function Get-CleanerVersion { $script:EngineVersion }

function Get-CleanerGroup { $script:Groups }

function Test-CleanerAdmin {
    if ($null -eq $script:IsAdmin) {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { $script:IsAdmin = $false }
    }
    return [bool]$script:IsAdmin
}

function Format-CleanerSize {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return ('{0:N0} B' -f $Bytes) }
    $units = @('KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $index = -1
    do { $value = $value / 1024; $index++ } while ($value -ge 1024 -and $index -lt ($units.Count - 1))
    if ($index -eq 0 -or $value -ge 100) { return ('{0:N0} {1}' -f $value, $units[$index]) }
    return ('{0:N1} {1}' -f $value, $units[$index])
}

$script:DataFolderOverride = $null  # tests point this at their sandbox
$script:LogFolderOverride = $null   # tests point this at their sandbox

function Get-CleanerDataFolder {
    if ($script:DataFolderOverride) { return $script:DataFolderOverride }
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Cleaner'
}

function Get-CleanerLogFolder {
    if ($script:LogFolderOverride) { return $script:LogFolderOverride }
    Join-Path (Get-CleanerDataFolder) 'Logs'
}

function Test-CleanerCancel {
    param([hashtable]$Sync)
    if ($null -ne $Sync -and $Sync['Cancel']) { throw (New-Object System.OperationCanceledException 'Cancelled by the user.') }
}

function Set-CleanerProgress {
    param([hashtable]$Sync, [string]$Status, [int]$Percent = -1, [string]$Detail, [string]$Current)
    if ($null -eq $Sync) { return }
    if ($PSBoundParameters.ContainsKey('Status')) { $Sync['Status'] = $Status }
    if ($PSBoundParameters.ContainsKey('Percent')) { $Sync['Percent'] = $Percent }
    if ($PSBoundParameters.ContainsKey('Detail')) { $Sync['Detail'] = $Detail }
    if ($PSBoundParameters.ContainsKey('Current')) { $Sync['Current'] = $Current }
}

# ----------------------------------------------------------------------------------------------
#  Path safety
# ----------------------------------------------------------------------------------------------

function Get-CleanerProtectedPath {
    <#
        Folders that must never be cleaned, and that no cleanup location may contain:
        drive roots, Windows and program folders, the user profile and every personal folder.
    #>
    if ($null -ne $script:ProtectedPaths) { return $script:ProtectedPaths }

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try {
            $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
            if ($full) { [void]$set.Add($full) }
        }
        catch { }
    }

    foreach ($name in @('Windows', 'System', 'SystemX86', 'ProgramFiles', 'ProgramFilesX86', 'CommonProgramFiles',
            'CommonProgramFilesX86', 'CommonApplicationData', 'UserProfile', 'Desktop', 'DesktopDirectory', 'MyDocuments',
            'MyPictures', 'MyMusic', 'MyVideos', 'ApplicationData', 'LocalApplicationData', 'Favorites', 'StartMenu',
            'Programs', 'Startup', 'Templates', 'CommonDesktopDirectory', 'CommonDocuments', 'CommonStartMenu',
            'CommonPrograms', 'CommonTemplates', 'CommonMusic', 'CommonPictures', 'CommonVideos', 'Fonts')) {
        try { & $add ([Environment]::GetFolderPath($name)) } catch { }
    }

    # Every shell folder of this user (Downloads, Saved Games, redirected folders ...).
    # "Recent" is the one exception: it only holds shortcuts and is the target of the Recent files rule.
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        foreach ($property in $shellFolders.PSObject.Properties) {
            if ($property.Name -notlike 'PS*' -and $property.Name -ne 'Recent' -and $property.Value -is [string]) { & $add $property.Value }
        }
    }
    catch { }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    foreach ($path in @(
            (Join-Path $userProfile 'Downloads'), (Join-Path $userProfile 'OneDrive'), (Join-Path $userProfile '.ssh'),
            (Join-Path $userProfile '.cache'), (Join-Path $userProfile '.ollama'), (Join-Path $userProfile '.lmstudio'),
            $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial, $env:PUBLIC,
            (Split-Path -Parent $userProfile),
            (Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'SysWOW64'), (Join-Path $env:WINDIR 'WinSxS'),
            (Join-Path $env:WINDIR 'Installer'), (Join-Path $env:WINDIR 'SoftwareDistribution'), (Join-Path $env:WINDIR 'Prefetch')
        )) { & $add $path }

    try {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) { & $add $drive.RootDirectory.FullName }
    }
    catch { }
    if ($env:SystemDrive) { & $add ($env:SystemDrive + '\') }

    $script:ProtectedPaths = @($set)
    return $script:ProtectedPaths
}

function Test-CleanerRootPath {
    <#
        Returns $null when a fully resolved folder path may be used as a cleanup location,
        otherwise a short reason why it is refused.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'The folder could not be resolved.' }
    if ($Path -match '^[A-Za-z]:\\?$') { return 'A whole drive is never cleaned.' }
    if ($Path -notmatch '^[A-Za-z]:\\[^\\]') { return 'Only folders on a local drive are cleaned.' }
    try {
        $drive = New-Object IO.DriveInfo($Path.Substring(0, 1))
        if ($drive.DriveType -ne [IO.DriveType]::Fixed) { return 'Only folders on a fixed local drive are cleaned.' }
    }
    catch { return 'The drive could not be checked.' }

    $candidate = $Path.TrimEnd('\')
    foreach ($protected in (Get-CleanerProtectedPath)) {
        if ($candidate.Equals($protected, [StringComparison]::OrdinalIgnoreCase)) {
            return "It is a protected folder ($protected)."
        }
        if ($protected.StartsWith($candidate + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return "It contains a protected folder ($protected)."
        }
    }
    return $null
}

function Test-CleanerLinkFree {
    <# True when the folder exists and neither it nor any parent folder is a junction or symbolic link. #>
    param([string]$Path)
    try {
        $dir = New-Object IO.DirectoryInfo($Path)
        if (-not $dir.Exists) { return $false }
        while ($null -ne $dir) {
            if (([int]$dir.Attributes -band 0x400) -ne 0) { return $false }
            $dir = $dir.Parent
        }
        return $true
    }
    catch { return $false }
}

function Get-CleanerSubdirectory {
    <# Real (non-link) subfolders of a folder; nothing when it does not exist. #>
    param([string]$Path)
    $list = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    try {
        if ([IO.Directory]::Exists($Path)) {
            foreach ($dir in (New-Object IO.DirectoryInfo($Path)).EnumerateDirectories()) {
                if (([int]$dir.Attributes -band 0x400) -eq 0) { $list.Add($dir) }
            }
        }
    }
    catch { }
    return $list.ToArray()
}

# ----------------------------------------------------------------------------------------------
#  Rules (the built-in list of what may be cleaned)
# ----------------------------------------------------------------------------------------------

function New-CleanerTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse,
        [string[]]$Include = @('*'),
        [string[]]$ExcludeName = @(),
        [string[]]$AllowExtension = @(),
        [switch]$RemoveEmptyFolders
    )
    [pscustomobject]@{
        Path               = $Path
        Recurse            = [bool]$Recurse
        Include            = @($Include)
        ExcludeName        = @($ExcludeName)
        AllowExtension     = @($AllowExtension)
        RemoveEmptyFolders = [bool]$RemoveEmptyFolders
    }
}

function New-CleanerRule {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Files', 'RecycleBin', 'ExplorerRecent')][string]$Kind = 'Files',
        [object[]]$Targets = @(),
        [ValidateRange(0, 3650)][int]$MinAgeDays = 0,
        [string[]]$Processes = @(),
        [string]$AppName = '',
        [switch]$RequiresAdmin,
        [switch]$Recommended,
        [switch]$Caution,
        [string]$Note = ''
    )
    $existing = @($Targets | Where-Object { $null -ne $_ -and [IO.Directory]::Exists($_.Path) })
    [pscustomobject]@{
        Id            = $Id
        Group         = $Group
        Name          = $Name
        Description   = $Description
        Kind          = $Kind
        Targets       = @($Targets)
        Locations     = @($existing | ForEach-Object { $_.Path })
        MinAgeDays    = $MinAgeDays
        Processes     = @($Processes)
        AppName       = $AppName
        RequiresAdmin = [bool]$RequiresAdmin
        Recommended   = [bool]$Recommended
        Caution       = [bool]$Caution
        Note          = $Note
        Available     = ($Kind -ne 'Files') -or ($existing.Count -gt 0)
    }
}

function Get-ChromiumCacheTarget {
    <# Cache folders of a Chromium-based browser or Electron app (only caches - never profile data). #>
    param([string]$DataPath)
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-CleanerLinkFree -Path $DataPath)) { return $targets.ToArray() }

    $profileDirs = New-Object 'System.Collections.Generic.List[string]'
    $profileDirs.Add($DataPath)
    foreach ($sub in (Get-CleanerSubdirectory -Path $DataPath)) {
        if ($sub.Name -match '^(Default|Profile \d+|Guest Profile|System Profile)$') { $profileDirs.Add($sub.FullName) }
    }
    foreach ($profileDir in $profileDirs) {
        foreach ($relative in $script:ChromiumCacheFolders) {
            $full = Join-Path $profileDir $relative
            if ([IO.Directory]::Exists($full)) { $targets.Add((New-CleanerTarget -Path $full -Recurse)) }
        }
    }
    foreach ($relative in $script:ChromiumRootCacheFolders) {
        $full = Join-Path $DataPath $relative
        if ([IO.Directory]::Exists($full)) { $targets.Add((New-CleanerTarget -Path $full -Recurse)) }
    }
    return $targets.ToArray()
}

function Get-ChromiumHistoryTarget {
    <# The browsing activity files of each normal profile of a Chromium-based browser (exact file names, no subfolders). #>
    param([string]$DataPath)
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-CleanerLinkFree -Path $DataPath)) { return $targets.ToArray() }

    $profileDirs = New-Object 'System.Collections.Generic.List[string]'
    $profileDirs.Add($DataPath)
    foreach ($sub in (Get-CleanerSubdirectory -Path $DataPath)) {
        if ($sub.Name -match '^(Default|Profile \d+)$') { $profileDirs.Add($sub.FullName) }
    }
    foreach ($profileDir in $profileDirs) {
        $found = @($script:ChromiumHistoryFiles | Where-Object { [IO.File]::Exists((Join-Path $profileDir $_)) })
        if ($found.Count -gt 0) { $targets.Add((New-CleanerTarget -Path $profileDir -Include $script:ChromiumHistoryFiles)) }
    }
    return $targets.ToArray()
}

function Get-CleanerRule {
    <#
    .SYNOPSIS
        The built-in cleanup rules. Only rules whose folders exist on this PC are returned,
        unless -IncludeUnavailable is used.
    #>
    [CmdletBinding()]
    param([switch]$IncludeUnavailable)

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    $windows = [Environment]::GetFolderPath('Windows')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')

    $all = New-Object 'System.Collections.Generic.List[object]'
    $add = { param([hashtable]$Spec) $all.Add((New-CleanerRule @Spec)) }

    # ---------------------------------------------------------------- System
    $userTemp = Join-Path $local 'Temp'
    $tempTargets = New-Object 'System.Collections.Generic.List[object]'
    $tempTargets.Add((New-CleanerTarget -Path $userTemp -Recurse -RemoveEmptyFolders))
    try {
        # A TEMP variable pointing somewhere else is only followed if that folder is really called Temp/Tmp.
        $sessionTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $inside = $sessionTemp.Equals($userTemp, [StringComparison]::OrdinalIgnoreCase) -or
                  $sessionTemp.StartsWith($userTemp + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $inside -and (Split-Path -Leaf $sessionTemp) -match '^(temp|tmp)$') {
            $tempTargets.Add((New-CleanerTarget -Path $sessionTemp -Recurse -RemoveEmptyFolders))
        }
    }
    catch { }

    & $add @{
        Id = 'temp'; Group = 'System'; Name = 'Temporary files'
        Description = 'Leftovers from apps and installers that are older than 7 days.'
        Targets = $tempTargets.ToArray(); MinAgeDays = 7; Recommended = $true
    }
    & $add @{
        Id = 'error-reports'; Group = 'System'; Name = 'Error reports and crash dumps'
        Description = 'Windows error reports and app crash dumps older than 30 days.'
        Targets = @(
            (New-CleanerTarget -Path (Join-Path $local 'Microsoft\Windows\WER\ReportArchive') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $local 'Microsoft\Windows\WER\ReportQueue') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $local 'CrashDumps') -Include '*.dmp')
        )
        MinAgeDays = 30; Recommended = $true
    }
    & $add @{
        Id = 'recycle-bin'; Group = 'System'; Name = 'Recycle Bin'; Kind = 'RecycleBin'
        Description = 'Permanently empties the Recycle Bin on all drives.'
        Caution = $true; Note = 'Review the Recycle Bin first - emptying it cannot be undone.'
    }

    # ---------------------------------------------------------------- Browsers
    $browserText = 'Cached images and files. Passwords, cookies and history stay.'
    foreach ($browser in @(
            @{ Id = 'chrome';   Name = 'Google Chrome';  Path = (Join-Path $local 'Google\Chrome\User Data');               Process = 'chrome' },
            @{ Id = 'edge';     Name = 'Microsoft Edge'; Path = (Join-Path $local 'Microsoft\Edge\User Data');              Process = 'msedge' },
            @{ Id = 'brave';    Name = 'Brave';          Path = (Join-Path $local 'BraveSoftware\Brave-Browser\User Data'); Process = 'brave' },
            @{ Id = 'vivaldi';  Name = 'Vivaldi';        Path = (Join-Path $local 'Vivaldi\User Data');                     Process = 'vivaldi' },
            @{ Id = 'opera';    Name = 'Opera';          Path = (Join-Path $local 'Opera Software\Opera Stable');           Process = 'opera' },
            @{ Id = 'opera-gx'; Name = 'Opera GX';       Path = (Join-Path $local 'Opera Software\Opera GX Stable');        Process = 'opera' }
        )) {
        & $add @{
            Id = $browser.Id; Group = 'Browsers'; Name = $browser.Name; Description = $browserText
            Targets = @(Get-ChromiumCacheTarget -DataPath $browser.Path)
            Processes = @($browser.Process); AppName = $browser.Name; Recommended = $true
        }
        # Never preselected: history cannot be brought back.
        & $add @{
            Id = ($browser.Id + '-history'); Group = 'Activity'; Name = ($browser.Name + ' history')
            Description = 'Visited sites, searches and the download list. Passwords and cookies stay.'
            Targets = @(Get-ChromiumHistoryTarget -DataPath $browser.Path)
            Processes = @($browser.Process); AppName = $browser.Name; Caution = $true
            Note = 'Cannot be undone. Address bar suggestions start fresh; downloaded files stay. If browser sync is on, your account can bring the history back.'
        }
    }

    $firefoxTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ffProfile in (Get-CleanerSubdirectory -Path (Join-Path $local 'Mozilla\Firefox\Profiles'))) {
        foreach ($relative in @('cache2\entries', 'cache2\doomed', 'startupCache')) {
            $full = Join-Path $ffProfile.FullName $relative
            if ([IO.Directory]::Exists($full)) { $firefoxTargets.Add((New-CleanerTarget -Path $full -Recurse)) }
        }
    }
    & $add @{
        Id = 'firefox'; Group = 'Browsers'; Name = 'Mozilla Firefox'; Description = $browserText
        Targets = $firefoxTargets.ToArray(); Processes = @('firefox'); AppName = 'Firefox'; Recommended = $true
    }

    # ---------------------------------------------------------------- Apps (Chromium/Electron caches)
    foreach ($app in @(
            @{ Id = 'discord'; Name = 'Discord';            Path = (Join-Path $roaming 'discord'); Process = 'Discord' },
            @{ Id = 'slack';   Name = 'Slack';              Path = (Join-Path $roaming 'Slack');   Process = 'slack' },
            @{ Id = 'vscode';  Name = 'Visual Studio Code'; Path = (Join-Path $roaming 'Code');    Process = 'Code' },
            @{ Id = 'cursor';  Name = 'Cursor';             Path = (Join-Path $roaming 'Cursor');  Process = 'Cursor' }
        )) {
        & $add @{
            Id = $app.Id; Group = 'Apps'; Name = $app.Name
            Description = 'Cached web content. Settings, extensions and sign-in are kept.'
            Targets = @(Get-ChromiumCacheTarget -DataPath $app.Path)
            Processes = @($app.Process); AppName = $app.Name; Recommended = $true
        }
    }

    # ---------------------------------------------------------------- Privacy
    $recent = Join-Path $roaming 'Microsoft\Windows\Recent'
    & $add @{
        Id = 'recent-files'; Group = 'Privacy'; Name = 'Recent files list'
        Description = 'Shortcuts to recently opened files. Your files are not touched.'
        Targets = @((New-CleanerTarget -Path $recent -Include '*.lnk')); Recommended = $true
    }
    & $add @{
        Id = 'explorer-recent'; Group = 'Privacy'; Name = 'File Explorer recent folders'; Kind = 'ExplorerRecent'
        Description = 'Recent folders in File Explorer and its taskbar list. Pinned folders stay.'
        Recommended = $true
        Note = 'Only the list is cleared - the folders themselves are never touched.'
    }
    & $add @{
        Id = 'jump-lists'; Group = 'Privacy'; Name = 'Jump Lists'
        Description = 'Recent items in taskbar and Start jump lists. Quick Access pins are kept.'
        Targets = @(
            # f01b4d95cf55d32a = File Explorer (Quick Access pinned folders) - never removed.
            (New-CleanerTarget -Path (Join-Path $recent 'AutomaticDestinations') -Include '*.automaticDestinations-ms' -ExcludeName 'f01b4d95cf55d32a.automaticDestinations-ms'),
            (New-CleanerTarget -Path (Join-Path $recent 'CustomDestinations') -Include '*.customDestinations-ms')
        )
        Caution = $true; Note = 'Items you pinned inside an app''s Jump List are removed too.'
    }

    # ---------------------------------------------------------------- Developer tools
    & $add @{
        Id = 'pip-cache'; Group = 'Developer'; Name = 'pip download cache'
        Description = 'Python downloads older than 30 days. Built wheels are kept.'
        Targets = @(
            (New-CleanerTarget -Path (Join-Path $local 'pip\Cache\http-v2') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $local 'pip\Cache\http') -Recurse -RemoveEmptyFolders)
        )
        MinAgeDays = 30
    }
    & $add @{
        Id = 'npm-cache'; Group = 'Developer'; Name = 'npm cache'
        Description = 'Node.js package downloads older than 30 days.'
        Targets = @(
            (New-CleanerTarget -Path (Join-Path $local 'npm-cache\_cacache\content-v2') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $roaming 'npm-cache\_cacache\content-v2') -Recurse -RemoveEmptyFolders)
        )
        MinAgeDays = 30
    }
    & $add @{
        Id = 'nuget-cache'; Group = 'Developer'; Name = 'NuGet HTTP cache'
        Description = 'NuGet download cache older than 30 days. Packages are kept.'
        Targets = @((New-CleanerTarget -Path (Join-Path $local 'NuGet\v3-cache') -Recurse -RemoveEmptyFolders))
        MinAgeDays = 30
    }

    # ---------------------------------------------------------------- Graphics
    & $add @{
        Id = 'shader-cache'; Group = 'Graphics'; Name = 'Graphics shader cache'
        Description = 'DirectX and GPU driver shader caches older than 30 days.'
        Targets = @(
            (New-CleanerTarget -Path (Join-Path $local 'D3DSCache') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $local 'NVIDIA\DXCache') -Recurse),
            (New-CleanerTarget -Path (Join-Path $local 'NVIDIA\GLCache') -Recurse -RemoveEmptyFolders -AllowExtension '.bin'),
            (New-CleanerTarget -Path (Join-Path $local 'AMD\DxCache') -Recurse),
            (New-CleanerTarget -Path (Join-Path $local 'AMD\DxcCache') -Recurse),
            (New-CleanerTarget -Path (Join-Path $local 'AMD\GLCache') -Recurse),
            (New-CleanerTarget -Path (Join-Path $local 'AMD\VkCache') -Recurse),
            (New-CleanerTarget -Path (Join-Path $local 'Intel\ShaderCache') -Recurse)
        )
        MinAgeDays = 30; Note = 'Games may load a little slower the first time after cleaning. NVIDIA ComputeCache (CUDA/AI) is never touched.'
    }

    # ---------------------------------------------------------------- Windows (administrator)
    & $add @{
        Id = 'windows-temp'; Group = 'Admin'; Name = 'Windows temporary files'
        Description = 'System-wide temporary files older than 14 days.'
        Targets = @((New-CleanerTarget -Path (Join-Path $windows 'Temp') -Recurse -RemoveEmptyFolders))
        MinAgeDays = 14; RequiresAdmin = $true; Recommended = $true
    }
    & $add @{
        Id = 'system-reports'; Group = 'Admin'; Name = 'System error reports and dumps'
        Description = 'System crash reports and memory dumps older than 30 days.'
        Targets = @(
            (New-CleanerTarget -Path (Join-Path $programData 'Microsoft\Windows\WER\ReportArchive') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $programData 'Microsoft\Windows\WER\ReportQueue') -Recurse -RemoveEmptyFolders),
            (New-CleanerTarget -Path (Join-Path $windows 'Minidump') -Include '*.dmp'),
            (New-CleanerTarget -Path (Join-Path $windows 'LiveKernelReports') -Recurse -Include '*.dmp')
        )
        MinAgeDays = 30; RequiresAdmin = $true; Recommended = $true
    }

    foreach ($rule in $all) {
        if ($rule.Available -or $IncludeUnavailable) { $rule }
    }
}

# ----------------------------------------------------------------------------------------------
#  Settings and log
# ----------------------------------------------------------------------------------------------

$script:Themes = @('System', 'Dark', 'Light')

function Read-CleanerSettings {
    <#
        Saved choices and statistics:
          Theme (System | Dark | Light), Rules (id -> selected), LastCleanedAt, LastFreedBytes, TotalFreedBytes.
        Imports the choices of version 1 (StartMenuCleaner) once.
    #>
    $settings = @{ Version = 3; Theme = 'System'; Rules = @{}; LastCleanedAt = $null; LastFreedBytes = [long]0; TotalFreedBytes = [long]0 }
    try {
        $file = Join-Path (Get-CleanerDataFolder) 'settings.json'
        if ([IO.File]::Exists($file)) {
            $json = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            $properties = $json.PSObject.Properties
            if ($properties['Theme'] -and $script:Themes -contains [string]$json.Theme) { $settings.Theme = [string]$json.Theme }
            elseif ($properties['FollowSystemTheme'] -and $json.FollowSystemTheme -is [bool]) {
                $settings.Theme = $(if ($json.FollowSystemTheme) { 'System' } else { 'Light' })
            }
            if ($properties['Rules'] -and $null -ne $json.Rules) {
                foreach ($property in $json.Rules.PSObject.Properties) {
                    if ($property.Value -is [bool]) { $settings.Rules[$property.Name] = $property.Value }
                }
            }
            if ($properties['LastCleanedAt'] -and $json.LastCleanedAt) {
                $value = $json.LastCleanedAt
                if ($value -is [DateTime]) { $settings.LastCleanedAt = $value }
                else {
                    $parsed = [DateTime]::MinValue
                    if ([DateTime]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                        $settings.LastCleanedAt = $parsed
                    }
                }
                if ($settings.LastCleanedAt -is [DateTime] -and $settings.LastCleanedAt.Kind -eq [DateTimeKind]::Utc) {
                    $settings.LastCleanedAt = $settings.LastCleanedAt.ToLocalTime()
                }
            }
            foreach ($name in @('LastFreedBytes', 'TotalFreedBytes')) {
                if ($properties[$name]) { try { $settings[$name] = [long]$json.$name } catch { } }
            }
            return $settings
        }

        $old = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'StartMenuCleaner\settings.json'
        if ([IO.File]::Exists($old)) {
            $json = [IO.File]::ReadAllText($old) | ConvertFrom-Json
            $properties = $json.PSObject.Properties
            if ($properties['ClearRecentShortcuts'] -and $json.ClearRecentShortcuts -is [bool]) { $settings.Rules['recent-files'] = $json.ClearRecentShortcuts }
            if ($properties['ClearJumpLists'] -and $json.ClearJumpLists -is [bool]) { $settings.Rules['jump-lists'] = $json.ClearJumpLists }
            if ($properties['FollowSystemDarkMode'] -and $json.FollowSystemDarkMode -is [bool]) {
                $settings.Theme = $(if ($json.FollowSystemDarkMode) { 'System' } else { 'Light' })
            }
        }
    }
    catch { }   # unreadable settings: use the defaults
    return $settings
}

function Save-CleanerSettings {
    param([Parameter(Mandatory = $true)][hashtable]$Settings)
    $folder = Get-CleanerDataFolder
    if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }

    $rules = [ordered]@{}
    if ($Settings['Rules'] -is [hashtable]) {
        foreach ($key in @($Settings['Rules'].Keys | Sort-Object)) { $rules[$key] = [bool]$Settings['Rules'][$key] }
    }
    $theme = [string]$Settings['Theme']
    if ($script:Themes -notcontains $theme) { $theme = 'System' }
    $lastCleaned = $Settings['LastCleanedAt']
    $data = [ordered]@{
        Version         = 3
        Theme           = $theme
        LastCleanedAt   = $(if ($lastCleaned -is [DateTime]) { $lastCleaned.ToString('o') } else { $null })
        LastFreedBytes  = [long]$Settings['LastFreedBytes']
        TotalFreedBytes = [long]$Settings['TotalFreedBytes']
        Rules           = $rules
    }

    $file = Join-Path $folder 'settings.json'
    $temp = $file + '.tmp'
    $json = $data | ConvertTo-Json -Depth 4
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 1; ; $attempt++) {
        try {
            # Write a temporary file, then swap it in, so a crash never leaves a half-written settings file.
            [IO.File]::WriteAllText($temp, $json, $encoding)
            # [NullString]::Value = "no backup file". A plain $null would reach .NET as '' (an invalid path).
            if ([IO.File]::Exists($file)) { [IO.File]::Replace($temp, $file, [NullString]::Value) } else { [IO.File]::Move($temp, $file) }
            return
        }
        catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Milliseconds (60 * $attempt)    # another program (for example antivirus) may hold the file briefly
        }
    }
}

function Open-CleanerLog {
    try {
        $folder = Get-CleanerLogFolder
        if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
        $path = Join-Path $folder ('Cleaner-{0:yyyy-MM-dd}.log' -f [DateTime]::Now)
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        return (New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false))))
    }
    catch { return $null }
}

function Write-CleanerLog {
    param($Writer, [string]$Kind, [string]$Message)
    if ($null -eq $Writer) { return }
    try { $Writer.WriteLine(('{0:yyyy-MM-dd HH:mm:ss}  {1,-8} {2}' -f [DateTime]::Now, $Kind, $Message)) } catch { }
}

function Add-CleanerLogEntry {
    <# Writes one line to today's log (used by the app for errors). #>
    param([string]$Kind = 'INFO', [string]$Message)
    $writer = Open-CleanerLog
    if ($null -eq $writer) { return }
    try { Write-CleanerLog $writer $Kind $Message } finally { $writer.Dispose() }
}

function Remove-CleanerOldLog {
    <# Deletes Cleaner's own log files older than KeepDays (only Cleaner-*.log in its own Logs folder). #>
    param([int]$KeepDays = 30)
    try {
        $folder = Get-CleanerLogFolder
        if (-not [IO.Directory]::Exists($folder)) { return }
        $cutoff = [DateTime]::Now.AddDays(-$KeepDays)
        foreach ($file in (New-Object IO.DirectoryInfo($folder)).EnumerateFiles('Cleaner-*.log')) {
            if ($file.LastWriteTime -lt $cutoff -and ([int]$file.Attributes -band 0x400) -eq 0) { $file.Delete() }
        }
    }
    catch { }
}

# ----------------------------------------------------------------------------------------------
#  Running apps
# ----------------------------------------------------------------------------------------------

function Get-CleanerRunningApp {
    <# Process names of the rule's app that are running in this Windows session. #>
    param([Parameter(Mandatory = $true)]$Rule)
    $running = New-Object 'System.Collections.Generic.List[string]'
    if (@($Rule.Processes).Count -eq 0) { return $running.ToArray() }

    $session = -1
    $myId = -1
    try {
        $me = [Diagnostics.Process]::GetCurrentProcess()
        $session = $me.SessionId
        $myId = $me.Id
    }
    catch { }

    foreach ($name in $Rule.Processes) {
        $processes = @()
        try { $processes = [Diagnostics.Process]::GetProcessesByName($name) }
        catch { if (-not $running.Contains($name)) { $running.Add($name) }; continue }   # cannot check: assume running
        foreach ($process in $processes) {
            try {
                if ($process.Id -ne $myId -and ($session -lt 0 -or $process.SessionId -eq $session)) {
                    if (-not $running.Contains($name)) { $running.Add($name) }
                }
            }
            catch { if (-not $running.Contains($name)) { $running.Add($name) } }
            finally { $process.Dispose() }
        }
    }
    return $running.ToArray()
}

function Close-CleanerApp {
    <#
        Closes the app that owns a rule's cache: only processes with the rule's fixed names (browsers and
        apps) and only in this Windows session. Without -Force every main window is asked to close normally,
        like clicking its X button, so the app can save or ask to save. -Force ends the processes.
        Returns how many processes were asked to close or were ended.
    #>
    param([Parameter(Mandatory = $true)]$Rule, [switch]$Force)
    $count = 0
    if (@($Rule.Processes).Count -eq 0) { return 0 }
    $session = -1
    $myId = -1
    try {
        $me = [Diagnostics.Process]::GetCurrentProcess()
        $session = $me.SessionId
        $myId = $me.Id
    }
    catch { }
    $ids = New-Object 'System.Collections.Generic.List[int]'
    foreach ($name in $Rule.Processes) {
        $processes = @()
        try { $processes = [Diagnostics.Process]::GetProcessesByName($name) } catch { continue }
        foreach ($process in $processes) {
            try {
                if ($process.Id -eq $myId -or ($session -ge 0 -and $process.SessionId -ne $session)) { continue }
                if ($Force) { $process.Kill(); $count++ }
                else { $ids.Add($process.Id) }
            }
            catch { }
            finally { $process.Dispose() }
        }
    }
    if (-not $Force -and $ids.Count -gt 0) { $count = [CleanerNative.Apps]::CloseWindows($ids.ToArray()) }
    return $count
}

# ----------------------------------------------------------------------------------------------
#  Analysis (read-only: nothing is changed on disk)
# ----------------------------------------------------------------------------------------------

function New-CleanerScanResult {
    param($Rule)
    [pscustomobject]@{
        RuleId            = $Rule.Id
        Rule              = $Rule
        State             = 'Pending'    # Ready | Empty | Blocked | Unavailable | Error | Cancelled
        Message           = ''
        Files             = New-Object 'System.Collections.Generic.List[CleanerNative.Candidate]'
        Folders           = New-Object 'System.Collections.Generic.List[CleanerNative.FolderCandidate]'
        Roots             = New-Object 'System.Collections.Generic.List[object]'
        Notes             = New-Object 'System.Collections.Generic.List[string]'
        Bytes             = [long]0
        Count             = [long]0
        SkippedRecent     = [long]0
        SkippedProtected  = [long]0
        SkippedLinks      = [long]0
        SkippedUnreadable = [long]0
        LimitReached      = $false
        Cutoff            = [long]0
        ScannedAt         = [DateTime]::Now
        RunningApps       = @()
    }
}

function Invoke-CleanerTargetScan {
    param($Result, $Target, [int]$RootIndex, [hashtable]$Sync)

    $cutoff = [long]$Result.Cutoff
    $keep = $script:KeepAttributes
    $never = $script:NeverDeleteExtensions
    $files = $Result.Files
    $folders = $Result.Folders
    $recurse = [bool]$Target.Recurse
    $collectFolders = $recurse -and [bool]$Target.RemoveEmptyFolders
    $max = $script:MaxFilesPerRule

    $patterns = $null
    $includes = @($Target.Include)
    if (-not ($includes.Count -eq 1 -and $includes[0] -eq '*')) {
        $patterns = @(foreach ($include in $includes) {
                New-Object Management.Automation.WildcardPattern($include, [Management.Automation.WildcardOptions]::IgnoreCase)
            })
    }
    $exclude = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Target.ExcludeName) { [void]$exclude.Add($name) }
    $allow = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $Target.AllowExtension) { [void]$allow.Add($extension) }

    [long]$bytes = 0; [long]$recent = 0; [long]$protected = 0; [long]$links = 0; [long]$unreadable = 0; [long]$seen = 0
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([object[]]@((New-Object IO.DirectoryInfo($Target.Path)), 0))

    try {
        while ($stack.Count -gt 0) {
            Test-CleanerCancel -Sync $Sync
            $item = $stack.Pop()
            $dir = $item[0]
            $depth = [int]$item[1]
            try {
                foreach ($entry in $dir.EnumerateFileSystemInfos()) {
                    $seen++
                    if (($seen % 500) -eq 0) {
                        Test-CleanerCancel -Sync $Sync
                        if ($null -ne $Sync) { $Sync['Detail'] = ('{0:N0} items checked' -f ([long]$Sync['Checked'] + $seen)) }
                    }
                    $attributes = [int]$entry.Attributes
                    if (($attributes -band 0x400) -ne 0) { $links++; continue }       # junction / symbolic link: never followed

                    if (($attributes -band 0x10) -ne 0) {                           # folder
                        if ($recurse) {
                            $stack.Push([object[]]@($entry, ($depth + 1)))
                            if ($collectFolders -and ($attributes -band $keep) -eq 0) {
                                $created = $entry.CreationTimeUtc.ToFileTimeUtc()
                                $written = $entry.LastWriteTimeUtc.ToFileTimeUtc()
                                if ($created -lt $cutoff -and $written -lt $cutoff) {
                                    $folders.Add((New-Object CleanerNative.FolderCandidate($entry.FullName, ($depth + 1), $RootIndex)))
                                }
                            }
                        }
                        continue
                    }

                    $name = $entry.Name
                    if ($null -ne $patterns) {
                        $match = $false
                        foreach ($pattern in $patterns) { if ($pattern.IsMatch($name)) { $match = $true; break } }
                        if (-not $match) { continue }
                    }
                    if ($exclude.Contains($name)) { $protected++; continue }
                    $extension = $entry.Extension
                    if ($never.Contains($extension) -and -not $allow.Contains($extension)) { $protected++; continue }
                    if (($attributes -band $keep) -ne 0) { $protected++; continue }

                    $written = $entry.LastWriteTimeUtc.ToFileTimeUtc()
                    $created = $entry.CreationTimeUtc.ToFileTimeUtc()
                    if ($written -ge $cutoff -or $created -ge $cutoff) { $recent++; continue }

                    $length = $entry.Length
                    $files.Add((New-Object CleanerNative.Candidate($entry.FullName, $length, $written, [Math]::Max($written, $created), $RootIndex)))
                    $bytes += $length
                    if ($files.Count -ge $max) { $Result.LimitReached = $true; return }
                }
            }
            catch [System.OperationCanceledException] { throw }
            catch [System.UnauthorizedAccessException] { $unreadable++ }
            catch [System.IO.IOException] { $unreadable++ }               # also: path too long, folder vanished
            catch [System.Security.SecurityException] { $unreadable++ }
            catch {
                Test-CleanerCancel -Sync $Sync
                $unreadable++
            }
        }
    }
    finally {
        $Result.Bytes += $bytes
        $Result.SkippedRecent += $recent
        $Result.SkippedProtected += $protected
        $Result.SkippedLinks += $links
        $Result.SkippedUnreadable += $unreadable
        if ($null -ne $Sync) { $Sync['Checked'] = [long]$Sync['Checked'] + $seen }
    }
}

function Invoke-CleanerRuleScan {
    param([Parameter(Mandatory = $true)]$Rule, [hashtable]$Sync)

    $result = New-CleanerScanResult -Rule $Rule
    $result.Cutoff = [DateTime]::UtcNow.AddDays(-$Rule.MinAgeDays).ToFileTimeUtc()

    if ($Rule.RequiresAdmin -and -not (Test-CleanerAdmin)) {
        $result.State = 'Unavailable'
        $result.Message = 'Needs administrator rights.'
        return $result
    }

    $running = @(Get-CleanerRunningApp -Rule $Rule)
    if ($running.Count -gt 0) {
        $app = if ($Rule.AppName) { $Rule.AppName } else { $running[0] }
        $result.State = 'Blocked'
        $result.RunningApps = $running
        $result.Message = "$app is running. Close it completely (also from the notification area) and analyze again."
        return $result
    }

    if ($Rule.Kind -eq 'ExplorerRecent') {
        try { $entries = @(Get-CleanerExplorerRecentEntry) }
        catch {
            $result.State = 'Error'
            $result.Message = 'File Explorer''s recent folders could not be read: ' + $_.Exception.Message
            return $result
        }
        foreach ($entry in $entries) { $result.Notes.Add([string]$entry) }
        $result.Count = $entries.Count
        $result.State = if ($result.Count -gt 0) { 'Ready' } else { 'Empty' }
        return $result
    }

    if ($Rule.Kind -eq 'RecycleBin') {
        $info = [CleanerNative.SafeIO]::QueryRecycleBin()
        if ($null -eq $info) {
            $result.State = 'Error'
            $result.Message = 'The size of the Recycle Bin could not be read.'
            return $result
        }
        $result.Bytes = $info[0]
        $result.Count = $info[1]
        $result.State = if ($result.Count -gt 0) { 'Ready' } else { 'Empty' }
        return $result
    }

    $seenRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in $Rule.Targets) {
        Test-CleanerCancel -Sync $Sync
        $path = $target.Path
        if (-not [IO.Directory]::Exists($path)) { continue }
        if (-not (Test-CleanerLinkFree -Path $path)) {
            $result.Notes.Add("Skipped because it is a linked folder: $path")
            continue
        }
        $final = [CleanerNative.SafeIO]::GetFinalPath($path)
        $problem = Test-CleanerRootPath -Path $final
        if ($problem) {
            $result.Notes.Add("Skipped ${path}: $problem")
            continue
        }
        $covered = $false
        foreach ($seenRoot in $seenRoots) {
            if ($final.Equals($seenRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $final.StartsWith($seenRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if ($covered) { continue }
        $seenRoots.Add($final)

        $index = $result.Roots.Count
        $result.Roots.Add([pscustomobject]@{ Path = $path; FinalPath = $final; RemoveEmptyFolders = [bool]$target.RemoveEmptyFolders })
        Invoke-CleanerTargetScan -Result $result -Target $target -RootIndex $index -Sync $Sync
        if ($result.LimitReached) { break }
    }

    $result.Count = $result.Files.Count
    if ($result.Roots.Count -eq 0) {
        $result.State = 'Unavailable'
        $result.Message = if ($result.Notes.Count -gt 0) { $result.Notes[0] } else { 'The folder no longer exists.' }
    }
    elseif ($result.Count -gt 0) { $result.State = 'Ready' }
    else { $result.State = 'Empty' }
    return $result
}

function Invoke-CleanerScan {
    <#
    .SYNOPSIS
        Analyzes rules and returns one result per rule. Read-only: nothing is deleted.
    .PARAMETER Sync
        Optional synchronized hashtable for progress (Status, Detail, Percent, Current),
        cancellation (Cancel = $true) and live results (Queue = ConcurrentQueue).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Rule, [hashtable]$Sync)

    $results = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $Sync) { $Sync['Checked'] = [long]0 }
    $total = $Rule.Count
    $cancelled = $false

    for ($i = 0; $i -lt $total; $i++) {
        $current = $Rule[$i]
        if ($cancelled) {
            $result = New-CleanerScanResult -Rule $current
            $result.State = 'Cancelled'
            $result.Message = 'The analysis was cancelled.'
        }
        else {
            Set-CleanerProgress -Sync $Sync -Status ('Analyzing {0}' -f $current.Name) -Percent ([int][Math]::Floor(100 * $i / [Math]::Max($total, 1))) -Current $current.Id
            try {
                $result = Invoke-CleanerRuleScan -Rule $current -Sync $Sync
            }
            catch {
                $result = New-CleanerScanResult -Rule $current
                if ($_.Exception -is [System.OperationCanceledException] -or ($null -ne $Sync -and $Sync['Cancel'])) {
                    $cancelled = $true
                    $result.State = 'Cancelled'
                    $result.Message = 'The analysis was cancelled.'
                }
                else {
                    $result.State = 'Error'
                    $result.Message = $_.Exception.Message
                }
            }
        }
        $results.Add($result)
        if ($null -ne $Sync -and $null -ne $Sync['Queue']) { $Sync['Queue'].Enqueue($result) }
    }
    Set-CleanerProgress -Sync $Sync -Percent 100 -Current ''
    return $results.ToArray()
}

# ----------------------------------------------------------------------------------------------
#  Cleaning
# ----------------------------------------------------------------------------------------------

function New-CleanerCleanResult {
    param($Scan)
    [pscustomobject]@{
        RuleId         = $Scan.RuleId
        Rule           = $Scan.Rule
        State          = 'Pending'      # Done | Blocked | Skipped | Error | Cancelled
        Message        = ''
        Deleted        = [long]0
        Bytes          = [long]0
        InUse          = [long]0
        Changed        = [long]0
        Denied         = [long]0
        Protected      = [long]0
        Missing        = [long]0
        Failed         = [long]0
        FoldersRemoved = [long]0
    }
}

function Get-CleanerExplorerRecentItem {
    <#
        The folders File Explorer lists as recent (the unpinned folders in Quick Access, also shown in the
        taskbar's File Explorer list). Pinned folders are never returned; an item whose pin state cannot be
        read is treated as pinned. Nothing is changed here.
    #>
    param([scriptblock]$Filter)
    $shell = New-Object -ComObject Shell.Application
    $quickAccess = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
    if ($null -eq $quickAccess) { return }
    foreach ($item in $quickAccess.Items()) {
        try {
            if (-not $item.IsFolder) { continue }
            $pinned = $item.ExtendedProperty('System.Home.IsPinned')
            if ($null -eq $pinned -or $pinned -ne $false) { continue }
            if ($null -ne $Filter -and -not (& $Filter $item.Path)) { continue }
            [pscustomobject]@{ Name = $item.Name; Path = $item.Path; Item = $item }
        }
        catch { }
    }
}

$script:ExplorerAppId = 'Microsoft.Windows.Explorer'

function Get-CleanerQuickAccessPinned {
    <# The folders pinned in Quick Access (also the "Pinned" part of File Explorer's taskbar list). Throws if they cannot be read. #>
    $shell = New-Object -ComObject Shell.Application
    $quickAccess = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
    if ($null -eq $quickAccess) { throw 'Quick Access could not be read.' }
    $pinned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $quickAccess.Items()) {
        $state = $item.ExtendedProperty('System.Home.IsPinned')
        if ($null -eq $state -or $state -ne $false) { [void]$pinned.Add([string]$item.Path) }   # unknown counts as pinned
    }
    return , $pinned
}

function Get-CleanerExplorerRecentEntry {
    <#
        Everything File Explorer lists as recent: the unpinned Quick Access folders and the Recent/Frequent
        entries of its taskbar list. Pinned folders are never returned. Nothing is changed here.
    #>
    param([scriptblock]$Filter)
    $pinned = Get-CleanerQuickAccessPinned
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $all = @(@(Get-CleanerExplorerRecentItem | ForEach-Object { [string]$_.Path }) + @([CleanerNative.JumpList]::GetEntries($script:ExplorerAppId)))
    foreach ($path in $all) {
        if ([string]::IsNullOrEmpty($path) -or $pinned.Contains($path)) { continue }
        if ($null -ne $Filter -and -not (& $Filter $path)) { continue }
        if ($seen.Add($path)) { $paths.Add($path) }
    }
    $paths.ToArray()
}

function Backup-CleanerExplorerList {
    <# Keeps a copy of File Explorer's list file (with the pins) before it is changed. Returns $false if that is not possible. #>
    param($Log)
    $source = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms'
    if (-not [IO.File]::Exists($source)) { return $true }
    try {
        $folder = Join-Path (Get-CleanerDataFolder) 'Backup'
        [void][IO.Directory]::CreateDirectory($folder)
        $target = Join-Path $folder 'QuickAccess.automaticDestinations-ms'
        $in = New-Object IO.FileStream($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $out = New-Object IO.FileStream($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
        Write-CleanerLog $Log 'BACKUP' ('Saved a copy of File Explorer''s list (with the pins) to {0}' -f $target)
        return $true
    }
    catch {
        Write-CleanerLog $Log 'ERROR' ('Could not save a copy of File Explorer''s list: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Invoke-CleanerExplorerRecent {
    <#
        Clears File Explorer's recent folders:
          1. Quick Access: Windows' own "Remove from Quick access" command on each unpinned folder (re-checked right before).
          2. Taskbar list: the official Jump List interface removes each Recent/Frequent entry that is not pinned.
        Only list entries go - the folders themselves are never touched. A copy of the list file is kept first.
    #>
    param($Result, $Log, [scriptblock]$Filter)
    $before = @(Get-CleanerExplorerRecentEntry -Filter $Filter)
    $pinnedBefore = Get-CleanerQuickAccessPinned

    if (-not (Backup-CleanerExplorerList -Log $Log)) {
        $Result.State = 'Error'
        $Result.Message = 'A safety copy of File Explorer''s list could not be saved, so nothing was changed.'
        return
    }

    # 1. Quick Access (it shows a limited number at a time, so repeat until none are left).
    $tried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($round = 0; $round -lt 30; $round++) {
        $fresh = @(Get-CleanerExplorerRecentItem -Filter $Filter | Where-Object { -not $tried.Contains([string]$_.Path) })
        if ($fresh.Count -eq 0) { break }
        foreach ($entry in $fresh) {
            [void]$tried.Add([string]$entry.Path)
            try { $entry.Item.InvokeVerb('removefromhome') }
            catch { Write-CleanerLog $Log 'ERROR' ('Could not remove {0} from Quick Access: {1}' -f $entry.Path, $_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 200
    }

    # 2. Taskbar list: pins are read again right before, and only unpinned entries are passed on.
    $pinnedNow = Get-CleanerQuickAccessPinned
    $targets = @([CleanerNative.JumpList]::GetEntries($script:ExplorerAppId) | Where-Object {
            -not $pinnedNow.Contains($_) -and -not $pinnedBefore.Contains($_) -and ($null -eq $Filter -or (& $Filter $_)) })
    if ($targets.Count -gt 0) { [void][CleanerNative.JumpList]::Remove($script:ExplorerAppId, [string[]]$targets) }
    Start-Sleep -Milliseconds 200

    $after = @(Get-CleanerExplorerRecentEntry -Filter $Filter)
    $left = @($after | Where-Object { $before -contains $_ })
    $Result.Deleted = [long][Math]::Max(0, $before.Count - $left.Count)
    $Result.Failed = [long]$left.Count
    $pinnedAfter = Get-CleanerQuickAccessPinned
    $lostPins = @($pinnedBefore | Where-Object { -not $pinnedAfter.Contains($_) })
    if ($lostPins.Count -gt 0) {
        Write-CleanerLog $Log 'WARNING' ('Pinned folder(s) no longer pinned after cleaning: {0}. A copy of the list is in the Backup folder.' -f ($lostPins -join ', '))
    }
    if ($Result.Deleted -eq 0 -and $left.Count -gt 0) {
        $Result.State = 'Error'
        $Result.Message = 'File Explorer did not remove its recent folders. Restart File Explorer and try again.'
    }
    Write-CleanerLog $Log 'RECENT' ('Cleared {0:N0} recent folder(s) from File Explorer and its taskbar list (pinned folders kept), {1:N0} left' -f $Result.Deleted, $left.Count)
}

function Invoke-CleanerRecycleBin {
    param($Result, $Log)
    $before = [CleanerNative.SafeIO]::QueryRecycleBin()
    $hr = [CleanerNative.SafeIO]::EmptyRecycleBin()
    $after = [CleanerNative.SafeIO]::QueryRecycleBin()
    if ($null -ne $before -and $null -ne $after) {
        $Result.Deleted = [Math]::Max([long]0, [long]($before[1] - $after[1]))
        $Result.Bytes = [Math]::Max([long]0, [long]($before[0] - $after[0]))
        if ($after[1] -gt 0) { $Result.Failed = $after[1] }
    }
    if ($hr -ne 0 -and $Result.Deleted -eq 0 -and $null -ne $after -and $after[1] -gt 0) {
        $Result.State = 'Error'
        $Result.Message = ('The Recycle Bin could not be emptied (code 0x{0:X8}).' -f $hr)
    }
    Write-CleanerLog $Log 'RECYCLE' ('Emptied the Recycle Bin: {0:N0} item(s), {1:N0} bytes' -f $Result.Deleted, $Result.Bytes)
}

function Invoke-CleanerRuleClean {
    param($Scan, $Result, [hashtable]$Sync, $Log, [ref]$Step, [long]$TotalSteps)

    # Every location must still be the very same real folder that was analyzed.
    $roots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $Scan.Roots) {
        $final = $null
        if ([IO.Directory]::Exists($root.Path) -and (Test-CleanerLinkFree -Path $root.Path)) {
            $now = [CleanerNative.SafeIO]::GetFinalPath($root.Path)
            if ($now -and $now.Equals($root.FinalPath, [StringComparison]::OrdinalIgnoreCase) -and -not (Test-CleanerRootPath -Path $now)) {
                $final = $now
            }
        }
        if ($null -eq $final) { Write-CleanerLog $Log 'SKIP' ('Location changed since the analysis - not cleaned: {0}' -f $root.Path) }
        $roots.Add($final)
    }

    $cutoff = [long]$Scan.Cutoff
    $count = $Scan.Files.Count
    [long]$index = 0
    foreach ($file in $Scan.Files) {
        $index++
        $Step.Value = $Step.Value + 1
        if (($index % 50) -eq 0 -or $index -eq 1) {
            Test-CleanerCancel -Sync $Sync
            Set-CleanerProgress -Sync $Sync -Percent ([int][Math]::Floor(100 * $Step.Value / [Math]::Max($TotalSteps, 1))) -Detail ('{0:N0} of {1:N0} files' -f $index, $count)
        }
        $rootFinal = $roots[$file.Root]
        if ($null -eq $rootFinal) { $Result.Changed++; continue }

        $status = [CleanerNative.SafeIO]::DeleteFileChecked($file.Path, $rootFinal, $file.Size, $file.WriteTime, $cutoff)
        switch ([int]$status) {
            0 { $Result.Deleted++; $Result.Bytes += $file.Size; Write-CleanerLog $Log 'DELETED' ('{0}  ({1:N0} bytes)' -f $file.Path, $file.Size) }
            1 { $Result.Missing++ }
            2 { $Result.InUse++; Write-CleanerLog $Log 'IN USE' $file.Path }
            3 { $Result.Denied++; Write-CleanerLog $Log 'DENIED' $file.Path }
            4 { $Result.Changed++; Write-CleanerLog $Log 'CHANGED' $file.Path }
            5 { $Result.Protected++; Write-CleanerLog $Log 'OUTSIDE' $file.Path }
            6 { $Result.Protected++; Write-CleanerLog $Log 'KEPT' $file.Path }
            default { $Result.Failed++; Write-CleanerLog $Log 'FAILED' $file.Path }
        }
    }

    if ($Scan.Folders.Count -gt 0) {
        Set-CleanerProgress -Sync $Sync -Detail 'Removing empty folders'
        $folderIndex = 0
        foreach ($folder in [CleanerNative.SafeIO]::DeepestFirst($Scan.Folders)) {
            $folderIndex++
            if (($folderIndex % 100) -eq 0) { Test-CleanerCancel -Sync $Sync }
            $rootFinal = $roots[$folder.Root]
            if ($null -eq $rootFinal) { continue }
            if ([CleanerNative.SafeIO]::DeleteEmptyFolderChecked($folder.Path, $rootFinal) -eq [CleanerNative.DeleteStatus]::Deleted) {
                $Result.FoldersRemoved++
                Write-CleanerLog $Log 'FOLDER' $folder.Path
            }
        }
    }
}

function Invoke-CleanerClean {
    <#
    .SYNOPSIS
        Deletes the files found by Invoke-CleanerScan, re-checking every single file first.
    .PARAMETER ScanResult
        Results from Invoke-CleanerScan. Only results in the Ready state are cleaned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$ScanResult, [hashtable]$Sync)

    $ready = @($ScanResult | Where-Object { $_.State -eq 'Ready' })
    [long]$totalSteps = 0
    foreach ($scan in $ready) { $totalSteps += [Math]::Max([long]1, [long]$scan.Files.Count) }
    $step = [long]0
    $results = New-Object 'System.Collections.Generic.List[object]'
    $cancelled = $false
    $log = Open-CleanerLog

    try {
        Write-CleanerLog $log 'START' ('Cleaning {0} item(s) as {1}\{2} (administrator: {3})' -f $ready.Count, [Environment]::UserDomainName, [Environment]::UserName, (Test-CleanerAdmin))
        foreach ($scan in $ScanResult) {
            $result = New-CleanerCleanResult -Scan $scan
            $rule = $scan.Rule
            if ($cancelled) {
                $result.State = 'Cancelled'
                $result.Message = 'Cleaning was stopped.'
            }
            elseif ($scan.State -ne 'Ready') {
                $result.State = 'Skipped'
                $result.Message = 'Nothing to clean.'
            }
            else {
                Set-CleanerProgress -Sync $Sync -Status ('Cleaning {0}' -f $rule.Name) -Current $rule.Id
                try {
                    if ($rule.RequiresAdmin -and -not (Test-CleanerAdmin)) { throw 'Needs administrator rights.' }
                    $running = @(Get-CleanerRunningApp -Rule $rule)
                    if ($running.Count -gt 0) {
                        $app = if ($rule.AppName) { $rule.AppName } else { $running[0] }
                        $result.State = 'Blocked'
                        $result.Message = "$app was opened again, so its cache was not cleaned."
                    }
                    elseif ($rule.Kind -eq 'RecycleBin') {
                        Invoke-CleanerRecycleBin -Result $result -Log $log
                        $step++
                    }
                    elseif ($rule.Kind -eq 'ExplorerRecent') {
                        Invoke-CleanerExplorerRecent -Result $result -Log $log
                        $step++
                    }
                    else {
                        Invoke-CleanerRuleClean -Scan $scan -Result $result -Sync $Sync -Log $log -Step ([ref]$step) -TotalSteps $totalSteps
                    }
                }
                catch {
                    if ($_.Exception -is [System.OperationCanceledException] -or ($null -ne $Sync -and $Sync['Cancel'])) {
                        $cancelled = $true
                        $result.State = 'Cancelled'
                        $result.Message = 'Cleaning was stopped.'
                    }
                    else {
                        $result.State = 'Error'
                        $result.Message = $_.Exception.Message
                        Write-CleanerLog $log 'ERROR' ('{0}: {1}' -f $rule.Name, $_.Exception.Message)
                    }
                }
                if ($result.State -eq 'Pending') { $result.State = 'Done' }
                Write-CleanerLog $log 'SUMMARY' ('{0}: deleted {1:N0} file(s), {2}, in use {3:N0}, changed {4:N0}, denied {5:N0}, kept {6:N0}, failed {7:N0}, empty folders removed {8:N0}' -f
                    $rule.Name, $result.Deleted, (Format-CleanerSize $result.Bytes), $result.InUse, $result.Changed, $result.Denied, $result.Protected, $result.Failed, $result.FoldersRemoved)
            }
            $results.Add($result)
            if ($null -ne $Sync -and $null -ne $Sync['Queue']) { $Sync['Queue'].Enqueue($result) }
        }
        [long]$freed = 0
        foreach ($r in $results) { $freed += $r.Bytes }
        Write-CleanerLog $log 'END' ('Freed {0}{1}' -f (Format-CleanerSize $freed), $(if ($cancelled) { ' (stopped by the user)' } else { '' }))
    }
    finally {
        if ($null -ne $log) { $log.Dispose() }
    }
    Set-CleanerProgress -Sync $Sync -Percent 100 -Current ''
    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'Get-CleanerVersion', 'Get-CleanerGroup', 'Get-CleanerRule', 'Invoke-CleanerScan', 'Invoke-CleanerClean',
    'Test-CleanerAdmin', 'Format-CleanerSize', 'Get-CleanerDataFolder', 'Get-CleanerLogFolder',
    'Read-CleanerSettings', 'Save-CleanerSettings', 'Add-CleanerLogEntry', 'Remove-CleanerOldLog',
    'Get-CleanerRunningApp', 'Close-CleanerApp', 'Get-CleanerProtectedPath', 'Test-CleanerRootPath'
)
