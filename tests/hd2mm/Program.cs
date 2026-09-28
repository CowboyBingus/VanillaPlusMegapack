using System.Collections;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Text.Json;

var managerDir = Path.GetFullPath(args[0]);
var release = Path.GetFullPath(args[1]);
var outputDir = Path.GetFullPath(args[2]);
Directory.CreateDirectory(outputDir);
Directory.SetCurrentDirectory(outputDir);
AssemblyLoadContext.Default.Resolving += (_, name) => {
    var file = Path.Combine(managerDir, name.Name + ".dll");
    return File.Exists(file) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(file) : null;
};
var assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(managerDir, "Helldivers2ModManager.dll"));
Type TypeOf(string name) => assembly.GetType("Helldivers2ModManager." + name, true)!;
object Get(object obj, string prop) => obj.GetType().GetProperty(prop)!.GetValue(obj)!;
void Set(object obj, string prop, object value) => obj.GetType().GetProperty(prop)!.SetValue(obj, value);
object? Call(object obj, string method, params object?[] values) {
    try { return obj.GetType().GetMethod(method)!.Invoke(obj, values); }
    catch (TargetInvocationException e) when(e.InnerException is not null) { throw e.InnerException; }
}
async Task<object?> Run(object obj, string method, params object?[] values) {
    var task = (Task)Call(obj, method, values)!;
    await task;
    return task.GetType().GetProperty("Result")?.GetValue(task);
}
void Require(bool value, string message) { if (!value) throw new Exception(message); }
object Create(string name) {
    var type = TypeOf(name);
    var loggerType = Assembly.Load("Microsoft.Extensions.Logging.Abstractions").GetType("Microsoft.Extensions.Logging.Abstractions.NullLogger`1")!.MakeGenericType(type);
    var logger = loggerType.GetProperty("Instance")?.GetValue(null) ?? loggerType.GetField("Instance")!.GetValue(null);
    return Activator.CreateInstance(type, logger)!;
}
(object Service, string Root, string Data) Fixture(string label) {
    var root = Path.Combine(outputDir, label + "-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    var game = Path.Combine(root, "game");
    var data = Path.Combine(game, "data");
    Directory.CreateDirectory(data);
    Directory.CreateDirectory(Path.Combine(game, "bin"));
    var settings = Create("Services.SettingsService");
    Call(settings, "InitDefault", false);
    Set(settings, "GameDirectory", game);
    Set(settings, "StorageDirectory", Path.Combine(root, "library"));
    Set(settings, "TempDirectory", Path.Combine(root, "temp"));
    ((IList)Get(settings, "SkipList")).Clear();
    var service = Create("Services.ModService");
    Require(((Array)Call(service, "Init", settings)!).Length == 0, "Fixture initialization failed");
    return (service, root, data);
}
object[] Mods(object service) => ((IEnumerable)Get(service, "Mods")).Cast<object>().ToArray();
Guid Id(object mod) => (Guid)Get(Get(mod, "Manifest"), "Guid");
using var zip = ZipFile.OpenRead(release);
byte[] Payload(string name) {
    using var input = zip.GetEntry(name)!.Open();
    using var output = new MemoryStream(); input.CopyTo(output); return output.ToArray();
}
using var json = JsonDocument.Parse(Payload("manifest.json"));
var expected = json.RootElement.GetProperty("Options").EnumerateArray().ToArray();
var optionCount = expected.Length;
var fullMask = (1 << optionCount) - 1;
Require(optionCount >= 2, "Expected independent options");
// An option's archives in deployment order: its patch_N files by N (Mod Bindings Menu has two).
string[] ArchivesOf(string folder) => zip.Entries.Select(e=>e.FullName)
    .Where(n=>n.StartsWith(folder+"/9ba626afa44a3aa3.patch_") && char.IsDigit(n[^1]))
    .OrderBy(n=>int.Parse(n[(n.LastIndexOf('_')+1)..])).ToArray();
void Verify(string data, int mask) {
    var archives = expected.Where((_,i)=>(mask & (1<<i))!=0).SelectMany(o=>ArchivesOf(o.GetProperty("Include")[0].GetString()!)).ToArray();
    Require(Directory.GetFiles(data).Length == archives.Length * 3, "Unexpected deployment file count");
    for(var i=0;i<archives.Length;i++) foreach(var suffix in new[]{"", ".stream", ".gpu_resources"}) {
        var actual = File.ReadAllBytes(Path.Combine(data, "9ba626afa44a3aa3.patch_" + i + suffix));
        Require(actual.SequenceEqual(Payload(archives[i]+suffix)), "Wrong deployed payload");
    }
}
var fixture = Fixture("options");
var warnings = (Array)(await Run(fixture.Service, "TryAddModFromArchiveAsync", new FileInfo(release)))!;
Require(warnings.Length==0, "Import returned warnings");
var mods = Mods(fixture.Service);
Require(mods.Length==1, "Expected one manager entry");
var mod = mods[0];
var manifest = Get(mod, "Manifest");
Require(Get(manifest, "Version").ToString()=="V1", "Expected V1 manifest");
var options = ((IEnumerable)Get(manifest, "Options")).Cast<object>().ToArray();
Require(options.Length==optionCount, "Expected every parsed option");
Require(((bool[])Get(mod,"EnabledOptions")).All(x=>x), "Default selections missing");
for(var i=0;i<optionCount;i++) {
    Require((string)Get(options[i],"Name")==expected[i].GetProperty("Name").GetString(), "Wrong option label");
    Require((string)Get(options[i],"Description")==expected[i].GetProperty("Description").GetString(), "Wrong option description");
    Require(File.Exists(Path.Combine(((DirectoryInfo)Get(mod,"Directory")).FullName,(string)Get(options[i],"Image"))), "Missing option image");
}
Set(mod, "Enabled", true);
foreach(var mask in new[]{fullMask,0}.Concat(Enumerable.Range(0,fullMask+1))) {
    await Run(fixture.Service,"PurgeAsync"); Verify(fixture.Data,0);
    var enabled = (bool[])Get(mod,"EnabledOptions");
    for(var i=0;i<optionCount;i++) enabled[i]=(mask & (1<<i))!=0;
    await Run(fixture.Service,"DeployAsync",new object?[]{new[]{Id(mod)}});
    Verify(fixture.Data,mask);
}
await Run(fixture.Service,"PurgeAsync"); Verify(fixture.Data,0);
Set(mod,"Enabled",false);
await Run(fixture.Service,"DeployAsync",new object?[]{Array.Empty<Guid>()}); Verify(fixture.Data,0);
Set(mod,"Enabled",true);
Array.Fill((bool[])Get(mod,"EnabledOptions"),true);
await Run(fixture.Service,"DeployAsync",new object?[]{new[]{Id(mod)}}); Verify(fixture.Data,fullMask);
await Run(fixture.Service,"PurgeAsync");
await Run(fixture.Service,"RemoveAsync",mod);
Require(Mods(fixture.Service).Length==0,"Removal left entry"); Verify(fixture.Data,0);
var report=new {manager_version=assembly.GetName().Version!.ToString(),options=optionCount,all_subsets=true,subsets=fullMask+1,payloads_match=true,purge_reenable_remove=true,game_launched=false,live_profile_changed=false,release_sha256=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(release))),manager_assembly_sha256=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(assembly.Location)))};
File.WriteAllText(Path.Combine(outputDir,"hd2mm-compatibility.json"),JsonSerializer.Serialize(report,new JsonSerializerOptions{WriteIndented=true}));
Console.WriteLine(JsonSerializer.Serialize(report));
