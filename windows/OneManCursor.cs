// ワンマンカーソル (試作) - Windows 側の参加者
// Mac 側のワンマンカーソル / FinderSwipe と合図をやり取りする。
// 役割は2つ:
//  1) スワイプの合図 → エクスプローラー / Chromium 系ブラウザのショートカットに変換
//       エクスプローラー: 戻る = Alt+← / 進む = Alt+→ / 上の階層 = Alt+↑ / 開く = Enter
//       Chromium 系: 戻る = Alt+← / 進む = Alt+→ (履歴移動のみ)
//  2) カーソル共有の参加者 → 合図でカーソルを受け取り、自分の画面で再現する。
//     隣がいる端を越えたら次の相手へ中継し、来た相手の側の端を越えたら返す。
// 設定は OneManCursor.ini (この exe と同じフォルダ) に書く:
//   name=表示名 / id=自分のID(自動生成) / links=隣の割り当て(自動) / push=端の押し込み量(px、0=即時) / clip=クリップボード共有(1で有効)

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    private const int Port = 45987;
    private const string Magic = "FSWIPE1 ";

    // ---- 設定と自分の情報 ----
    private static string myId;
    private static string myName;
    private static readonly Dictionary<string, string> configKv = new Dictionary<string, string>();
    // 隣接リンク(dir + spec)。spec は "相手ID" または "相手ID@開始@終了"(辺の重なり)
    private sealed class PeerLinkC
    {
        public string Dir;
        public string Spec;
        public string Id { get { return SpecId(Spec); } }
    }
    private static readonly List<PeerLinkC> links = new List<PeerLinkC>();
    // マシンの色(ID → "#RRGGBB")。Mac 側の割り当てで配られる(将来のボーダー表示用に保持)
    private static Dictionary<string, string> colorMap = new Dictionary<string, string>();
    // ビルド番号(版の確認用。機能を変えたら上げる)
    private const string BuildTag = "Build 20261030-13";

    private static string SpecId(string spec)
    {
        int at = spec.IndexOf('@');
        return at < 0 ? spec : spec.Substring(0, at);
    }

    private static void SpecSpan(string spec, out double s, out double e)
    {
        s = 0; e = 1;
        string[] p = spec.Split('@');
        double a, b;
        if (p.Length == 3
            && double.TryParse(p[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out a)
            && double.TryParse(p[2], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out b))
        { s = Math.Min(a, b); e = Math.Max(a, b); }
    }

    private static PeerLinkC FindLink(string dir, double ratio)
    {
        foreach (PeerLinkC l in links)
        {
            if (l.Dir != dir) continue;
            double s, e;
            SpecSpan(l.Spec, out s, out e);
            if (ratio >= s - 0.001 && ratio <= e + 0.001) return l;
        }
        return null;
    }

    private static PeerLinkC FindLinkTo(string id)
    {
        foreach (PeerLinkC l in links) if (l.Id == id) return l;
        return null;
    }

    private static void SaveLinks()
    {
        List<string> parts = new List<string>();
        foreach (PeerLinkC l in links) parts.Add(l.Dir + "=" + l.Spec);
        configKv["links"] = string.Join(";", parts.ToArray());
    }
    private static readonly Dictionary<long, DateTime> seenActions = new Dictionary<long, DateTime>();
    private static readonly Dictionary<string, DateTime> seenCursor = new Dictionary<string, DateTime>();
    private static readonly Dictionary<string, string> peers = new Dictionary<string, string>();
    private static readonly Dictionary<string, IPAddress> peerIps = new Dictionary<string, IPAddress>();
    private static long fastSeq = 0;
    private static UdpClient sender;

    // ---- カーソル共有の状態 ----
    private static bool holding = false;
    private static string cameFrom = null;
    private static string forwardTo = null;
    private static string cursorAt = null; // カーソルが今いるマシン
    private static System.Threading.SynchronizationContext uiCtx;
    // 切り替え画面の連動(タスクビュー / Alt+Tab)
    private static bool switching = false;
    private static DateTime switchAt = DateTime.MinValue;
    private static bool altTabArmed = false;
    private static bool winTabArmed = false;
    private static IntPtr kbHook = IntPtr.Zero;
    private static IntPtr fgHook = IntPtr.Zero;
    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
    private static LowLevelKeyboardProc kbProc;
    private static WinEventDelegate fgProc;
    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    private static double vx = 0, vy = 0;
    private static int pushPx = 0;
    private static double pushAccR = 0, pushAccL = 0, pushAccD = 0, pushAccU = 0;

    // ---- クリップボード共有 ----
    private static bool clipEnabled = false;
    private static uint lastClipSeq = 0;
    private static bool clipSeqReady = false;
    private static uint clipAppliedSeq = 0;
    private static bool clipAppliedValid = false;
    private static int clipSendCounter = 0;
    private static string pendingClip = null;
    private static readonly object clipLock = new object();
    private sealed class ClipAsm { public int Total; public Dictionary<int, string> Parts = new Dictionary<int, string>(); public DateTime First = DateTime.UtcNow; }
    private static readonly Dictionary<string, ClipAsm> clipAsm = new Dictionary<string, ClipAsm>();

    // ---- user32 ----
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUTUNION u; }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    private const uint INPUT_KEYBOARD = 1;
    private const uint INPUT_MOUSE = 0;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const ushort VK_MENU = 0x12;
    private const ushort VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_RETURN = 0x0D;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;

    // 画面全体の外形(仮想スクリーン)
    private static int ScrX { get { return GetSystemMetrics(76); } }
    private static int ScrY { get { return GetSystemMetrics(77); } }
    private static int ScrW { get { return GetSystemMetrics(78); } }
    private static int ScrH { get { return GetSystemMetrics(79); } }

    // ---- 入力の合成 ----
    private static INPUT MakeKey(ushort vk, bool keyUp)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
        return i;
    }

    private static INPUT MakeMouse(uint flags, int data)
    {
        INPUT i = new INPUT();
        i.type = INPUT_MOUSE;
        i.u.mi.dwFlags = flags;
        i.u.mi.mouseData = unchecked((uint)data);
        return i;
    }

    private static void SendInputs(params INPUT[] inputs)
    {
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static void AltCombo(ushort vk)
    {
        SendInputs(MakeKey(VK_MENU, false), MakeKey(vk, false), MakeKey(vk, true), MakeKey(VK_MENU, true));
    }

    private static void PressKey(ushort vk) { SendInputs(MakeKey(vk, false), MakeKey(vk, true)); }

    // ---- 合図の送信 ----
    private static void SendBytes(byte[] data, string body)
    {
        // 宛先の IP が分かればユニキャスト、無ければブロードキャスト。
        // ブロードキャストは Wi-Fi で遅延・落下が多く、カクつきと合図落ちの原因になる
        IPAddress ip = IPAddress.Broadcast;
        string[] bp = body.Split(' ');
        IPAddress known;
        if (bp.Length >= 2 && peerIps.TryGetValue(bp[1], out known)) ip = known;
        try { sender.Send(data, data.Length, new IPEndPoint(ip, Port)); }
        catch (Exception) { /* 送れなくても落とさない */ }
    }

    private static void SendRaw(string body)
    {
        byte[] data = Encoding.UTF8.GetBytes(Magic + myId + " " + Interlocked.Increment(ref fastSeq) + " " + body);
        SendBytes(data, body);
    }

    private static void SendFast(string body)
    {
        byte[] data = Encoding.UTF8.GetBytes(Magic + myId + " " + Interlocked.Increment(ref fastSeq) + " " + body);
        if (body.StartsWith("mv ")) { SendBytes(data, body); return; }
        // 出来事系(enter/leave/キー/クリック等)は落とすと致命的なので、同じデータを3回送る(受け側で重複を捨てる)
        ThreadPool.QueueUserWorkItem(delegate
        {
            for (int i = 0; i < 3; i++)
            {
                SendBytes(data, body);
                if (i < 2) Thread.Sleep(10);
            }
        });
    }

    private static void SendHello()
    {
        byte[] data = Encoding.UTF8.GetBytes(Magic + myId + " 0 hello " + myName + " " + ScrW + "x" + ScrH);
        try { sender.Send(data, data.Length, new IPEndPoint(IPAddress.Broadcast, Port)); }
        catch (Exception) { }
    }

    // ---- 設定ファイル ----
    private static void LoadConfig()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string path = Path.Combine(dir, "OneManCursor.ini");
        // 旧名(FinderSwipePeer.ini)の設定があれば引き継ぐ(ID が変わると Mac 側で別人に見えるため)
        string oldPath = Path.Combine(dir, "FinderSwipePeer.ini");
        if (!File.Exists(path) && File.Exists(oldPath))
        {
            try { File.Copy(oldPath, path); } catch (Exception) { }
        }
        Dictionary<string, string> kv = configKv;
        if (File.Exists(path))
        {
            foreach (string line in File.ReadAllLines(path))
            {
                string t = line.Trim();
                if (t.Length == 0 || t.StartsWith(";") || t.StartsWith("#")) continue;
                int eq = t.IndexOf('=');
                if (eq > 0) kv[t.Substring(0, eq).Trim().ToLower()] = t.Substring(eq + 1).Trim();
            }
        }
        string id;
        if (!kv.TryGetValue("id", out id) || id.Length == 0)
        {
            id = Guid.NewGuid().ToString("N").Substring(0, 8);
            kv["id"] = id;
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("; ワンマンカーソル Windows 設定 (相手のIDは各マシンの表示に合わせて書き換える)");
            foreach (KeyValuePair<string, string> p in kv) sb.AppendLine(p.Key + "=" + p.Value);
            if (!kv.ContainsKey("name")) sb.AppendLine("name=" + Environment.MachineName);
            if (!kv.ContainsKey("left")) sb.AppendLine("left=");
            if (!kv.ContainsKey("right")) sb.AppendLine("right=");
            try { File.WriteAllText(path, sb.ToString()); } catch (Exception) { }
        }
        myId = id;
        string nm;
        myName = kv.TryGetValue("name", out nm) && nm.Length > 0 ? nm : Environment.MachineName;
        string lv;
        if (kv.TryGetValue("links", out lv) && lv.Length > 0)
        {
            foreach (string tok in lv.Split(';'))
            {
                int eq = tok.IndexOf('=');
                if (eq <= 0) continue;
                PeerLinkC l = new PeerLinkC();
                l.Dir = tok.Substring(0, eq);
                l.Spec = tok.Substring(eq + 1);
                if (l.Spec.Length > 0) links.Add(l);
            }
        }
        else
        {
            foreach (string d in new string[] { "left", "right", "up", "down" })
            {
                string v;
                if (kv.TryGetValue(d, out v) && v.Length > 0)
                {
                    PeerLinkC l = new PeerLinkC();
                    l.Dir = d;
                    l.Spec = v;
                    links.Add(l);
                }
            }
        }
        string pv;
        string colorsV;
        if (kv.TryGetValue("colors", out colorsV) && colorsV.Length > 0)
        {
            foreach (string tok in colorsV.Split(';'))
            {
                int eq = tok.IndexOf('=');
                if (eq > 0) colorMap[tok.Substring(0, eq)] = tok.Substring(eq + 1);
            }
        }
        if (kv.TryGetValue("push", out pv)) int.TryParse(pv, out pushPx);
        string cv;
        clipEnabled = kv.TryGetValue("clip", out cv) && cv == "1";
    }

    private static string OppositeDir(string d)
    {
        if (d == "right") return "left";
        if (d == "left") return "right";
        if (d == "up") return "down";
        if (d == "down") return "up";
        return null;
    }

    // 学習した隣を ini にも書き戻す(次回起動でも覚えているように)
    private static void SaveConfig()
    {
        try
        {
            string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "OneManCursor.ini");
            SaveLinks();
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("; ワンマンカーソル Windows 設定 (隣は自動でも覚えます)");
            string v;
            sb.AppendLine("name=" + (configKv.TryGetValue("name", out v) ? v : ""));
            sb.AppendLine("id=" + myId);
            sb.AppendLine("links=" + (configKv.TryGetValue("links", out v) ? v : ""));
            sb.AppendLine("colors=" + (configKv.TryGetValue("colors", out v) ? v : ""));
            sb.AppendLine("push=" + (configKv.TryGetValue("push", out v) ? v : ""));
            sb.AppendLine("clip=" + (configKv.TryGetValue("clip", out v) ? v : ""));
            File.WriteAllText(path, sb.ToString());
        }
        catch (Exception) { }
    }

    private static void LearnNeighbor(string dir, string id)
    {
        foreach (PeerLinkC l in links) if (l.Dir == dir && l.Id == id) return; // 割り当て済み(スパン付き含む)は壊さない
        links.RemoveAll(l => l.Id == id || l.Dir == dir);
        PeerLinkC nl = new PeerLinkC();
        nl.Dir = dir;
        nl.Spec = id;
        links.Add(nl);
        SaveConfig();
        Log("カーソル共有: 隣 (" + dir + ") に " + PeerName(id) + " を覚えました");
    }

    private static string DirOf(string id)
    {
        PeerLinkC l = FindLinkTo(id);
        return l != null ? l.Dir : null;
    }

    private static string PeerName(string id)
    {
        string n;
        return peers.TryGetValue(id, out n) ? n : "相手";
    }

    // ---- カーソル共有 ----
    private static void PositionAtEdge(string dir, double ratio, string peerId)
    {
        // 届いた位置は「共有辺の中の割合」なので、自分の辺の割合に直す
        PeerLinkC l = FindLinkTo(peerId);
        if (l != null)
        {
            double s, e;
            SpecSpan(l.Spec, out s, out e);
            ratio = s + ratio * (e - s);
        }
        if (dir == "right") { vx = ScrX + ScrW - 1; vy = ScrY + ratio * ScrH; }
        else if (dir == "left") { vx = ScrX; vy = ScrY + ratio * ScrH; }
        else if (dir == "down") { vy = ScrY + ScrH - 1; vx = ScrX + ratio * ScrW; }
        else { vy = ScrY; vx = ScrX + ratio * ScrW; } // up
        Warp();
    }

    private static void Warp() { SetCursorPos((int)vx, (int)vy); }

    private static void ClearPush() { pushAccR = 0; pushAccL = 0; pushAccD = 0; pushAccU = 0; }

    private static bool Cross(string dir, double ratio)
    {
        PeerLinkC l = FindLink(dir, ratio);
        if (l == null) return false;
        double s, e;
        SpecSpan(l.Spec, out s, out e);
        double seg = e > s ? Math.Min(1, Math.Max(0, (ratio - s) / (e - s))) : 0.5;
        string next = l.Id;
        string segText = seg.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (next == cameFrom)
        {
            SendFast("leave " + next + " " + segText);
            holding = false;
            cameFrom = null;
            Log("カーソル共有: 手元に返しました");
        }
        else
        {
            SendFast("enter " + next + " " + segText + " " + dir);
            forwardTo = next;
            holding = false;
            Log("カーソル共有: " + PeerName(next) + " へ渡しました");
        }
        return true;
    }

    private static void ApplyCursor(string kind, string[] args)
    {
        if (kind == "mv")
        {
            double dx, dy;
            if (args.Length < 2 || !double.TryParse(args[0], out dx) || !double.TryParse(args[1], out dy)) return;
            vx += dx; vy += dy;
            double ry = (vy - ScrY) / ScrH;
            double rx = (vx - ScrX) / ScrW;
            if (pushPx <= 0)
            {
                if (vx >= ScrX + ScrW && Cross("right", ry)) return;
                if (vx < ScrX && Cross("left", ry)) return;
                if (vy >= ScrY + ScrH && Cross("down", rx)) return;
                if (vy < ScrY && Cross("up", rx)) return;
            }
            else
            {
                // 端に張り付いたまま押し込んだ量が push= の値に達したら渡す
                if (vx >= ScrX + ScrW) { pushAccR += vx - (ScrX + ScrW - 1); vx = ScrX + ScrW - 1; if (pushAccR >= pushPx) { ClearPush(); if (Cross("right", ry)) return; } }
                else pushAccR = 0;
                if (vx < ScrX) { pushAccL += ScrX - vx; vx = ScrX; if (pushAccL >= pushPx) { ClearPush(); if (Cross("left", ry)) return; } }
                else pushAccL = 0;
                if (vy >= ScrY + ScrH) { pushAccD += vy - (ScrY + ScrH - 1); vy = ScrY + ScrH - 1; if (pushAccD >= pushPx) { ClearPush(); if (Cross("down", rx)) return; } }
                else pushAccD = 0;
                if (vy < ScrY) { pushAccU += ScrY - vy; vy = ScrY; if (pushAccU >= pushPx) { ClearPush(); if (Cross("up", rx)) return; } }
                else pushAccU = 0;
            }
            if (vx < ScrX) vx = ScrX;
            if (vx > ScrX + ScrW - 1) vx = ScrX + ScrW - 1;
            if (vy < ScrY) vy = ScrY;
            if (vy > ScrY + ScrH - 1) vy = ScrY + ScrH - 1;
            Warp();
        }
        else if (kind == "dn" || kind == "up")
        {
            int b;
            if (args.Length < 1 || !int.TryParse(args[0], out b)) return;
            bool down = kind == "dn";
            uint f = b == 1 ? (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP)
                   : b == 2 ? (down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP)
                   : (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
            SendInputs(MakeMouse(f, 0));
        }
        else if (kind == "sc")
        {
            int dy;
            if (args.Length < 2 || !int.TryParse(args[0], out dy)) return;
            SendInputs(MakeMouse(MOUSEEVENTF_WHEEL, dy * 6)); // 倍率は感触に合わせて調整
        }
        else if (kind == "kd" || kind == "ku")
        {
            int code; long flags;
            if (args.Length < 2 || !int.TryParse(args[0], out code) || !long.TryParse(args[1], out flags)) return;
            bool down = kind == "kd";
            bool cmd = (flags & 0x100000L) != 0;
            // ⌘[ / ⌘] は文字キーではなく、Windows のブラウザ「戻る/進む」専用キーへ割り振る
            if (cmd && code == 33) { SendInputs(MakeKey(0xA6, !down)); return; }
            if (cmd && code == 30) { SendInputs(MakeKey(0xA7, !down)); return; }
            if (cmd && code == 126 && ForegroundKind() == Foreground.Explorer)
            {
                // エクスプローラーの「上の階層へ」= Alt+↑
                if (down) SendInputs(MakeKey(0x12, false), MakeKey(0x26, false));
                else SendInputs(MakeKey(0x26, true), MakeKey(0x12, true));
                return;
            }
            if (cmd && code == 31 && ForegroundKind() == Foreground.Explorer)
            {
                // エクスプローラーの「開く」= Enter
                SendInputs(MakeKey(0x0D, !down));
                return;
            }
            ushort vk;
            if (MacKeyToVK.TryGetValue(code, out vk)) SendInputs(MakeKey(vk, kind == "ku"));
        }
        else if (kind == "fl")
        {
            int code; long flags;
            if (args.Length < 2 || !int.TryParse(args[0], out code) || !long.TryParse(args[1], out flags)) return;
            long bit = code == 56 || code == 60 ? 0x20000L
                     : code == 59 || code == 62 ? 0x40000L
                     : code == 58 || code == 61 ? 0x80000L
                     : code == 55 || code == 54 ? 0x100000L : 0L;
            ushort vk;
            if (bit != 0 && MacKeyToVK.TryGetValue(code, out vk))
                SendInputs(MakeKey(vk, (flags & bit) == 0));
        }
    }

    private static void HandleAssign(string[] args)
    {
        links.Clear();
        Dictionary<string, string> newColors = new Dictionary<string, string>();
        foreach (string t in args)
        {
            if (t.StartsWith("c:"))
            {
                string kv = t.Substring(2);
                int ceq = kv.IndexOf('=');
                if (ceq > 0) newColors[kv.Substring(0, ceq)] = kv.Substring(ceq + 1);
                continue;
            }
            int eq = t.IndexOf('=');
            if (eq <= 0) continue;
            string d = t.Substring(0, eq);
            if (d != "left" && d != "right" && d != "up" && d != "down") continue;
            PeerLinkC l = new PeerLinkC();
            l.Dir = d;
            l.Spec = t.Substring(eq + 1);
            if (l.Spec.Length > 0) links.Add(l);
        }
        if (newColors.Count > 0)
        {
            colorMap = newColors;
            List<string> cparts = new List<string>();
            foreach (KeyValuePair<string, string> p in colorMap) cparts.Add(p.Key + "=" + p.Value);
            configKv["colors"] = string.Join(";", cparts.ToArray());
        }
        SaveConfig();
        Log("レイアウト: 割り当てを受けました");
    }

    // ---- クリップボード共有(テキストのみ・上限64KB) ----

    private static void HandleClipChunk(string[] args, string from)
    {
        if (!clipEnabled || args.Length < 4) return;
        int idx, total;
        if (!int.TryParse(args[1], out idx) || !int.TryParse(args[2], out total)) return;
        if (total < 1 || total > 200 || idx < 0 || idx >= total) return;
        string key = from + "|" + args[0];
        lock (clipLock)
        {
            ClipAsm asm;
            if (!clipAsm.TryGetValue(key, out asm)) { asm = new ClipAsm(); asm.Total = total; clipAsm[key] = asm; }
            asm.Parts[idx] = args[3];
            List<string> dead = new List<string>();
            foreach (KeyValuePair<string, ClipAsm> p in clipAsm)
                if ((DateTime.UtcNow - p.Value.First).TotalSeconds > 10) dead.Add(p.Key);
            foreach (string k in dead) clipAsm.Remove(k);
            if (asm.Parts.Count < asm.Total) return;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < asm.Total; i++)
            {
                string part;
                if (!asm.Parts.TryGetValue(i, out part)) return;
                sb.Append(part);
            }
            clipAsm.Remove(key);
            string text;
            try { text = Encoding.UTF8.GetString(Convert.FromBase64String(sb.ToString())); }
            catch (Exception) { return; }
            if (text.Length == 0 || Encoding.UTF8.GetByteCount(text) > 65536) return;
            pendingClip = text;
        }
    }

    private static void SendClipText(string text)
    {
        string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        int chunk = 800;
        int total = (b64.Length + chunk - 1) / chunk;
        string tid = myId + "-" + (++clipSendCounter);
        List<string> targets = new List<string>(peers.Keys);
        foreach (string peer in targets)
        {
            for (int i = 0; i < total; i++)
            {
                int len = Math.Min(chunk, b64.Length - i * chunk);
                SendFast("clip " + peer + " " + tid + " " + i + " " + total + " " + b64.Substring(i * chunk, len));
            }
        }
        Log("クリップボード共有: テキストを送りました");
    }

    /// トレイのタイマー(UIスレッド)から 500ms ごとに呼ばれる
    private static void PollClipboard()
    {
        string pending = null;
        lock (clipLock) { pending = pendingClip; pendingClip = null; }
        if (pending != null)
        {
            try
            {
                Clipboard.SetText(pending);
                clipAppliedSeq = GetClipboardSequenceNumber();
                clipAppliedValid = true;
                Log("クリップボード共有: テキストを受け取りました");
            }
            catch (Exception) { }
        }
        uint seq = GetClipboardSequenceNumber();
        if (!clipEnabled) { lastClipSeq = seq; clipSeqReady = true; return; }
        if (!clipSeqReady) { lastClipSeq = seq; clipSeqReady = true; return; }
        if (seq == lastClipSeq) return;
        lastClipSeq = seq;
        if (clipAppliedValid && seq == clipAppliedSeq) return; // 自分が受けて入れたもの
        string text = null;
        try { if (Clipboard.ContainsText()) text = Clipboard.GetText(); } catch (Exception) { }
        if (string.IsNullOrEmpty(text)) return;
        if (Encoding.UTF8.GetByteCount(text) > 65536) return;
        SendClipText(text);
    }

    // カーソルの現在地を全マシンへ知らせる(自分が保持者になったとき)
    private static void SendAtSelf()
    {
        cursorAt = myId;
        List<string> ids = new List<string>(peers.Keys);
        foreach (string pid in ids)
        {
            if (pid != myId) SendFast("at " + pid + " " + myId);
        }
    }

    // ---- 切り替え画面の連動 ----
    private static bool SwitchAlive()
    {
        return switching && (DateTime.Now - switchAt).TotalSeconds < 20;
    }

    private static void SetSwitching(bool on)
    {
        switching = on;
        if (on) switchAt = DateTime.Now;
    }

    private static void SendSwitchAll(string kind)
    {
        List<string> ids = new List<string>(peers.Keys);
        foreach (string pid in ids)
        {
            if (pid != myId) SendFast(kind + " " + pid);
        }
    }

    /// 合図を受けて自分のタスクビューを開く
    private static void OpenSwitchLocal()
    {
        SetSwitching(true);
        SendInputs(MakeKey(0x5B, false), MakeKey(0x09, false), MakeKey(0x09, true), MakeKey(0x5B, true));
    }

    /// 他端末から「確定」を受けた: 一覧を開いているときだけ Esc で閉じる
    private static void ReceiveDoneSwitch()
    {
        if (!SwitchAlive()) return;
        switching = false;
        SendInputs(MakeKey(0x1B, false), MakeKey(0x1B, true));
    }

    /// 自分が確定した: 他端末へ知らせる(自分は閉じなくてよい)
    private static void DecideSwitch()
    {
        if (!SwitchAlive()) return;
        switching = false;
        SendSwitchAll("done");
    }

    private static void InstallSwitchHooks()
    {
        kbProc = KbHookCallback;
        fgProc = FgCallback;
        kbHook = SetWindowsHookEx(13, kbProc, GetModuleHandle(null), 0);
        fgHook = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, fgProc, 0, 0, 0);
    }

    private static IntPtr KbHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            try
            {
                int vk = System.Runtime.InteropServices.Marshal.ReadInt32(lParam);
                int msg = wParam.ToInt32();
                bool down = msg == 0x0100 || msg == 0x0104;
                bool up = msg == 0x0101 || msg == 0x0105;
                if (down && vk == 0x09)
                {
                    if ((GetAsyncKeyState(0x12) & 0x8000) != 0)
                    {
                        // Alt+Tab 開始: 一覧を開いた扱いにし、他端末へ「開く」合図(Alt を離すまで再送しない)
                        if (!altTabArmed) { altTabArmed = true; SetSwitching(true); SendSwitchAll("open"); }
                    }
                    else if ((GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0)
                    {
                        // Win+Tab(タスクビュー)開始
                        if (!winTabArmed) { winTabArmed = true; SetSwitching(true); SendSwitchAll("open"); }
                    }
                }
                else if (up && (vk == 0x12 || vk == 0xA4 || vk == 0xA5))
                {
                    // Alt を離した = Alt+Tab の確定
                    if (altTabArmed) { altTabArmed = false; DecideSwitch(); }
                }
                else if (up && (vk == 0x5B || vk == 0x5C))
                {
                    winTabArmed = false;
                }
                else if (down && vk == 0x1B)
                {
                    // Esc で一覧を閉じたときも確定と同じ扱い
                    DecideSwitch();
                }
            }
            catch (Exception) { }
        }
        return CallNextHookEx(kbHook, nCode, wParam, lParam);
    }

    private static void FgCallback(IntPtr h, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        // 最前面ウィンドウの変化 = タスクビューでの確定(開いた直後の変化は除く)
        if (!SwitchAlive()) return;
        if ((DateTime.Now - switchAt).TotalMilliseconds < 700) return;
        DecideSwitch();
    }

    /// 画面確認: 自分の色で画面全体を薄く光らせる
    private static Form identifyForm;
    private static void ShowIdentify()
    {
        if (uiCtx == null) return;
        uiCtx.Post(delegate
        {
            try
            {
                if (identifyForm == null)
                {
                    identifyForm = new Form();
                    identifyForm.FormBorderStyle = FormBorderStyle.None;
                    identifyForm.ShowInTaskbar = false;
                    identifyForm.TopMost = true;
                    identifyForm.StartPosition = FormStartPosition.Manual;
                    Label lb = new Label();
                    lb.Name = "lb";
                    lb.Dock = DockStyle.Fill;
                    lb.TextAlign = ContentAlignment.MiddleCenter;
                    lb.Font = new Font("Yu Gothic UI", 48, FontStyle.Bold);
                    lb.ForeColor = Color.White;
                    identifyForm.Controls.Add(lb);
                }
                Color c = Color.FromArgb(0, 120, 215);
                string hex;
                if (colorMap.TryGetValue(myId, out hex))
                {
                    try { c = ColorTranslator.FromHtml(hex); } catch (Exception) { }
                }
                identifyForm.BackColor = c;
                identifyForm.Opacity = 0.35;
                identifyForm.Bounds = SystemInformation.VirtualScreen;
                ((Label)identifyForm.Controls["lb"]).Text = myName;
                identifyForm.Show();
                identifyForm.BringToFront();
                System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
                t.Interval = 1600;
                t.Tick += delegate { t.Stop(); identifyForm.Hide(); t.Dispose(); };
                t.Start();
            }
            catch (Exception) { }
        }, null);
    }

    private static void ReceiveCursor(string kind, string[] rest, string from)
    {
        // rest[0] は宛先ID
        if (rest.Length < 1 || rest[0] != myId) return;
        string[] args = new string[rest.Length - 1];
        Array.Copy(rest, 1, args, 0, args.Length);

        if (kind == "clip") { HandleClipChunk(args, from); return; }
        if (kind == "assign") { HandleAssign(args); return; }
        if (kind == "at") { if (args.Length >= 1) cursorAt = args[0]; return; }
        if (kind == "open") { OpenSwitchLocal(); return; }
        if (kind == "done") { ReceiveDoneSwitch(); return; }
        if (kind == "identify") { ShowIdentify(); return; }
        if (kind == "enter")
        {
            if (holding || forwardTo != null || args.Length < 1) return;
            double ratio;
            if (!double.TryParse(args[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out ratio)) ratio = 0.5;
            holding = true;
            cameFrom = from;
            string d = null;
            if (args.Length > 1)
            {
                // 送り手が「出た方向」を付けていれば、その反対側の隣として自動で覚える(ini 編集は不要になる)
                string od = OppositeDir(args[1]);
                if (od != null) { LearnNeighbor(od, from); d = od; }
            }
            if (d == null) d = DirOf(from);
            if (d != null) PositionAtEdge(d, ratio, from);
            Log("カーソル共有: " + PeerName(from) + " から受け取りました");
            SendAtSelf();
        }
        else if (kind == "leave")
        {
            if (forwardTo == from && args.Length >= 1)
            {
                double ratio;
                if (!double.TryParse(args[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out ratio)) ratio = 0.5;
                forwardTo = null;
                holding = true; // cameFrom は元の相手のまま
                string d = DirOf(from);
                if (d != null) PositionAtEdge(d, ratio, from);
                Log("カーソル共有: 戻ってきました");
                SendAtSelf();
            }
        }
        else
        {
            if (holding) ApplyCursor(kind, args);
            else if (forwardTo != null) SendFast(kind + " " + forwardTo + " " + string.Join(" ", args));
        }
    }

    // Mac のキーコード → Windows の仮想キーコード(主なものだけ)
    private static readonly Dictionary<int, ushort> MacKeyToVK = new Dictionary<int, ushort>
    {
        {0,0x41},{1,0x53},{2,0x44},{3,0x46},{4,0x48},{5,0x47},{6,0x5A},{7,0x58},{8,0x43},{9,0x56},
        {11,0x42},{12,0x51},{13,0x57},{14,0x45},{15,0x52},{16,0x59},{17,0x54},{31,0x4F},{32,0x55},
        {34,0x49},{35,0x50},{37,0x4C},{38,0x4A},{40,0x4B},{45,0x4E},{46,0x4D},
        {18,0x31},{19,0x32},{20,0x33},{21,0x34},{23,0x35},{22,0x36},{26,0x37},{28,0x38},{25,0x39},{29,0x30},
        {49,0x20},{36,0x0D},{53,0x1B},{48,0x09},{51,0x08},{117,0x2E},{115,0x24},{119,0x23},{116,0x21},{121,0x22},
        {123,0x25},{124,0x27},{125,0x28},{126,0x26},
        {33,0xDB},{30,0xDD},{41,0xBA},{39,0xDE},{43,0xBC},{47,0xBE},{44,0xBF},{42,0xDC},{27,0xBD},{24,0xBB},{50,0xC0},
        {122,0x70},{120,0x71},{99,0x72},{118,0x73},{96,0x74},{97,0x75},{98,0x76},{100,0x77},{101,0x78},{109,0x79},{103,0x7A},{111,0x7B},
        {57,0x14},{55,0x5B},{54,0x5B},{56,0x10},{60,0x10},{58,0x12},{61,0x12},{59,0x11},{62,0x11},
    };

    // ---- スワイプの合図 ----
    private enum Foreground { None, Explorer, Chromium }

    private static Foreground ForegroundKind()
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(GetForegroundWindow(), sb, sb.Capacity);
        string cls = sb.ToString();
        if (cls == "CabinetWClass" || cls == "ExploreWClass") return Foreground.Explorer;
        if (cls == "Chrome_WidgetWin_1") return Foreground.Chromium;
        return Foreground.None;
    }

    private static void ActSwipe(string action)
    {
        switch (action)
        {
            case "back": AltCombo(VK_LEFT); break;
            case "forward": AltCombo(VK_RIGHT); break;
            case "parent": AltCombo(VK_UP); break;
            case "open": PressKey(VK_RETURN); break;
            default: return;
        }
        Log("実行: " + action);
    }

    private static void ReceiveSwipe(string action, long seq)
    {
        DateTime now = DateTime.UtcNow;
        DateTime seenAt;
        if (seenActions.TryGetValue(seq, out seenAt) && (now - seenAt).TotalSeconds < 2) return;
        seenActions[seq] = now;

        Foreground kind = ForegroundKind();
        if (kind == Foreground.None)
        {
            Log("受信: " + action + " (対応アプリが最前面ではないので実行しません)");
            return;
        }
        if (kind == Foreground.Chromium && action != "back" && action != "forward")
        {
            Log("受信: " + action + " (Chromium 系では履歴移動だけ対応)");
            return;
        }
        Log("受信: " + action);
        ActSwipe(action);
    }

    private static Mutex singleMutex;

    // ---- ログ(常駐アプリなのでコンソールではなくメモリに貯め、必要なときだけ窓で見る) ----
    private static readonly List<string> logLines = new List<string>();
    private static TextBox logBox;
    private static Form logForm;

    private static void Log(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + " " + s;
        lock (logLines)
        {
            logLines.Add(line);
            if (logLines.Count > 300) logLines.RemoveAt(0);
        }
        TextBox tb = logBox;
        if (tb != null && !tb.IsDisposed)
        {
            try { tb.BeginInvoke((MethodInvoker)delegate { if (logBox != null) logBox.AppendText(line + "\r\n"); }); }
            catch (Exception) { }
        }
    }

    private static void ShowLogWindow()
    {
        if (logForm != null && !logForm.IsDisposed) { logForm.Activate(); return; }
        logForm = new Form();
        logForm.Text = "ワンマンカーソル - ログ (自分の ID: " + myId + ")";
        logForm.Width = 680;
        logForm.Height = 380;
        TextBox tb = new TextBox();
        tb.Multiline = true;
        tb.ReadOnly = true;
        tb.Dock = DockStyle.Fill;
        tb.ScrollBars = ScrollBars.Vertical;
        tb.Font = new Font("Consolas", 9);
        lock (logLines) { tb.Text = string.Join("\r\n", logLines.ToArray()) + "\r\n"; }
        logBox = tb;
        logForm.Controls.Add(tb);
        logForm.FormClosed += delegate { logBox = null; logForm = null; };
        logForm.Show();
    }

    private static Icon MakeWaIcon()
    {
        Bitmap bmp = new Bitmap(32, 32);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.FromArgb(64, 100, 220));
            using (Font f = new Font("Meiryo UI", 17, FontStyle.Bold))
            using (Brush b = new SolidBrush(Color.White))
            {
                g.DrawString("ワ", f, b, 1, 3);
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    private sealed class TrayContext : ApplicationContext
    {
        private readonly NotifyIcon icon;
        private readonly ToolStripMenuItem cursorItem;
        private readonly System.Windows.Forms.Timer clipTimer;

        public TrayContext()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("ログを表示", null, delegate { ShowLogWindow(); });
            menu.Items.Add(BuildTag, null, null).Enabled = false;
            cursorItem = new ToolStripMenuItem("カーソル: 自分");
            cursorItem.Enabled = false;
            menu.Items.Add(cursorItem);
            menu.Opening += delegate
            {
                cursorItem.Text = (cursorAt == null || cursorAt == myId) ? "カーソル: 自分" : "カーソル: " + PeerName(cursorAt);
            };
            menu.Items.Add("自分の ID: " + myId, null, null).Enabled = false;
            ToolStripMenuItem clipItem = new ToolStripMenuItem("クリップボード共有");
            clipItem.Checked = clipEnabled;
            clipItem.Click += delegate
            {
                clipEnabled = !clipEnabled;
                clipItem.Checked = clipEnabled;
                configKv["clip"] = clipEnabled ? "1" : "0";
                SaveConfig();
                Log("クリップボード共有: " + (clipEnabled ? "オン" : "オフ"));
            };
            menu.Items.Add(clipItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("終了", null, delegate { Exit(); });
            InstallSwitchHooks();
            uiCtx = System.Threading.SynchronizationContext.Current;
            icon = new NotifyIcon();
            icon.Text = "ワンマンカーソル " + BuildTag + " (ID: " + myId + ")";
            icon.Icon = MakeWaIcon();
            icon.ContextMenuStrip = menu;
            icon.Visible = true;
            icon.DoubleClick += delegate { ShowLogWindow(); };
            clipTimer = new System.Windows.Forms.Timer();
            clipTimer.Interval = 500;
            clipTimer.Tick += delegate { PollClipboard(); };
            clipTimer.Start();
        }

        private void Exit()
        {
            icon.Visible = false;
            Environment.Exit(0);
        }
    }

    [STAThread]
    private static void Main()
    {
        // 二重起動の防止(複数動くと合図が重なって競合するため)
        bool createdNew;
        singleMutex = new Mutex(true, "OneManCursor.WindowsPeer", out createdNew);
        if (!createdNew)
        {
            MessageBox.Show("すでに起動しています。二重には起動しません。", "ワンマンカーソル");
            return;
        }
        LoadConfig();
        sender = new UdpClient();
        sender.EnableBroadcast = true;

        Log("ワンマンカーソル OneManCursor (Windows)");
        Log("  名前: " + myName + " / 自分のID: " + myId);
        Log("  画面: " + ScrW + "x" + ScrH + " (原点 " + ScrX + "," + ScrY + ")");
        foreach (PeerLinkC l in links)
            Log("  隣 (" + l.Dir + "): " + l.Spec);
        Log("  UDP " + Port + " で合図を待っています (終了はトレイのアイコンから)");
        Log("  ※ レイアウトは Mac 側の「レイアウトを編集」で自動設定されます");

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Thread helloThread = new Thread(() =>
        {
            while (true) { SendHello(); Thread.Sleep(5000); }
        });
        helloThread.IsBackground = true;
        helloThread.Start();

        Thread netThread = new Thread(ReceiveLoop);
        netThread.IsBackground = true;
        netThread.Start();

        Application.Run(new TrayContext());
    }

    private static void ReceiveLoop()
    {
        UdpClient udp = new UdpClient(Port);
        IPEndPoint fromEp = new IPEndPoint(IPAddress.Any, 0);
        while (true)
        {
            byte[] data = udp.Receive(ref fromEp);
            string s = Encoding.UTF8.GetString(data);
            if (!s.StartsWith(Magic)) continue;
            // 形式: FSWIPE1 <送信元ID> <連番> <種類> [引数...]
            string[] parts = s.Substring(Magic.Length).Split(' ');
            if (parts.Length < 3) continue;
            string from = parts[0];
            if (from == myId) continue;
            peerIps[from] = fromEp.Address;
            string kind = parts[2];
            string[] rest = new string[parts.Length - 3];
            Array.Copy(parts, 3, rest, 0, rest.Length);

            if (kind == "hello")
            {
                string name = string.Join(" ", rest);
                // 末尾の解像度トークン(例 1920x1080)は名前ではないので落とす
                if (rest.Length > 0)
                {
                    string lastTok = rest[rest.Length - 1];
                    int xi = lastTok.IndexOf('x');
                    int hw, hh;
                    if (xi > 0 && int.TryParse(lastTok.Substring(0, xi), out hw) && int.TryParse(lastTok.Substring(xi + 1), out hh))
                        name = string.Join(" ", rest, 0, rest.Length - 1);
                }
                if (!peers.ContainsKey(from)) Log("相方を発見: " + name + " (ID: " + from + ")");
                peers[from] = name.Length > 0 ? name : "Mac";
                continue;
            }
            if (kind == "reset")
            {
                holding = false; cameFrom = null; forwardTo = null;
                Log("カーソル共有: リセットされました");
                continue;
            }
            if (kind == "back" || kind == "forward" || kind == "parent" || kind == "open")
            {
                long seq;
                if (parts.Length == 3 && long.TryParse(parts[1], out seq)) ReceiveSwipe(kind, seq);
                continue;
            }
            // 出来事系は送り手が同じ連番で3回送ってくる(落下対策)。Mac 側は重複を捨てているが
            // Windows 側は捨てていなかったため、キーやクリックが3回ずつ実行されてチャタリングしていた
            long cseq;
            if (long.TryParse(parts[1], out cseq))
            {
                string dupKey = from + "|" + cseq;
                DateTime seenAt;
                if (seenCursor.TryGetValue(dupKey, out seenAt) && (DateTime.UtcNow - seenAt).TotalSeconds < 2) continue;
                seenCursor[dupKey] = DateTime.UtcNow;
                if (seenCursor.Count > 512)
                {
                    List<string> old = new List<string>();
                    foreach (KeyValuePair<string, DateTime> p in seenCursor)
                        if ((DateTime.UtcNow - p.Value).TotalSeconds >= 10) old.Add(p.Key);
                    foreach (string k in old) seenCursor.Remove(k);
                }
            }
            ReceiveCursor(kind, rest, from);
        }
    }
}
