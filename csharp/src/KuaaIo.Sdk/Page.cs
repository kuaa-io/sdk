using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

namespace KuaaIo.Sdk;

/// <summary>One page of a list, and where the next one starts.</summary>
/// <typeparam name="T">The object listed.</typeparam>
public sealed class Page<T>
{
    /// <summary>The page's items.</summary>
    public required IReadOnlyList<T> Items { get; init; }

    /// <summary>The cursor of the next page, or null on the last one.</summary>
    public string? NextCursor { get; init; }

    /// <summary>Another page follows.</summary>
    public bool HasMore { get; init; }
}

internal static class Pages
{
    /// <summary>
    /// Walks pages from <paramref name="cursor"/> (the first page when null)
    /// until the last one, fetching each page only when the previous one is
    /// used up.
    /// </summary>
    internal static async IAsyncEnumerable<T> IterateAsync<T>(
        Func<string?, CancellationToken, Task<Page<T>>> fetch,
        string? cursor,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        while (true)
        {
            var page = await fetch(cursor, cancellationToken).ConfigureAwait(false);
            foreach (var item in page.Items)
            {
                yield return item;
            }
            if (!page.HasMore || string.IsNullOrEmpty(page.NextCursor))
            {
                yield break;
            }
            cursor = page.NextCursor;
        }
    }
}
