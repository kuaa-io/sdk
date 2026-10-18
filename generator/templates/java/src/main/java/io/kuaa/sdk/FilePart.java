package io.kuaa.sdk;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;

/** One file of a multipart body. */
public final class FilePart {
    private final String filename;
    private final byte[] data;
    private final String contentType;

    /**
     * A file.
     *
     * @param filename the name the part carries, such as frente.jpg
     * @param data the file's bytes
     * @param contentType the file's media type: image/jpeg or image/png
     */
    public FilePart(String filename, byte[] data, String contentType) {
        this.filename = Objects.requireNonNull(filename, "filename");
        this.data = Objects.requireNonNull(data, "data").clone();
        this.contentType = contentType == null || contentType.isEmpty() ? "application/octet-stream" : contentType;
    }

    /**
     * A file read from disk.
     *
     * @param path the file
     * @param contentType the file's media type
     * @return the file
     * @throws IOException when the file cannot be read
     */
    public static FilePart fromPath(Path path, String contentType) throws IOException {
        return new FilePart(path.getFileName().toString(), Files.readAllBytes(path), contentType);
    }

    /** @return the name the part carries */
    public String getFilename() {
        return filename;
    }

    /** @return the file's bytes */
    public byte[] getData() {
        return data.clone();
    }

    /** @return the file's media type */
    public String getContentType() {
        return contentType;
    }
}
