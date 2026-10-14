using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex Screen Capture")]
[assembly: AssemblyDescription("Capture, annotate and paste images into the current Codex draft without sending")]
[assembly: AssemblyCompany("Orua; based on daftlamb/screen-capture-marketplace")]
[assembly: AssemblyProduct("Codex Screen Capture")]
[assembly: AssemblyVersion("0.2.1.0")]
[assembly: AssemblyFileVersion("0.2.1.0")]

internal static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        try {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexScreenCapture", "0.2.1");
            string scripts = Path.Combine(root, "scripts");
            string runtime = Path.Combine(root, "agent", "temp", "runtime");
            Directory.CreateDirectory(scripts);
            Directory.CreateDirectory(runtime);
            using (var mutex = new Mutex(false, @"Local\CodexScreenCaptureExtractor")) {
                if (!mutex.WaitOne(10000)) throw new IOException("另一个截图程序正在初始化，请稍后再试。");
                try {
                    foreach (string file in new string[] { "hotkey.ps1", "capture.ps1", "composer-paste.ps1", "capture-ui.cs" }) {
                        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("scripts." + file)) {
                            if (stream == null) throw new IOException("缺少内置文件：" + file);
                            using (var bytes = new MemoryStream()) {
                                stream.CopyTo(bytes);
                                byte[] contents = bytes.ToArray();
                                string destination = Path.Combine(scripts, file);
                                if (!File.Exists(destination) || !Equal(File.ReadAllBytes(destination), contents)) File.WriteAllBytes(destination, contents);
                            }
                        }
                    }
                } finally { mutex.ReleaseMutex(); }
            }
            if (Array.IndexOf(args, "--self-test") >= 0) {
                File.WriteAllText(Path.Combine(runtime,"launcher-validation.json"), "{\"version\":\"0.2.1\",\"embeddedFiles\":4,\"extractionVerified\":true}", new UTF8Encoding(false));
                return 0;
            }
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo(powershell,
                "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + Path.Combine(scripts,"hotkey.ps1") + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.WorkingDirectory = root;
            start.RedirectStandardError = true;
            using (var process = Process.Start(start)) {
                string errors = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0) {
                    File.WriteAllText(Path.Combine(runtime,"launcher-error.txt"),errors,new UTF8Encoding(false));
                    MessageBox.Show("截图程序启动失败。请查看运行目录中的 launcher-error.txt。", "Codex 截图", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return process.ExitCode;
            }
        } catch (Exception error) {
            MessageBox.Show(error.Message,"Codex 截图",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
    static bool Equal(byte[] a, byte[] b)
    {
        if(a.Length != b.Length) return false;
        for(int i=0;i<a.Length;i++) if(a[i]!=b[i]) return false;
        return true;
    }
}
