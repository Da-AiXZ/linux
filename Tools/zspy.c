/*
 * zspy -- a transparent libz that reports what inflate() really consumes.
 *
 * The index data on the device is byte-identical to the CDN (verified by
 * sha256), the reads are sequential and complete, and yet inflate() returns
 * Z_DATA_ERROR (-3), which apk turns into "IO ERROR".  Either the bytes zlib
 * consumes are not the bytes on disk, or inflate_state is damaged while the
 * stream is being decoded.  This shim answers that with one device run.
 *
 * zlib is compiled with -DZ_PREFIX, so its entry points become z_inflate,
 * z_inflateInit2_ and so on.  This file re-exports the normal names and, in
 * inflate(), keeps a CRC32 over exactly the input bytes zlib consumed as well
 * as the offset (total_in) at which it gave up.  Comparing that CRC with the
 * same prefix of the file on the host separates the two cases:
 *
 *   CRC matches  -> the input was perfect, inflate_state was damaged
 *   CRC differs  -> the input buffer was damaged, and total_in locates it
 *
 * Allocation is untouched (zlib's default zcalloc ends up in musl's mallocng),
 * so the workload behaves exactly like the failing builds.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;

/* zlib's z_stream, laid out for LP64 exactly as zlib.h declares it. */
typedef struct {
    const Bytef *next_in;
    uInt avail_in;
    uLong total_in;
    Bytef *next_out;
    uInt avail_out;
    uLong total_out;
    const char *msg;
    void *state;
    void *zalloc;
    void *zfree;
    void *opaque;
    int data_type;
    uLong adler;
    uLong reserved;
} zspy_stream;

extern int z_inflate(zspy_stream *strm, int flush);
extern int z_inflateInit_(zspy_stream *strm, const char *version,
                          int stream_size);
extern int z_inflateInit2_(zspy_stream *strm, int windowBits,
                           const char *version, int stream_size);
extern int z_inflateEnd(zspy_stream *strm);
extern int z_inflateReset(zspy_stream *strm);
extern int z_inflateReset2(zspy_stream *strm, int windowBits);
extern uLong z_crc32(uLong crc, const Bytef *buf, uInt len);
extern uLong z_adler32(uLong adler, const Bytef *buf, uInt len);
extern const char *z_zlibVersion(void);
extern unsigned long z_zlibCompileFlags(void);
extern int z_deflate(zspy_stream *strm, int flush);
extern int z_deflateInit_(zspy_stream *strm, int level, const char *version,
                          int stream_size);
extern int z_deflateInit2_(zspy_stream *strm, int level, int method,
                           int windowBits, int memLevel, int strategy,
                           const char *version, int stream_size);
extern int z_deflateEnd(zspy_stream *strm);
extern int z_deflateReset(zspy_stream *strm);
extern int z_deflateParams(zspy_stream *strm, int level, int strategy);
extern unsigned long z_deflateBound(zspy_stream *strm, unsigned long sourceLen);
extern int z_compress(Bytef *dest, unsigned long *destLen,
                      const Bytef *source, unsigned long sourceLen);
extern int z_compress2(Bytef *dest, unsigned long *destLen,
                       const Bytef *source, unsigned long sourceLen, int level);
extern unsigned long z_compressBound(unsigned long sourceLen);
extern int z_uncompress(Bytef *dest, unsigned long *destLen,
                        const Bytef *source, unsigned long sourceLen);
extern int z_uncompress2(Bytef *dest, unsigned long *destLen,
                         const Bytef *source, unsigned long *sourceLen);
extern const char *z_zError(int error);
extern unsigned long z_crc32_z(unsigned long crc, const Bytef *buf,
                               size_t len);
extern unsigned long z_adler32_z(unsigned long adler, const Bytef *buf,
                                 size_t len);
extern void *z_get_crc_table(void);
extern int z_inflateSync(zspy_stream *strm);
extern int z_inflateCopy(zspy_stream *dest, zspy_stream *source);

