// Minimal C# service used to verify the DevStore Windows pipeline for .NET apps.
// Writes a heartbeat to %ProgramData%\hello-windows-dotnet\heartbeat.log every
// 5 seconds and exits cleanly on Ctrl+C / stop.
using System.Reflection;

var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?";
var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "hello-windows-dotnet");
Directory.CreateDirectory(dir);
var log = Path.Combine(dir, "heartbeat.log");
void Write(string msg) => File.AppendAllText(log, $"{DateTime.Now:s} hello-windows-dotnet {version} {msg}{Environment.NewLine}");

using var stop = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => stop.Cancel();

Write("started");
while (!stop.IsCancellationRequested)
{
    try { await Task.Delay(TimeSpan.FromSeconds(5), stop.Token); Write("alive"); }
    catch (TaskCanceledException) { }
}
Write("stopped");
