namespace PaolaScreenStudio.Core;

/// <summary>Source time ranges kept in the final video (trim minus cuts) and the mapping between both timelines.</summary>
public sealed class TimeMap
{
    public IReadOnlyList<(double Start, double End)> Kept { get; }
    public double OutputDuration { get; }

    public TimeMap(double duration, EditSettings settings)
    {
        var start = Math.Clamp(settings.TrimStart, 0, duration);
        var end = Math.Clamp(settings.TrimEnd ?? duration, start, duration);
        var ranges = new List<(double, double)>();
        var cursor = start;
        foreach (var cut in settings.Cuts.OrderBy(c => c.Start))
        {
            var cutStart = Math.Max(cut.Start, cursor);
            var cutEnd = Math.Min(cut.End, end);
            if (cutEnd <= cutStart)
            {
                continue;
            }
            if (cutStart - cursor > 0.02)
            {
                ranges.Add((cursor, cutStart));
            }
            cursor = cutEnd;
        }
        if (end - cursor > 0.02)
        {
            ranges.Add((cursor, end));
        }
        Kept = ranges;
        OutputDuration = ranges.Sum(r => r.Item2 - r.Item1);
    }

    public bool IsKept(double source) => Kept.Any(r => source >= r.Start && source < r.End);

    /// <summary>First kept source time at or after <paramref name="source"/>, or null at the end.</summary>
    public double? NextKept(double source)
    {
        foreach (var range in Kept)
        {
            if (source < range.End)
            {
                return Math.Max(source, range.Start);
            }
        }
        return null;
    }

    public double ToOutput(double source)
    {
        var output = 0.0;
        foreach (var range in Kept)
        {
            if (source <= range.Start)
            {
                break;
            }
            output += Math.Min(source, range.End) - range.Start;
        }
        return output;
    }

    public double ToSource(double output)
    {
        foreach (var range in Kept)
        {
            var length = range.End - range.Start;
            if (output <= length)
            {
                return range.Start + output;
            }
            output -= length;
        }
        return Kept.Count > 0 ? Kept[^1].End : 0;
    }
}