static char zspyBuffer[256];
static unsigned int zspyCalls;
static unsigned int zspyStreams;
static uLong zspyConsumed;
static uLong zspyInputCrc = 1; /* zlib starts crc32 at 0, but 0 is ambiguous */
static uLong zspyLastOffset;
static unsigned int zspyChunks;
static uLong zspyOutCrc;
static const Bytef *zspyChunkPtr;
static uLong zspyChunkBlocks[32];
static uInt zspyChunkBlockCount; /* gzip trailer uses crc32 starting at 0 */
static uInt zspyPrevLeft;
static Bytef *zspyOutStart;
static const Bytef *zspyPrevIn;

static void zspyWrite(const char *text, size_t length)
{
    ssize_t ignored = write(STDERR_FILENO, text, length);
    (void)ignored;
}

static void zspyLog(const char *format, ...)
{
    va_list arguments;
    int length;

    va_start(arguments, format);
    length = vsnprintf(zspyBuffer, sizeof(zspyBuffer), format, arguments);
    va_end(arguments);
    if (length <= 0) {
        return;
    }
    if ((size_t)length > sizeof(zspyBuffer) - 1) {
        length = (int)sizeof(zspyBuffer) - 1;
    }
    zspyWrite(zspyBuffer, (size_t)length);
}

static void zspyReset(void)
{
    zspyCalls = 0;
    zspyChunks = 0;
    zspyOutCrc = 0;
    zspyPrevLeft = 0;
    zspyOutStart = NULL;
    zspyPrevIn = NULL;
    zspyConsumed = 0;
    zspyInputCrc = 1;
    zspyLastOffset = 0;
    zspyChunkPtr = NULL;
    zspyChunkBlockCount = 0;
}

static void zspyState(const void *state);

/*
 * Called for every completed inflate(), including the ones that only fill the
 * output buffer.  A tick every 128 calls keeps the log readable while still
 * showing forward progress; failures and stream ends are always printed.
 */
static void zspyReport(zspy_stream *stream, int result, uInt before)
{
    uInt consumed = before - stream->avail_in;

    zspyCalls++;
    if (stream->next_out != NULL && zspyOutStart != NULL &&
        stream->next_out > zspyOutStart) {
        uLong produced = (uLong)(stream->next_out - zspyOutStart);
        zspyOutCrc = z_crc32(zspyOutCrc, zspyOutStart, (uInt)produced);
    }
    if (consumed != 0) {
        zspyInputCrc = z_crc32(zspyInputCrc,
                               stream->next_in - consumed,
                               consumed);
        zspyConsumed += consumed;
    }
    zspyLastOffset = stream->total_in;
    zspyPrevLeft = stream->avail_in;
    zspyPrevIn = stream->next_in;

    if (zspyChunkPtr != NULL && zspyChunkBlockCount != 0) {
        uInt index;
        for (index = 0; index < zspyChunkBlockCount; index++) {
            size_t at = (size_t)index * 4096;
            uLong now = z_crc32(1, zspyChunkPtr + at, 4096);
            if (now != zspyChunkBlocks[index]) {
                zspyLog("[zm] block changed at +%lu of 0x%lx old=%08lx new=%08lx\n",
                        (unsigned long)at,
                        (unsigned long)(uintptr_t)zspyChunkPtr,
                        (unsigned long)zspyChunkBlocks[index],
                        (unsigned long)now);
                zspyChunkBlocks[index] = now;
            }
        }
    }

    if (result < 0 || result == 2) {
        zspyLog("[zspy] fail ret=%d total_in=%lu total_out=%lu"
                " avail_in=%u avail_out=%u chunk=%u crc=%08lx calls=%u"
                " msg=%s\n",
                result,
                (unsigned long)stream->total_in,
                (unsigned long)stream->total_out,
                (unsigned int)stream->avail_in,
                (unsigned int)stream->avail_out,
                (unsigned int)consumed,
                (unsigned long)zspyInputCrc,
                zspyCalls,
                stream->msg != NULL ? stream->msg : "-");
        {
            uLong trailer = 0;
            if (stream->avail_in == 4 && stream->next_in != NULL) {
                const Bytef *at = stream->next_in - 4;
                trailer = ((uLong)at[0] << 24) | ((uLong)at[1] << 16) |
                          ((uLong)at[2] << 8) | (uLong)at[3];
            }
            zspyLog("[zout] outcrc=%08lx trailer=%08lx total_out=%lu\n",
                    (unsigned long)zspyOutCrc,
                    (unsigned long)trailer,
                    (unsigned long)stream->total_out);
        }
        /*
         * 0.40.18: the message is the cheapest possible discriminator.
         * "incorrect data check" means the bytes inflated were wrong while
         * the state was fine; "invalid distance" / "invalid code" means the
         * state or the code table was damaged.  Print the state fields too.
         */
        zspyState(stream->state);
        return;
    }
    if (result == 1) { /* Z_STREAM_END */
        zspyLog("[zout] outcrc=%08lx total_out=%lu\n",
                (unsigned long)zspyOutCrc,
                (unsigned long)stream->total_out);
        zspyLog("[zspy] end total_in=%lu total_out=%lu crc=%08lx calls=%u\n",
                (unsigned long)stream->total_in,
                (unsigned long)stream->total_out,
                (unsigned long)zspyInputCrc,
                zspyCalls);
        return;
    }
    if ((zspyCalls & 127u) == 0) {
        zspyLog("[zspy] tick calls=%u total_in=%lu total_out=%lu\n",
                zspyCalls,
                (unsigned long)stream->total_in,
                (unsigned long)stream->total_out);
    }
}

