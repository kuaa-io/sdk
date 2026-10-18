using System;
using System.IO;

namespace KuaaIo.Sdk;

/// <summary>One file of a multipart body.</summary>
/// <param name="Filename">The name the part carries, such as frente.jpg.</param>
/// <param name="Data">The file's bytes.</param>
/// <param name="ContentType">The file's media type: image/jpeg or image/png.</param>
public sealed record FilePart(string Filename, byte[] Data, string ContentType = "application/octet-stream")
{
    /// <summary>A file read from disk.</summary>
    /// <param name="path">The file.</param>
    /// <param name="contentType">The file's media type.</param>
    /// <returns>The file.</returns>
    public static FilePart FromPath(string path, string contentType = "application/octet-stream")
    {
        ArgumentNullException.ThrowIfNull(path);
        return new FilePart(Path.GetFileName(path), File.ReadAllBytes(path), contentType);
    }
}
