<?php

declare(strict_types=1);

namespace Kuaa;

/** One file of a multipart body. */
final class File
{
    /**
     * @param string $filename the name the part carries, such as frente.jpg
     * @param string $data the file's bytes
     * @param string $contentType the file's media type: image/jpeg or image/png
     */
    public function __construct(
        public readonly string $filename,
        public readonly string $data,
        public readonly string $contentType = 'application/octet-stream',
    ) {
    }

    /** A file read from disk. */
    public static function fromPath(string $path, string $contentType = 'application/octet-stream'): self
    {
        $data = file_get_contents($path);
        if ($data === false) {
            throw new \RuntimeException("kuaa: cannot read {$path}");
        }
        return new self(basename($path), $data, $contentType);
    }
}