int inflateInit_(zspy_stream *stream, const char *version, int streamSize)
{
    zspyReset();
    zspyStreams++;
    zspyLog("[zspy] init streams=%u state=%p\n", zspyStreams, stream->state);
    return z_inflateInit_(stream, version, streamSize);
}

int inflateInit2_(zspy_stream *stream, int windowBits, const char *version,
                  int streamSize)
{
    int result;

    zspyReset();
    zspyStreams++;
    result = z_inflateInit2_(stream, windowBits, version, streamSize);
    zspyLog("[zspy] init2 wbits=%d ret=%d streams=%u state=%p\n",
            windowBits, result, zspyStreams, stream->state);
    return result;
}

static char zspyHex[24];

static unsigned zspyU32(const void *base, unsigned offset)
{
    unsigned value;
    memcpy(&value, (const unsigned char *)base + offset, sizeof(value));
    return value;
}

static void *zspyPtr(const void *base, unsigned offset)
{
    void *value;
    memcpy(&value, (const unsigned char *)base + offset, sizeof(value));
    return value;
}

/*
 * The crash is inside inflate_fast copying from a NULL window, which zlib only
 * does when its bookkeeping is already wrong (a window copy is taken while
 * whave claims history but window is NULL).  Print the fields that decide that
 * branch at entry, so the next run says whether the state arrived broken or
 * was broken during the call.  Offsets are zlib 1.3.1's inflate_state.
 */
static void zspyState(const void *state)
{
    if (state == NULL) {
        zspyLog("[zspy] state is NULL\n");
        return;
    }
    zspyLog("[zspy] state mode=%u last=%d wrap=%d wbits=%u wsize=%u"
            " whave=%u wnext=%u window=%p length=%u offset=%u\n",
            zspyU32(state, 8),
            (int)zspyU32(state, 12),
            (int)zspyU32(state, 16),
            zspyU32(state, 56),
            zspyU32(state, 60),
            zspyU32(state, 64),
            zspyU32(state, 68),
            zspyPtr(state, 72),
            zspyU32(state, 92),
            zspyU32(state, 96));
}

