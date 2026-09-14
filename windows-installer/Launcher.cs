using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            bool install = args.Length == 1 && args[0] == "--install";
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, install ? "Install-ChatGPTQuotaPet.ps1" : "ChatGPTQuotaPet.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Missing application file", script);
            if (!install)
            {
                var state = InitialSessionState.CreateDefault();
                state.AuthorizationManager = new AuthorizationManager("ChatGPTQuotaPet");
                using (var runspace = RunspaceFactory.CreateRunspace(state))
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    using (var shell = PowerShell.Create())
                    {
                        shell.Runspace = runspace;
                        shell.AddCommand(script);
                        shell.Invoke();
                        if (shell.HadErrors) throw new Exception(shell.Streams.Error[0].ToString());
                    }
                }
                return 0;
            }
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"" + (install ? "" : " -OpenDashboard"),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = Process.Start(info))
            {
                process.StandardInput.Close();
                process.OutputDataReceived += delegate { };
                process.BeginOutputReadLine();
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                    MessageBox.Show(error.Length == 0 ? "Application failed to start." : error, "ChatGPT Quota Dashboard", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "ChatGPT Quota Dashboard", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
