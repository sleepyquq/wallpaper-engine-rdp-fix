using System;
using System.Diagnostics;
using System.IO;

// 编译为 Windows GUI 程序，从进程创建时就不显示控制台；不依赖 VBScript。
internal static class Launcher {
    [STAThread]
    private static int Main(string[] args) {
        if (args.Length != 1 || (args[0] != "Remote" && args[0] != "Local" && args[0] != "Sync")) return 64;
        string root = AppDomain.CurrentDomain.BaseDirectory;
        try {
            string pwsh = File.ReadAllText(Path.Combine(root, "powershell-path.txt")).Trim();
            string script = Path.Combine(root, "src", "Runtime.ps1");
            var start = new ProcessStartInfo {
                FileName = pwsh,
                Arguments = "-NoLogo -NoProfile -NonInteractive -File \"" + script + "\" -Mode " + args[0],
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process child = Process.Start(start)) {
                child.WaitForExit();
                return child.ExitCode;
            }
        } catch (Exception e) {
            File.AppendAllText(Path.Combine(root, "launcher-errors.log"), DateTimeOffset.Now.ToString("o") + " " + e.Message + Environment.NewLine);
            return 1;
        }
    }
}
