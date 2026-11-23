using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal sealed class GitHubRelease
{
    public string tag_name { get; set; }
    public bool draft { get; set; }
    public bool prerelease { get; set; }
    public GitHubAsset[] assets { get; set; }
}

public sealed class GitHubAsset
{
    public string name { get; set; }
    public string browser_download_url { get; set; }
    public string digest { get; set; }
    public int size { get; set; }
}

public sealed class UpdatePackage
{
    internal GitHubAsset Asset;
    public Version Version { get; internal set; }
}

public sealed class PreparedUpdate
{
    internal string path;
    internal UpdatePackage package;
}

public static class NewLookUpdate
{
    private const string Repository = "WOLF5ER/NewLook";
    private const string ReleaseEndpoint = "https://api.github.com/repos/" + Repository + "/releases/latest";
    private const int MaxBytes = 32 * 1024 * 1024;
    private static readonly string Executable = typeof(NewLookUpdate).Assembly.Location;

    public static async Task<UpdatePackage> CheckAsync()
    {
        var json = Encoding.UTF8.GetString(await FetchAsync(new Uri(ReleaseEndpoint)).ConfigureAwait(false));
        return ParseRelease(json, typeof(NewLookUpdate).Assembly.GetName().Version);
    }

    internal static UpdatePackage ParseRelease(string json, Version installed)
    {
        var release = new JavaScriptSerializer().Deserialize<GitHubRelease>(json);
        if (release == null || release.draft || release.prerelease || release.assets == null ||
            !Regex.IsMatch(release.tag_name ?? "", @"^v\d+\.\d+\.\d+$"))
            return null;
        Version published;
        if (!Version.TryParse(release.tag_name.Substring(1) + ".0", out published) || published <= installed)
            return null;

        var url = "https://github.com/" + Repository + "/releases/download/" + release.tag_name + "/NewLook.exe";
        foreach (var asset in release.assets)
        {
            if (asset.name == "NewLook.exe" && asset.browser_download_url == url &&
                asset.size > 0 && asset.size <= MaxBytes &&
                Regex.IsMatch(asset.digest ?? "", @"^sha256:[a-fA-F0-9]{64}$"))
                return new UpdatePackage { Asset = asset, Version = published };
        }
        return null;
    }

