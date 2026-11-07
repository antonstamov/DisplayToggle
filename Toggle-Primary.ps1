# Переключение основного дисплея через современный API DisplayConfig.
#
# ПОЧЕМУ НЕ LEGACY API: смена primary через ChangeDisplaySettingsEx
# переприменяет сохранённый в реестре режим дисплея (legacy-хранилище),
# а выбранный вручную в «Параметры» режим (например 60 Гц вместо 59,95)
# в это хранилище не попадает — поэтому после переключения частота
# откатывалась и начиналось моргание. Современный API (SetDisplayConfig)
# принимает source-режимы как есть, поэтому тайминг не затрагивается физически.
#
# Логика выбора цели сохранена (1 экран — ничего, 2 — другой, 3+ — по кругу),
# но список экранов берётся из активных путей DisplayConfig, а не из
# Screen.AllScreens (там часть мониторов отдаётся отключёнными).
#
# При ошибке SetDisplayConfig переключение не выполняется, причина пишется в toggle.log.

$ErrorActionPreference = "Stop"
$log = Join-Path $PSScriptRoot "toggle.log"
function Log($msg) {
  try { Add-Content -Path $log -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $msg) -ErrorAction SilentlyContinue } catch {}
}

# --------------------------------------------------------------------------
# C#-часть: структуры DisplayConfig. Размеры проверены на этой машине:
#   DISPLAYCONFIG_PATH_INFO = 72 байта
#   DISPLAYCONFIG_MODE_INFO = 64 байта (union 48)
#   source-режим в union: width@0 height@4 pixelFormat@8 position@12
# --------------------------------------------------------------------------
if (-not ("DisplayToggle" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class DisplayToggle
{
    const uint QDC_ONLY_ACTIVE_PATHS  = 0x00000002;
    const uint QDC_VIRTUAL_MODE_AWARE = 0x00000010;

    // флаги SetDisplayConfig (набор SDC_*, не QDC_*)
    const uint SDC_APPLY                     = 0x00000080;
    const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    const uint SDC_VALIDATE                  = 0x00000040;
    const uint SDC_ALLOW_CHANGES             = 0x00000400;
    const uint SDC_SAVE_TO_DATABASE          = 0x00000200;
    const uint SDC_VIRTUAL_MODE_AWARE        = 0x00008000;
    const uint SDC_VIRTUAL_REFRESH_RATE_AWARE = 0x00020000;

    const int PATH_SIZE = 72;
    const int MODE_SIZE = 64;
    const int MODE_UNION = 16;      // смещение union внутри DISPLAYCONFIG_MODE_INFO
    const int SRC_POS   = 12;       // смещение позиции внутри source-режима
    const int SRC_SIZE  = 36;       // sizeof(DISPLAYCONFIG_SOURCE_MODE)
    const int TGT_SIZE  = 48;       // sizeof(DISPLAYCONFIG_VIDEO_SIGNAL_INFO)

    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DIH { public uint type; public uint size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SOURCE_NAME {
        public DIH header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string viewGdiDeviceName;
    }

    // --- включение выключенного дисплея штатными средствами user32 ---
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE_EN {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevicesW(string dev, int idx, ref DISPLAY_DEVICE d, int flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int EnumDisplaySettingsW(string dev, int mode, ref DEVMODE_EN dm);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE_EN dm, IntPtr hwnd, int flags, IntPtr lparam);
    [DllImport("user32.dll")] static extern int ChangeDisplaySettingsExW(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lparam);

    const int DD_ATTACHED = 0x1;
    const int DD_MIRROR   = 0x8;
    const int ENUM_REGISTRY = -2;
    const int CDS_UPDATEREGISTRY = 0x01;
    const int CDS_NORESET = 0x10000000;
    const int DM_POSITION = 0x20;
    const int DM_PELSWIDTH = 0x80000;
    const int DM_PELSHEIGHT = 0x100000;
    const int DM_DISPLAYFREQUENCY = 0x400000;

    // Перечисляет режимы дисплея: макс. площадь, при равной — частота ближе к preferFreq
    // (дом-стандарт; сюрпризов вида 100+ Гц на первом включении не будет).
    public static bool GetBestMode(string dev, StringBuilder log, int preferFreq, out DEVMODE_EN best)
    {
        best = new DEVMODE_EN();
        bool found = false;
        long bestArea = -1;
        int bestFreq = 0;
        for (int m = 0; m < 256; m++)
        {
            DEVMODE_EN dm = new DEVMODE_EN();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            int r;
            try { r = EnumDisplaySettingsW(dev, m, ref dm); }
            catch { break; }
            if (r == 0) break;
            if (dm.dmPelsWidth <= 0 || dm.dmPelsHeight <= 0) continue;
            long area = (long)dm.dmPelsWidth * dm.dmPelsHeight;
            if (!found || area > bestArea ||
                (area == bestArea && Math.Abs(dm.dmDisplayFrequency - preferFreq) < Math.Abs(bestFreq - preferFreq)))
            { bestArea = area; bestFreq = dm.dmDisplayFrequency; best = dm; found = true; }
        }
        if (found) log.AppendLine("best mode for " + dev + ": " + best.dmPelsWidth + "x" + best.dmPelsHeight + "@" + best.dmDisplayFrequency);
        return found;
    }

    // Частота из target-тайминга (vSync rational, байты 16..23 VIDEO_SIGNAL_INFO).
    public static int DecodeFreq(string hex)
    {
        try
        {
            string[] parts = hex.Split(new char[] { '-' });
            if (parts.Length < 24) return 0;
            byte[] b = new byte[parts.Length];
            for (int i = 0; i < parts.Length; i++) b[i] = Convert.ToByte(parts[i], 16);
            uint num = BitConverter.ToUInt32(b, 16);
            uint den = BitConverter.ToUInt32(b, 20);
            if (den == 0) return 0;
            return (int)Math.Round((double)num / den);
        }
        catch { return 0; }
    }

    // Журнал последних виденных режимов: "gdi;target;W;H;freq". Пишется каждым
    // успешным тогглом из живого опроса — это и есть точный "как было".
    public static void RecordJournal(string file, Snapshot s, StringBuilder log)
    {
        try
        {
            List<string> lines = new List<string>();
            foreach (ScreenInfo sc in s.Screens)
            {
                int f = DecodeFreq(sc.TgtModeHex);
                lines.Add(sc.GdiName + ";" + sc.TargetId + ";" + sc.W + ";" + sc.H + ";" + f);
            }
            System.IO.File.WriteAllLines(file, lines.ToArray());
        }
        catch (Exception ex) { log.AppendLine("journal write failed: " + ex.Message); }
    }

    public static bool TryJournalMode(string file, string gdi, StringBuilder log, out int w, out int h, out int f)
    {
        w = 0; h = 0; f = 0;
        try
        {
            if (string.IsNullOrEmpty(file) || !System.IO.File.Exists(file)) return false;
            foreach (string line in System.IO.File.ReadAllLines(file))
            {
                string[] p = line.Split(new char[] { ';' });
                if (p.Length < 5) continue;
                if (!p[0].Equals(gdi, StringComparison.OrdinalIgnoreCase)) continue;
                if (!int.TryParse(p[2], out w) || !int.TryParse(p[3], out h)) { w = 0; h = 0; continue; }
                int.TryParse(p[4], out f);
                if (w <= 0 || h <= 0) continue;
                log.AppendLine("journal mode for " + gdi + ": " + w + "x" + h + "@" + f);
                return true;
            }
        }
        catch (Exception ex) { log.AppendLine("journal read failed: " + ex.Message); }
        return false;
    }

    // Один attach: режим w/h[/freq] в (posX,posY). Сначала с частотой, при отказе — без.
    public static bool TryAttach(string dev, int w, int h, int freq, int posX, int posY, StringBuilder log, string tag)
    {
        DEVMODE_EN dm = new DEVMODE_EN();
        dm.dmSize = (short)Marshal.SizeOf(dm);
        dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmDisplayFrequency = freq;
        dm.dmPositionX = posX; dm.dmPositionY = posY;
        if (freq > 0)
        {
            dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
            int ar = ChangeDisplaySettingsExW(dev, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
            log.AppendLine(tag + " attach " + dev + " " + w + "x" + h + "@" + freq + " at " + posX + "," + posY + " res=" + ar);
            if (ar == 0)
            {
                int cr = ChangeDisplaySettingsExW(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
                log.AppendLine(tag + " commit res=" + cr);
                return cr == 0;
            }
        }
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        int ar2 = ChangeDisplaySettingsExW(dev, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
        log.AppendLine(tag + " attach w/o freq res=" + ar2);
        if (ar2 != 0) return false;
        int cr2 = ChangeDisplaySettingsExW(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        log.AppendLine(tag + " commit res=" + cr2);
        return cr2 == 0;
    }

    // Включает первый выключенный (detached) дисплей расширением в (posX,posY).
    // Режим: наш журнал (точный "как было") -> legacy-реестр -> лучший из перебора.
    // activeCsv — имена уже активных GDI (их пропускаем).
    // Возвращает true + имя в enabledName, если attach удался.
    public static bool EnableFirstDetached(int posX, int posY, StringBuilder log, string activeCsv, string journalFile, int preferFreq, out string enabledName)
    {
        enabledName = "";
        string[] active = (activeCsv ?? "").Split(new char[] { ',' });
        for (int i = 0; i < 64; i++)
        {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(dd);
            bool has;
            try { has = EnumDisplayDevicesW(null, i, ref dd, 0); }
            catch (Exception ex) { log.AppendLine("enum adapters failed: " + ex.Message); return false; }
            if (!has) break;
            if (string.IsNullOrEmpty(dd.DeviceName)) continue;
            if ((dd.StateFlags & DD_MIRROR) != 0) continue;
            if ((dd.StateFlags & DD_ATTACHED) != 0) continue;
            bool isActive = false;
            foreach (string a in active) { if (!string.IsNullOrEmpty(a) && a == dd.DeviceName) { isActive = true; break; } }
            if (isActive) continue;
            log.AppendLine("detached candidate: " + dd.DeviceName + " (" + dd.DeviceString + ")");
            int jw, jh, jf;
            if (TryJournalMode(journalFile, dd.DeviceName, log, out jw, out jh, out jf))
            {
                if (TryAttach(dd.DeviceName, jw, jh, jf, posX, posY, log, "journal")) { enabledName = dd.DeviceName; return true; }
                log.AppendLine("journal mode failed, trying registry");
            }
            DEVMODE_EN dm = new DEVMODE_EN();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            int er = EnumDisplaySettingsW(dd.DeviceName, ENUM_REGISTRY, ref dm);
            if (er != 0 && dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0)
            {
                if (TryAttach(dd.DeviceName, dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency, posX, posY, log, "registry")) { enabledName = dd.DeviceName; return true; }
                log.AppendLine("registry mode failed, probing best");
            }
            else log.AppendLine("no registry mode for " + dd.DeviceName + ", probing best");
            DEVMODE_EN b;
            if (!GetBestMode(dd.DeviceName, log, preferFreq, out b)) { log.AppendLine("no modes for " + dd.DeviceName + ", skipping"); continue; }
            if (TryAttach(dd.DeviceName, b.dmPelsWidth, b.dmPelsHeight, b.dmDisplayFrequency, posX, posY, log, "best")) { enabledName = dd.DeviceName; return true; }
        }
        return false;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, ref uint pathCount, ref uint modeCount);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, IntPtr p, ref uint nm, IntPtr m, IntPtr topo);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, IntPtr p, uint nm, IntPtr m, uint flags);
    [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SOURCE_NAME r);

    public class ScreenInfo
    {
        public uint TargetId;
        public string GdiName = "";
        public int  X, Y;          // позиция источника в виртуальном рабочем столе
        public int  W, H;          // разрешение источника
        public int  ModeOffset = -1;
        public bool IsPrimary;
        public string TgtModeHex = "";
    }

    public class Snapshot
    {
        public List<ScreenInfo> Screens = new List<ScreenInfo>();
        public byte[] ModeBytes = new byte[0];
        public byte[] PathBytes = new byte[0];
        public uint PathCount, ModeCount;
        public IntPtr PathBuf, ModeBuf;
        public int QueryRc;
    }

    // читает активные пути + source-режимы.
    public static Snapshot Query(uint qflags)
    {
        Snapshot s = new Snapshot();
        uint pc = 0, mc = 0;
        int rc = GetDisplayConfigBufferSizes(qflags, ref pc, ref mc);
        if (rc != 0) { s.QueryRc = rc; return s; }
        s.PathBuf = Marshal.AllocHGlobal((int)pc * PATH_SIZE + 1024);
        s.ModeBuf = Marshal.AllocHGlobal((int)mc * MODE_SIZE + 1024);
        uint np = pc, nm = mc;
        rc = QueryDisplayConfig(qflags, ref np, s.PathBuf, ref nm, s.ModeBuf, IntPtr.Zero);
        s.QueryRc = rc;
        if (rc != 0) { FreeSnapshot(s); return s; }
        s.PathCount = np; s.ModeCount = nm;
        s.PathBytes = new byte[np * PATH_SIZE];
        s.ModeBytes = new byte[nm * MODE_SIZE];
        Marshal.Copy(s.PathBuf, s.PathBytes, 0, s.PathBytes.Length);
        Marshal.Copy(s.ModeBuf, s.ModeBytes, 0, s.ModeBytes.Length);

        // mode-элементы идут тройками: TARGET(id) -> SOURCE -> DESKTOP_IMAGE(id того же target'а)
        var srcOffsetByTarget = new Dictionary<uint, int>();
        var tgtOffsetByTarget = new Dictionary<uint, int>();
        uint curTarget = 0; int curSource = -1; int curTargetOff = -1;
        for (uint m = 0; m < nm; m++)
        {
            int o = (int)m * MODE_SIZE;
            uint type = BitConverter.ToUInt32(s.ModeBytes, o);
            uint id = BitConverter.ToUInt32(s.ModeBytes, o + 4);
            if (type == 2) { curTarget = id; curSource = -1; curTargetOff = o; }
            else if (type == 1) { curSource = o; }
            else if (type == 3)
            {
                if (curSource >= 0 && !srcOffsetByTarget.ContainsKey(id)) srcOffsetByTarget[id] = curSource;
                if (curTargetOff >= 0 && !tgtOffsetByTarget.ContainsKey(id)) tgtOffsetByTarget[id] = curTargetOff;
            }
        }

        for (uint i = 0; i < np; i++)
        {
            int po = (int)i * PATH_SIZE;
            ScreenInfo sc = new ScreenInfo();
            sc.TargetId = BitConverter.ToUInt32(s.PathBytes, po + 28);       // targetInfo.id
            uint srcAdapterLow = BitConverter.ToUInt32(s.PathBytes, po + 0);
            uint srcId = BitConverter.ToUInt32(s.PathBytes, po + 8);

            SOURCE_NAME sn = new SOURCE_NAME();
            sn.header.type = 1; sn.header.size = (uint)Marshal.SizeOf(typeof(SOURCE_NAME));
            sn.header.adapterId = new LUID { LowPart = srcAdapterLow, HighPart = 0 };
            sn.header.id = srcId;
            if (GetSourceName(ref sn) == 0) sc.GdiName = sn.viewGdiDeviceName;

            int mo, to;
            if (srcOffsetByTarget.TryGetValue(sc.TargetId, out mo))
            {
                sc.ModeOffset = mo;
                int u = mo + MODE_UNION;
                sc.W = (int)BitConverter.ToUInt32(s.ModeBytes, u + 0);
                sc.H = (int)BitConverter.ToUInt32(s.ModeBytes, u + 4);
                sc.X = BitConverter.ToInt32(s.ModeBytes, u + SRC_POS);
                sc.Y = BitConverter.ToInt32(s.ModeBytes, u + SRC_POS + 4);
            }
            if (tgtOffsetByTarget.TryGetValue(sc.TargetId, out to))
            {
                byte[] tgt = new byte[TGT_SIZE];
                Array.Copy(s.ModeBytes, to + MODE_UNION, tgt, 0, TGT_SIZE);
                sc.TgtModeHex = BitConverter.ToString(tgt);
            }
            s.Screens.Add(sc);
        }
        // primary: тот, чей источник в (0,0)
        bool any = false;
        foreach (ScreenInfo sc in s.Screens) { if (sc.X == 0 && sc.Y == 0) { sc.IsPrimary = true; any = true; } }
        if (!any && s.Screens.Count > 0) s.Screens[0].IsPrimary = true;
        return s;
    }

    public static string Describe(Snapshot s)
    {
        StringBuilder sb = new StringBuilder();
        foreach (ScreenInfo sc in s.Screens)
            sb.AppendLine("    " + sc.GdiName + " target=" + sc.TargetId + " " + sc.W + "x" + sc.H +
                          " pos=" + sc.X + "," + sc.Y + (sc.IsPrimary ? " PRIMARY" : ""));
        return sb.ToString();
    }

    public static void FreeSnapshot(Snapshot s)
    {
        try { if (s.PathBuf != IntPtr.Zero) Marshal.FreeHGlobal(s.PathBuf); } catch {}
        try { if (s.ModeBuf != IntPtr.Zero) Marshal.FreeHGlobal(s.ModeBuf); } catch {}
        s.PathBuf = IntPtr.Zero; s.ModeBuf = IntPtr.Zero;
    }

    // уникальные позиции (клоны одного экрана имеют одинаковую позицию)
    public static List<ScreenInfo> Dedupe(Snapshot s)
    {
        List<ScreenInfo> uniq = new List<ScreenInfo>();
        foreach (ScreenInfo sc in s.Screens)
        {
            bool dup = false;
            foreach (ScreenInfo u in uniq) if (u.X == sc.X && u.Y == sc.Y) { dup = true; break; }
            if (!dup) uniq.Add(sc);
        }
        return uniq;
    }

    // Переключает primary на следующий экран по кругу.
    // Возвращает текст отчёта; ok=false — переключение не выполнено.
    // journalFile — файл журнала последних режимов (точный "как было").
    public static string Switch(out bool ok, string journalFile, int preferFreq)
    {
        ok = false;
        StringBuilder sb = new StringBuilder();
        Snapshot s = Query(QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE);
        if (s.QueryRc != 0) { sb.AppendLine("query failed rc=" + s.QueryRc); return sb.ToString(); }
        sb.AppendLine("screens before:");
        sb.Append(Describe(s));

        // уникальные позиции (клоны одного экрана имеют одинаковую позицию)
        List<ScreenInfo> uniq = Dedupe(s);
        if (uniq.Count < 2) {
            sb.AppendLine("only one display position, trying to enable detached");
            // кейс "таргет выключен через ОС": включаем первый detached расширением
            // справа от текущего десктопа (дубликаты не трогаем) и ТУТ ЖЕ
            // переключаем primary на него тем же сдвигом.
            int right = 0;
            foreach (ScreenInfo sc in s.Screens) { int e = sc.X + sc.W; if (e > right) right = e; }
            StringBuilder an = new StringBuilder();
            foreach (ScreenInfo sc in s.Screens) { an.Append(sc.GdiName); an.Append(','); }
            string en;
            if (!EnableFirstDetached(right, 0, sb, an.ToString(), journalFile, preferFreq, out en)) {
                sb.AppendLine("no detached display to enable, nothing to toggle");
                FreeSnapshot(s);
                return sb.ToString();
            }
            System.Threading.Thread.Sleep(500);
            FreeSnapshot(s);
            s = Query(QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE);
            if (s.QueryRc != 0) { sb.AppendLine("re-query failed rc=" + s.QueryRc); FreeSnapshot(s); return sb.ToString(); }
            sb.AppendLine("screens after enable:");
            sb.Append(Describe(s));
            uniq = Dedupe(s);
            if (uniq.Count < 2) { sb.AppendLine("enabled " + en + " but still one position"); FreeSnapshot(s); return sb.ToString(); }
        }

        // primary = та позиция, что в (0,0)
        int pIdx = -1;
        for (int i = 0; i < uniq.Count; i++) if (uniq[i].X == 0 && uniq[i].Y == 0) { pIdx = i; break; }
        if (pIdx < 0) pIdx = 0;
        ScreenInfo target = uniq[(pIdx + 1) % uniq.Count];
        sb.AppendLine("current primary: " + uniq[pIdx].GdiName + " (" + uniq[pIdx].X + "," + uniq[pIdx].Y + ")");
        sb.AppendLine("new primary:     " + target.GdiName + " (" + target.X + "," + target.Y + ")");

        // сдвиг: новый primary в (0,0), остальные сдвигаются на ту же дельту
        int dx = -target.X, dy = -target.Y;
        byte[] modes = (byte[])s.ModeBytes.Clone();
        foreach (ScreenInfo sc in s.Screens)
        {
            if (sc.ModeOffset < 0) continue;
            int u = sc.ModeOffset + MODE_UNION + SRC_POS;
            int nx = BitConverter.ToInt32(modes, u) + dx;
            int ny = BitConverter.ToInt32(modes, u + 4) + dy;
            BitConverter.GetBytes(nx).CopyTo(modes, u);
            BitConverter.GetBytes(ny).CopyTo(modes, u + 4);
        }

        IntPtr mbuf = Marshal.AllocHGlobal(modes.Length);
        Marshal.Copy(modes, 0, mbuf, modes.Length);
        uint sdcBase = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES |
                       SDC_VIRTUAL_MODE_AWARE | SDC_VIRTUAL_REFRESH_RATE_AWARE;
        int rc = SetDisplayConfig(s.PathCount, s.PathBuf, s.ModeCount, mbuf, sdcBase | SDC_VALIDATE);
        sb.AppendLine("SetDisplayConfig(VALIDATE) rc=" + rc);
        if (rc == 0)
        {
            rc = SetDisplayConfig(s.PathCount, s.PathBuf, s.ModeCount, mbuf, sdcBase | SDC_APPLY | SDC_SAVE_TO_DATABASE);
            sb.AppendLine("SetDisplayConfig(APPLY+SAVE_TO_DATABASE) rc=" + rc);
        }
        Marshal.FreeHGlobal(mbuf);
        FreeSnapshot(s);
        if (rc != 0) { sb.AppendLine("switch failed"); return sb.ToString(); }

        System.Threading.Thread.Sleep(800);
        Snapshot after = Query(QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE);
        sb.AppendLine("screens after:");
        sb.Append(Describe(after));
        // проверяем, что тайминги (target-режимы) и разрешения источников не изменились
        bool timingKept = true;
        foreach (ScreenInfo sc in s.Screens)
        {
            ScreenInfo ac = null;
            foreach (ScreenInfo x in after.Screens) if (x.TargetId == sc.TargetId) { ac = x; break; }
            if (ac == null) { timingKept = false; sb.AppendLine("  target " + sc.TargetId + " disappeared"); continue; }
            if (sc.TgtModeHex != ac.TgtModeHex)
            {
                timingKept = false;
                sb.AppendLine("  target mode changed for " + sc.GdiName);
                sb.AppendLine("    before: " + sc.TgtModeHex);
                sb.AppendLine("    after : " + ac.TgtModeHex);
            }
            if (sc.W != ac.W || sc.H != ac.H)
            {
                timingKept = false;
                sb.AppendLine("  source resolution changed for " + sc.GdiName + ": " + sc.W + "x" + sc.H + " -> " + ac.W + "x" + ac.H);
            }
        }
        sb.AppendLine("timing kept: " + timingKept);
        RecordJournal(journalFile, after, sb);
        FreeSnapshot(after);
        ok = true;
        return sb.ToString();
    }
}
"@
}

# --------------------------------------------------------------------------
# блокировка от двойного запуска (отдельный файл, чтобы параллельные
# запуски с противоположными целями не дёргали primary туда-сюда)
# --------------------------------------------------------------------------
$lock = Join-Path $PSScriptRoot "toggle.lock"
$canRun = $true
if (Test-Path $lock) {
  try {
    $parts = ((Get-Content $lock -Raw).Trim() -split ";")
    $oldPid = [int]$parts[0]
    $oldTime = [datetime]$parts[1]
    $age = ((Get-Date) - $oldTime).TotalSeconds
    $alive = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($alive -and $age -lt 60) {
      Log ("skip: previous instance (pid " + $oldPid + ") still running, exiting")
      $canRun = $false
    }
  } catch { Log ("lock unreadable, taking over: " + $_) }
}
if (-not $canRun) { exit 0 }
try { ($PID.ToString() + ";" + (Get-Date).ToString("o")) | Set-Content $lock } catch {}
function ReleaseLock() { Remove-Item $lock -Force -ErrorAction SilentlyContinue }

# свежий лог на каждый запуск: старые прогоны не храним
try { Set-Content $log -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " --- run ---") } catch {}

$ok = $false
# Preferred refresh rate (Hz) when a detached display has no stored mode:
# among modes with max area, pick the one closest to this. 60 = safe default.
$PreferFreq = 60
try {
  $journal = Join-Path $PSScriptRoot "display-modes.txt"
  $report = [DisplayToggle]::Switch([ref]$ok, $journal, $PreferFreq)
  foreach ($line in ($report -split "`r?`n")) { if ($line.Trim()) { Log ("toggle: " + $line) } }
  if ($ok) { Log "toggle switch done"; ReleaseLock; exit 0 }
  Log "toggle switch did not succeed"
} catch {
  Log ("toggle switch exception: " + $_)
}

ReleaseLock
