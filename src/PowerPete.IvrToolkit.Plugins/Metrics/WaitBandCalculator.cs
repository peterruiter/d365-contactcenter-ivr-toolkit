using System;
using System.Linq;

namespace PowerPete.IvrToolkit.Metrics
{
    /// <summary>
    /// Callers hang up on raw numbers. "Fourteen people ahead of you" is a hangup trigger.
    /// Thresholds come from pwrp_WaitBandThresholds as three ascending second values.
    /// </summary>
    public static class WaitBandCalculator
    {
        public static string Band(int seconds, string thresholds)
        {
            var parts = (thresholds ?? "60,180,420")
                .Split(',')
                .Select(p => int.TryParse(p.Trim(), out var v) ? v : 0)
                .Where(v => v > 0)
                .OrderBy(v => v)
                .ToArray();

            if (parts.Length < 3)
            {
                parts = new[] { 60, 180, 420 };
            }

            if (seconds <= parts[0]) return "Short";
            if (seconds <= parts[1]) return "Moderate";
            if (seconds <= parts[2]) return "Long";
            return "VeryLong";
        }
    }
}
