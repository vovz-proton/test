using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class ScopeViewerLauncher
{
    [STAThread]
    private static void Main()
    {
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string python = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            @".cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe");
        string script = Path.Combine(folder, "scope_viewer.py");
        if (!File.Exists(python) || !File.Exists(script))
        {
            MessageBox.Show("Не найден pythonw.exe или scope_viewer.py.\n" + python,
                "UNI-T Scope Viewer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        Process.Start(new ProcessStartInfo
        {
            FileName = python,
            Arguments = "\"" + script + "\"",
            WorkingDirectory = folder,
            UseShellExecute = false,
            CreateNoWindow = true
        });
    }
}
