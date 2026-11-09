using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;
[assembly: AssemblyTitle("Cleaner")]
[assembly: AssemblyDescription("Cleaner desktop launcher")]
[assembly: AssemblyProduct("Cleaner")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]
internal static class Program {
 [STAThread] static int Main(string[] args) {
  bool check = args.Length == 1 && args[0].Equals("/check", StringComparison.OrdinalIgnoreCase);
  try {
   if(args.Length > 1 || (args.Length == 1 && !check && !args[0].Equals("/admin", StringComparison.OrdinalIgnoreCase))) throw new ArgumentException("Supported options: /admin or /check.");
   string root=AppDomain.CurrentDomain.BaseDirectory;
   string script=Path.Combine(root,"Cleaner.ps1");
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
   foreach(string file in new[]{script,Path.Combine(root,"CleanerEngine.psm1"),ps}) if(!File.Exists(file)) throw new FileNotFoundException("Required file missing: " + file);
   if(check) return 0;
   var start=new ProcessStartInfo(ps,"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
   start.WorkingDirectory=root; start.WindowStyle=ProcessWindowStyle.Hidden;
   start.UseShellExecute=args.Length == 1; start.CreateNoWindow=!start.UseShellExecute;
   if(start.UseShellExecute) start.Verb="runas";
   using(var process=Process.Start(start)) {process.WaitForExit();return process.ExitCode;}
  } catch(System.ComponentModel.Win32Exception ex) {if(ex.NativeErrorCode==1223)return 0; if(!check)MessageBox.Show(ex.Message,"Cleaner",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    catch(Exception ex) {if(!check)MessageBox.Show(ex.Message,"Cleaner",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
 }
}