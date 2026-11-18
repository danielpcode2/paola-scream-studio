using System.Text.Json;

namespace PaolaScreenStudio.Core;

public static class ProjectStore
{
    public const string FileName = "project.json";

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static Project Load(string folder)
    {
        var path = Path.Combine(folder, FileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(Strings.T("error.not_a_project"), path);
        }
        return JsonSerializer.Deserialize<Project>(File.ReadAllText(path), Json)
            ?? throw new InvalidDataException(Strings.T("error.not_a_project"));
    }

    public static void Save(string folder, Project project)
    {
        var path = Path.Combine(folder, FileName);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(project, Json));
        File.Move(temp, path, overwrite: true);
    }

    public static string CreateFolder(string projectsDirectory, DateTime now)
    {
        Directory.CreateDirectory(projectsDirectory);
        var name = now.ToString("yyyy-MM-dd HH.mm.ss", System.Globalization.CultureInfo.InvariantCulture);
        var folder = Path.Combine(projectsDirectory, name);
        var suffix = 2;
        while (Directory.Exists(folder))
        {
            folder = Path.Combine(projectsDirectory, $"{name} ({suffix++})");
        }
        Directory.CreateDirectory(folder);
        return folder;
    }

    /// <summary>Project folders, newest first.</summary>
    public static IReadOnlyList<string> List(string projectsDirectory)
    {
        if (!Directory.Exists(projectsDirectory))
        {
            return Array.Empty<string>();
        }
        return Directory.GetDirectories(projectsDirectory)
            .Where(d => File.Exists(Path.Combine(d, FileName)))
            .OrderByDescending(Directory.GetCreationTimeUtc)
            .ToList();
    }
}
