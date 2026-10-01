using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("G HUB 双版本切换器")]
[assembly: AssemblyVersion("1.0.0.0")]
internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length > 1 || (args.Length == 1 && args[0] != "--read-only"))
                throw new ArgumentException("支持的参数：--read-only");
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "Start-GHUBSwitcher.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("请先完整解压软件包，再启动 GHUBSwitcher.exe。", script);
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var info = new ProcessStartInfo(shell);
            info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" + (args.Length == 1 ? " -ReadOnly" : "");
            info.WorkingDirectory = directory;
            info.UseShellExecute = false;
            using (var process = Process.Start(info))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            if (!Console.IsInputRedirected) { Console.WriteLine("按 Enter 关闭窗口。"); Console.ReadLine(); }
            return 1;
        }
    }
}
