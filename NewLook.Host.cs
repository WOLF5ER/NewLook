using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

internal static class NewLookHost
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        string report = null;

        try
        {
            Guid transaction;
            Action updateReady = null;
            if (arguments.Length == 2 && arguments[0] == "--smoke-test")
                report = Path.GetFullPath(arguments[1]);
            else if (arguments.Length == 2 && arguments[0] == "--update-ready" &&
                Guid.TryParseExact(arguments[1], "N", out transaction))
                updateReady = NewLookUpdate.ReadyCallback(transaction);
            else if (arguments.Length != 0)
                throw new ArgumentException("Неизвестный параметр запуска.");

            var executable = Assembly.GetExecutingAssembly();
            using (var script = new StreamReader(executable.GetManifestResourceStream("NewLook.ps1")))
            using (var runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
            using (var powershell = PowerShell.Create())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                powershell.Runspace = runspace;
                powershell.AddScript(script.ReadToEnd());
                if (report != null)
                    powershell.AddParameter("SmokeTest");
                else
                    powershell.AddParameter("EnableUpdates");
                if (updateReady != null)
                    powershell.AddParameter("UpdateReady", updateReady);

                var output = powershell.Invoke();
                if (powershell.Streams.Error.Count != 0)
                {
                    var errors = new List<string>();
                    foreach (var error in powershell.Streams.Error)
                        errors.Add(error.ToString());
                    throw new InvalidOperationException(string.Join(Environment.NewLine, errors));
                }

                if (report != null)
                {
                    var lines = new List<string>();
                    foreach (var line in output)
                        lines.Add(line.ToString());
                    if (!lines.Exists(line => line.StartsWith("PASS:", StringComparison.Ordinal)))
                        throw new InvalidOperationException("The smoke test did not report success.");
                    File.WriteAllLines(report, lines);
                }
            }
            return 0;
        }
        catch (Exception failure)
        {
            if (report != null)
                File.WriteAllText(report, failure.ToString());
            else
                MessageBox.Show(failure.GetBaseException().Message, "NewLook",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
