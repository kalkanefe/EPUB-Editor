#include <zlib.h>

// ZIP members contain raw DEFLATE streams, without a zlib header.
static inline int epub_inflate(const Bytef *source, uInt length, Bytef *dest,
                               uInt capacity, uInt expected) {
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    stream.next_in = (Bytef *)source;
    stream.avail_in = length;
    stream.next_out = dest;
    stream.avail_out = capacity;
    int status = inflate(&stream, Z_FINISH);
    int complete = status == Z_STREAM_END && stream.total_out == expected && stream.avail_in == 0;
    inflateEnd(&stream);
    return complete;
}

static inline uInt epub_deflate(const Bytef *source, uInt length, Bytef *dest, uInt capacity) {
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS,
                     8, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
    stream.next_in = (Bytef *)source;
    stream.avail_in = length;
    stream.next_out = dest;
    stream.avail_out = capacity;
    int status = deflate(&stream, Z_FINISH);
    uInt count = status == Z_STREAM_END ? (uInt)stream.total_out : 0;
    deflateEnd(&stream);
    return count;
}