static const char *zspyHead(const Bytef *bytes, uInt available)
{
    static const char digits[] = "0123456789abcdef";
    uInt limit = available < 8 ? available : 8;
    uInt index;

    for (index = 0; index < limit; index++) {
        zspyHex[index * 2] = digits[bytes[index] >> 4];
        zspyHex[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    zspyHex[index * 2] = 0;
    return zspyHex;
}

int inflate(zspy_stream *stream, int flush)
{
    uInt before = stream->avail_in;
    Bytef *beforeOut = stream->next_out;
    uInt beforeAvail = stream->avail_out;
    int result;

    /*
     * 0.40.24: apk refills gzi's input buffer one read() at a time and points
     * next_in at the *start* of that buffer again, so next_in - total_in is
     * only the file start while the first chunk is being decoded -- 0.40.22
     * assumed otherwise and walked below the buffer into unmapped memory.
     * Hash each fresh chunk where it actually is, before zlib consumes it, and
     * print its own offset: comparing these with the file on the host names
     * the first window that is not what apk read from disk.
     */
    int freshChunk = (zspyPrevLeft == 0 ||
                       stream->next_in != zspyPrevIn);
    if (freshChunk && stream->avail_in >= 512 && stream->next_in != NULL) {
        uLong chunkCrc = z_crc32(1, stream->next_in, stream->avail_in);
        /*
         * 0.40.28: keep a fingerprint of every 4KB of this chunk and re-check
         * it after inflate() returns.  A block that changes while zlib is
         * running was written by something else -- zlib never writes to its
         * input -- and the offset says whether the damage landed in the data
         * (decoded bytes wrong) or in the gzip trailer (data right, check
         * fails).  That is exactly the split the six-run batch showed.
         */
        zspyChunkPtr = stream->next_in;
        zspyChunkBlockCount = 0;
        {
            uInt at;
            for (at = 0; at + 4096 <= stream->avail_in &&
                         zspyChunkBlockCount < 32; at += 4096) {
                zspyChunkBlocks[zspyChunkBlockCount++] =
                    z_crc32(1, stream->next_in + at, 4096);
            }
        }
        zspyLog("[zc] chunk=%u off=%lu len=%u crc=%08lx"
                " head=%02x%02x%02x%02x%02x%02x%02x%02x\n",
                zspyChunks++,
                (unsigned long)zspyConsumed,
                (unsigned)stream->avail_in,
                (unsigned long)chunkCrc,
                stream->next_in[0], stream->next_in[1],
                stream->next_in[2], stream->next_in[3],
                stream->next_in[4], stream->next_in[5],
                stream->next_in[6], stream->next_in[7]);
        /*
         * 0.40.26: the community index fails in exactly one 128KB chunk
         * (chunk 9) while its neighbours match the file byte for byte, so the
         * remaining question is where inside that chunk the bytes diverge.
         * Print 4KB sub-block CRCs around that chunk: a run that starts at an
         * offset and continues to the end of the chunk means a partial
         * overwrite, a single bad block means one page was written.
         */
        if (zspyChunks - 1 >= 8 && zspyChunks - 1 <= 10 &&
            stream->avail_in >= 4096) {
            uInt offset;
            for (offset = 0; offset + 4096 <= stream->avail_in; offset += 4096) {
                zspyLog("[zc4] c=%u o=%lu crc=%08lx\n",
                        zspyChunks - 1,
                        (unsigned long)(zspyConsumed + offset),
                        (unsigned long)z_crc32(1,
                                               stream->next_in + offset,
                                               4096));
            }
        }
    }

    /*
     * The first few calls of every stream get their arguments printed.  This
     * is what separates "the caller's z_stream was already broken" from "zlib
     * broke it while decoding": the previous build crashed inside inflate with
     * far=0x2d, a value far too small to be a real pointer, on the second
     * stream of the run.
     */
    if (zspyCalls < 4) {
        zspyLog("[zspy] pre #%u strm=%p state=%p in=%p avail=%u"
                " out=%p avail_out=%u head=%s\n",
                zspyCalls,
                (void *)stream,
                stream->state,
                (const void *)stream->next_in,
                (unsigned int)stream->avail_in,
                (void *)stream->next_out,
                (unsigned int)stream->avail_out,
                stream->next_in != NULL ? zspyHead(stream->next_in,
                                                   stream->avail_in)
                                        : "-");
        if (zspyCalls == 0) {
            zspyState(stream->state);
        }
    }
    zspyOutStart = stream->next_out;
    result = z_inflate(stream, flush);
    /*
     * 0.40.21: the invariant zlib relies on is that the bytes it advanced
     * next_out by are exactly the bytes it took out of avail_out.  Every
     * downstream bug tonight (wrong byte count for apk, incorrect data check,
     * database file format error) is consistent with this invariant breaking
     * somewhere inside one call.  Check it on every return, before the
     * counters are touched, and print the actual pointers.
     */
    {
        static int invCount = 0;
        long advanced = (long)(stream->next_out - beforeOut);
        unsigned consumed = beforeAvail - stream->avail_out;
        if (advanced != (long)consumed && invCount < 12) {
            invCount++;
            zspyLog("[zspy] INVARIANT #%d ret=%d advanced=%ld consumed=%u"
                    " before_out=%p after_out=%p before_avail=%u"
                    " after_avail=%u state=%p\n",
                    invCount,
                    result,
                    advanced,
                    consumed,
                    (void *)beforeOut,
                    (void *)stream->next_out,
                    beforeAvail,
                    stream->avail_out,
                    stream->state);
        }
    }
    zspyReport(stream, result, before);
    return result;
}

int inflateEnd(zspy_stream *stream)
{
    int result = z_inflateEnd(stream);
    zspyLog("[zspy] end-of-stream state=%p ret=%d consumed=%lu crc=%08lx\n",
            stream->state, result, (unsigned long)zspyConsumed,
            (unsigned long)zspyInputCrc);
    return result;
}

int inflateReset(zspy_stream *stream)
{
    zspyReset();
    return z_inflateReset(stream);
}

int inflateReset2(zspy_stream *stream, int windowBits)
{
    zspyReset();
    return z_inflateReset2(stream, windowBits);
}

uLong crc32(uLong crc, const Bytef *buffer, uInt length)
{
    return z_crc32(crc, buffer, length);
}

uLong adler32(uLong adler, const Bytef *buffer, uInt length)
{
    return z_adler32(adler, buffer, length);
}

const char *zlibVersion(void)
{
    return z_zlibVersion();
}

unsigned long zlibCompileFlags(void)
{
    return z_zlibCompileFlags();
}

/*
 * libapk links against the whole zlib surface, not just the inflate half:
 * the first instrumented build died in the loader with
 * "Error relocating /lib/libapk.so.2.14.0: deflate: symbol not found".
 * Everything below forwards unchanged, so nothing here changes behaviour.
 */
int deflate(zspy_stream *stream, int flush)
{
    return z_deflate(stream, flush);
}

int deflateInit_(zspy_stream *stream, int level, const char *version,
                 int streamSize)
{
    return z_deflateInit_(stream, level, version, streamSize);
}

int deflateInit2_(zspy_stream *stream, int level, int method, int windowBits,
                  int memLevel, int strategy, const char *version,
                  int streamSize)
{
    return z_deflateInit2_(stream, level, method, windowBits, memLevel,
                           strategy, version, streamSize);
}

int deflateEnd(zspy_stream *stream)
{
    return z_deflateEnd(stream);
}

int deflateReset(zspy_stream *stream)
{
    return z_deflateReset(stream);
}

int deflateParams(zspy_stream *stream, int level, int strategy)
{
    return z_deflateParams(stream, level, strategy);
}

unsigned long deflateBound(zspy_stream *stream, unsigned long sourceLen)
{
    return z_deflateBound(stream, sourceLen);
}

int compress(Bytef *dest, unsigned long *destLen, const Bytef *source,
             unsigned long sourceLen)
{
    return z_compress(dest, destLen, source, sourceLen);
}

int compress2(Bytef *dest, unsigned long *destLen, const Bytef *source,
              unsigned long sourceLen, int level)
{
    return z_compress2(dest, destLen, source, sourceLen, level);
}

unsigned long compressBound(unsigned long sourceLen)
{
    return z_compressBound(sourceLen);
}

int uncompress(Bytef *dest, unsigned long *destLen, const Bytef *source,
               unsigned long sourceLen)
{
    return z_uncompress(dest, destLen, source, sourceLen);
}

int uncompress2(Bytef *dest, unsigned long *destLen, const Bytef *source,
                unsigned long *sourceLen)
{
    return z_uncompress2(dest, destLen, source, sourceLen);
}

const char *zError(int error)
{
    return z_zError(error);
}

unsigned long crc32_z(unsigned long crc, const Bytef *buffer, size_t length)
{
    return z_crc32_z(crc, buffer, length);
}

unsigned long adler32_z(unsigned long adler, const Bytef *buffer, size_t length)
{
    return z_adler32_z(adler, buffer, length);
}

void *get_crc_table(void)
{
    return z_get_crc_table();
}

int inflateSync(zspy_stream *stream)
{
    return z_inflateSync(stream);
}

int inflateCopy(zspy_stream *dest, zspy_stream *source)
{
    return z_inflateCopy(dest, source);
}