    private static async Task<byte[]> FetchAsync(Uri uri)
    {
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        using (var handler = new HttpClientHandler { AllowAutoRedirect = false })
        using (var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30), MaxResponseContentBufferSize = MaxBytes })
        {
            client.DefaultRequestHeaders.UserAgent.ParseAdd("NewLook/" + typeof(NewLookUpdate).Assembly.GetName().Version);
            for (int remaining = 5; remaining > 0; remaining--)
            {
                if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 ||
                    (uri.Host != "api.github.com" && uri.Host != "github.com" &&
                     uri.Host != "release-assets.githubusercontent.com" && uri.Host != "objects.githubusercontent.com"))
                    throw new IOException("GitHub вернул неожиданный адрес загрузки.");
                using (var response = await client.GetAsync(uri).ConfigureAwait(false))
                {
                    int status = (int)response.StatusCode;
                    if (status >= 300 && status < 400 && response.Headers.Location != null)
                    {
                        uri = new Uri(uri, response.Headers.Location);
                        continue;
                    }
                    response.EnsureSuccessStatusCode();
                    return await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                }
            }
        }
        throw new IOException("Слишком много перенаправлений при загрузке обновления.");
    }

    internal static void VerifyFile(string path, UpdatePackage package)
    {
        if (new FileInfo(path).Length != package.Asset.size)
            throw new IOException("Размер обновления отличается от опубликованного.");
        using (var sha = SHA256.Create())
        using (var input = File.OpenRead(path))
        {
            var digest = BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "");
            if (!String.Equals(digest, package.Asset.digest.Substring(7), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Контрольная сумма обновления не совпала.");
        }
        if (FileVersionInfo.GetVersionInfo(path).FileVersion != package.Version.ToString())
            throw new IOException("Версия файла отличается от опубликованной.");
    }

    public static async Task<PreparedUpdate> DownloadAsync(UpdatePackage package)
    {
        var bytes = await FetchAsync(new Uri(package.Asset.browser_download_url)).ConfigureAwait(false);
        var stage = Path.Combine(Path.GetDirectoryName(Executable), ".newlook-" + Guid.NewGuid().ToString("N") + ".download");
        try
        {
            using (var output = new FileStream(stage, FileMode.CreateNew, FileAccess.Write))
            {
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
            VerifyFile(stage, package);
            return new PreparedUpdate { path = stage, package = package };
        }
        catch { DeleteIfPossible(stage); throw; }
    }

    public static void Discard(PreparedUpdate prepared)
    {
        if (prepared != null) DeleteIfPossible(prepared.path);
    }

    public static Task InstallAsync(PreparedUpdate prepared)
    {
        return Task.Run(() => Install(prepared, Executable, StartUpdatedProcess, TimeSpan.FromSeconds(20)));
    }

    internal static void Install(PreparedUpdate prepared, string executable,
        Func<string, Guid, Process> start, TimeSpan timeout)
    {
        var transaction = Guid.NewGuid();
        var backup = BackupPath(executable, transaction);
        var rejected = backup + ".rejected";
        string lockName;
        using (var sha = SHA256.Create())
            lockName = @"Local\NewLook.Update." + Convert.ToBase64String(
                sha.ComputeHash(Encoding.UTF8.GetBytes(executable.ToUpperInvariant()))).Replace('/', '_');
        using (var mutex = new Mutex(false, lockName))
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new IOException("Другое окно NewLook уже устанавливает обновление.");
            try
            {
                VerifyFile(prepared.path, prepared.package);
                var current = Version.Parse(FileVersionInfo.GetVersionInfo(executable).FileVersion);
                if (current >= prepared.package.Version) throw new IOException("Эта версия уже установлена.");
                using (var ready = new EventWaitHandle(false, EventResetMode.ManualReset, EventName(transaction)))
                {
                    File.Replace(prepared.path, executable, backup);
                    Process child = null;
                    try
                    {
                        child = start(executable, transaction);
                        var watch = Stopwatch.StartNew();
                        while (!ready.WaitOne(100))
                        {
                            if (child.HasExited || watch.Elapsed > timeout)
                                throw new IOException("Новая версия не открылась. Предыдущая версия восстановлена.");
                        }
                    }
                    catch
                    {
                        try
                        {
                            if (child != null && !child.HasExited)
                            {
                                child.Kill();
                                child.WaitForExit(3000);
                            }
                            File.Replace(backup, executable, rejected);
                            DeleteIfPossible(rejected);
                        }
                        catch (Exception rollback)
                        {
                            throw new IOException("Не удалось восстановить EXE автоматически. Резервная копия: " + backup, rollback);
                        }
                        throw;
                    }
                    finally { if (child != null) child.Dispose(); }
                }
            }
            finally { mutex.ReleaseMutex(); }
        }
    }

    private static Process StartUpdatedProcess(string executable, Guid transaction)
    {
        return Process.Start(new ProcessStartInfo(executable, "--update-ready " + transaction.ToString("N"))
        {
            WorkingDirectory = Path.GetDirectoryName(executable),
            UseShellExecute = false
        });
    }

    internal static Action ReadyCallback(Guid transaction)
    {
        return () =>
        {
            using (var ready = EventWaitHandle.OpenExisting(EventName(transaction))) ready.Set();
            Task.Run(async () =>
            {
                var backup = BackupPath(Executable, transaction);
                for (int attempt = 0; attempt < 60 && !DeleteIfPossible(backup); attempt++)
                    await Task.Delay(1000).ConfigureAwait(false);
            });
        };
    }

    private static string EventName(Guid id) { return @"Local\NewLook.UpdateReady." + id.ToString("N"); }
    private static string BackupPath(string exe, Guid id)
    {
        return Path.Combine(Path.GetDirectoryName(exe), ".newlook-" + id.ToString("N") + ".old");
    }

    private static bool DeleteIfPossible(string path)
    {
        try { File.Delete(path); return true; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
