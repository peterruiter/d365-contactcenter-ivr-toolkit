using System;
using System.Collections.Concurrent;

namespace PowerPete.IvrToolkit.Common
{
    /// <summary>
    /// Process-level cache. Sandboxed plugins are recycled often, so treat this as a
    /// best-effort hot cache, not a guarantee. Hours and queue metadata benefit most.
    /// Never cache live metrics for longer than pwrp_MetricsCacheSeconds.
    /// </summary>
    public static class CacheStore
    {
        private static readonly ConcurrentDictionary<string, Entry> Store = new ConcurrentDictionary<string, Entry>();

        private class Entry
        {
            public object Value;
            public DateTime ExpiresUtc;
        }

        public static T GetOrAdd<T>(string key, int ttlSeconds, Func<T> factory)
        {
            if (ttlSeconds <= 0)
            {
                return factory();
            }

            if (Store.TryGetValue(key, out var existing) && existing.ExpiresUtc > DateTime.UtcNow)
            {
                return (T)existing.Value;
            }

            var value = factory();
            Store[key] = new Entry { Value = value, ExpiresUtc = DateTime.UtcNow.AddSeconds(ttlSeconds) };
            return value;
        }

        public static void Invalidate(string prefix)
        {
            foreach (var key in Store.Keys)
            {
                if (key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                {
                    Store.TryRemove(key, out _);
                }
            }
        }
    }
}
