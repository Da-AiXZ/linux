/*
 * v2/elf.c -- parse and map an aarch64 ELF64 image.
 *
 * The loader does not trust the file: every offset is bounds checked against
 * the buffer and every segment against the file length, because a malformed
 * ELF must produce a message, not a wild write.
 */
#include "v2/elf.h"

#include <stdlib.h>
#include <string.h>

#include "v2/patch.h"

#define V2_ELF_PT_LOAD    1
#define V2_ELF_PT_DYNAMIC 2
#define V2_ELF_PT_INTERP  3
#define V2_ELF_PT_TLS     7

#define V2_ELF_MAX_FILESZ (64u * 1024u * 1024u)

struct v2_ehdr {
    uint8_t ident[16];
    uint16_t type;
    uint16_t machine;
    uint32_t version;
    uint64_t entry;
    uint64_t phoff;
    uint64_t shoff;
    uint32_t flags;
    uint16_t ehsize;
    uint16_t phentsize;
    uint16_t phnum;
    uint16_t shentsize;
    uint16_t shnum;
    uint16_t shstrndx;
};

struct v2_phdr {
    uint32_t type;
    uint32_t flags;
    uint64_t offset;
    uint64_t vaddr;
    uint64_t paddr;
    uint64_t filesz;
    uint64_t memsz;
    uint64_t align;
};

static void v2_error(char *buffer, size_t size, const char *text)
{
    if (buffer != NULL && size != 0) {
        size_t length = strlen(text);
        if (length >= size) {
            length = size - 1;
        }
        memcpy(buffer, text, length);
        buffer[length] = '\0';
    }
}

static uint64_t v2_align_up(uint64_t value, uint64_t alignment)
{
    return (value + alignment - 1) & ~(alignment - 1);
}

/*
 * ELF p_flags are PF_X=1, PF_W=2, PF_R=4; the guest ABI (and this runtime) use
 * PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4.  The two happen to agree for R|X and
 * to disagree for everything else, which is the worst possible overlap -- the
 * test caught a text page being mapped read-write because of it.
 */
static uint32_t v2_elf_prot(uint32_t flags)
{
    uint32_t prot = 0;

    if ((flags & 4u) != 0) {
        prot |= V2_PROT_READ;
    }
    if ((flags & 2u) != 0) {
        prot |= V2_PROT_WRITE;
    }
    if ((flags & 1u) != 0) {
        prot |= V2_PROT_EXEC;
    }
    return prot;
}

int v2_elf_parse(const void *file, size_t length, struct v2_elf_image *image,
                 char *error, size_t error_size)
{
    const uint8_t *bytes = (const uint8_t *)file;
    const struct v2_ehdr *header;
    const struct v2_phdr *programs;

    if (file == NULL || image == NULL || length < sizeof(struct v2_ehdr)) {
        v2_error(error, error_size, "file too short for an ELF header");
        return -V2_EINVAL;
    }
    header = (const struct v2_ehdr *)file;
    if (memcmp(header->ident, "\x7f" "ELF", 4) != 0) {
        v2_error(error, error_size, "not an ELF file");
        return -V2_EINVAL;
    }
    if (header->ident[4] != 2) {
        v2_error(error, error_size, "not ELF64");
        return -V2_EINVAL;
    }
    if (header->ident[5] != 1) {
        v2_error(error, error_size, "not little endian");
        return -V2_EINVAL;
    }
    if (header->machine != V2_ELF_EM_AARCH64) {
        v2_error(error, error_size, "not aarch64");
        return -V2_EINVAL;
    }
    if (header->type != V2_ELF_ET_DYN && header->type != V2_ELF_ET_EXEC) {
        v2_error(error, error_size, "not ET_DYN or ET_EXEC");
        return -V2_EINVAL;
    }
    if (header->phentsize < sizeof(struct v2_phdr) || header->phnum == 0) {
        v2_error(error, error_size, "no program headers");
        return -V2_EINVAL;
    }
    if (header->phnum > V2_ELF_MAX_SEGMENTS * 4) {
        v2_error(error, error_size, "too many program headers");
        return -V2_EINVAL;
    }
    if (header->phoff > length ||
        (uint64_t)header->phnum * header->phentsize > length - header->phoff) {
        v2_error(error, error_size, "program headers outside the file");
        return -V2_EINVAL;
    }

    memset(image, 0, sizeof(*image));
    image->type = header->type;
    image->machine = header->machine;
    image->entry = header->entry;
    image->phoff = header->phoff;
    image->phnum = header->phnum;
    image->phentsize = header->phentsize;

    programs = (const struct v2_phdr *)(bytes + header->phoff);
    for (uint16_t index = 0; index < header->phnum; index++) {
        const struct v2_phdr *program =
            (const struct v2_phdr *)((const uint8_t *)programs +
                                     (size_t)index * header->phentsize);

        if (program->type == V2_ELF_PT_LOAD) {
            if (image->segment_count >= V2_ELF_MAX_SEGMENTS) {
                v2_error(error, error_size, "too many PT_LOAD segments");
                return -V2_EINVAL;
            }
            if (program->filesz > V2_ELF_MAX_FILESZ ||
                program->memsz < program->filesz) {
                v2_error(error, error_size, "segment size is not sane");
                return -V2_EINVAL;
            }
            if (program->offset > length ||
                program->filesz > length - program->offset) {
                v2_error(error, error_size, "segment outside the file");
                return -V2_EINVAL;
            }
            image->segments[image->segment_count].vaddr = program->vaddr;
            image->segments[image->segment_count].offset = program->offset;
            image->segments[image->segment_count].filesz = program->filesz;
            image->segments[image->segment_count].memsz = program->memsz;
            image->segments[image->segment_count].flags =
                v2_elf_prot(program->flags);
            image->segment_count++;

            if (image->segment_count == 1 || program->vaddr < image->min_vaddr) {
                image->min_vaddr = program->vaddr;
            }
            if (program->vaddr + program->memsz > image->max_vaddr) {
                image->max_vaddr = program->vaddr + program->memsz;
            }
        } else if (program->type == V2_ELF_PT_INTERP) {
            uint64_t size = program->filesz;
            if (program->offset > length || size > length - program->offset ||
                size == 0 || size >= V2_ELF_INTERP_MAX) {
                v2_error(error, error_size, "PT_INTERP is not sane");
                return -V2_EINVAL;
            }
            memcpy(image->interp, bytes + program->offset, (size_t)size);
            image->interp[size] = '\0';
            image->has_interp = 1;
        } else if (program->type == V2_ELF_PT_TLS) {
            image->has_tls = 1;
            image->tls_vaddr = program->vaddr;
            image->tls_filesz = program->filesz;
            image->tls_memsz = program->memsz;
            image->tls_align = program->align;
        }
    }

    if (image->segment_count == 0 || image->max_vaddr <= image->min_vaddr) {
        v2_error(error, error_size, "no loadable segments");
        return -V2_EINVAL;
    }
    return 0;
}

int v2_elf_load(v2_space *space, int fd, const struct v2_elf_image *image,
                uint64_t base_hint, struct v2_patcher *patcher,
                struct v2_elf_load *out, char *error, size_t error_size)
{
    uint64_t page = v2_space_page_size(space);
    uint64_t span = v2_align_up(image->max_vaddr - image->min_vaddr, page);
    long long mapped;
    uint8_t *buffer;

    if (image->min_vaddr % page != 0) {
        v2_error(error, error_size, "min_vaddr is not page aligned");
        return -V2_EINVAL;
    }
    if (base_hint != 0 && base_hint % page != 0) {
        v2_error(error, error_size, "base is not page aligned");
        return -V2_EINVAL;
    }

    mapped = v2_space_map(space,
                          base_hint != 0 ? (void *)(uintptr_t)base_hint : NULL,
                          (size_t)span, V2_PROT_READ | V2_PROT_WRITE,
                          V2_MAP_ANON |
                              (base_hint != 0 ? V2_MAP_FIXED : 0),
                          -1, 0);
    if (mapped <= 0) {
        v2_error(error, error_size, "cannot reserve the image span");
        return (int)(mapped < 0 ? mapped : -V2_ENOMEM);
    }

    out->start = (uint64_t)mapped;
    out->span = span;
    out->base = out->start - image->min_vaddr;
    out->entry = out->base + image->entry;

    buffer = (uint8_t *)malloc(V2_ELF_MAX_FILESZ);
    if (buffer == NULL) {
        v2_error(error, error_size, "out of memory");
        return -V2_ENOMEM;
    }

    for (int index = 0; index < image->segment_count; index++) {
        const struct v2_elf_segment *segment = &image->segments[index];
        uint8_t *destination =
            (uint8_t *)(uintptr_t)(out->start + segment->vaddr - image->min_vaddr);
        size_t done = 0;

        if (segment->filesz == 0) {
            continue;
        }
        {
            int stalls = 0;

            while (done < segment->filesz) {
                long got = v2_space_host(space)->read_at(
                    v2_space_host(space)->ctx, fd, buffer + done,
                    (size_t)segment->filesz - done,
                    (long long)segment->offset + (long long)done);

                if (got < 0) {
                    free(buffer);
                    v2_error(error, error_size, "short read on a segment");
                    return -V2_EIO;
                }
                if (got == 0) {
                    /* Same reasoning as in vspace.c: zero is EOF, and a
                     * spurious zero would leave the segment half copied. */
                    if (++stalls > 3) {
                        free(buffer);
                        v2_error(error, error_size, "short read on a segment");
                        return -V2_EIO;
                    }
                    continue;
                }
                stalls = 0;
                done += (size_t)got;
            }
        }

        if ((segment->flags & V2_PROT_EXEC) != 0 && patcher != NULL) {
            int status = v2_patch_buffer(patcher,
                                         out->base + segment->vaddr,
                                         buffer, (size_t)segment->filesz,
                                         error, error_size);
            if (status != 0) {
                free(buffer);
                return status;
            }
        }

        if (v2_space_host(space)->write(v2_space_host(space)->ctx, destination, buffer,
                              (size_t)segment->filesz) != 0) {
            free(buffer);
            v2_error(error, error_size, "cannot write the segment");
            return -V2_EFAULT;
        }
    }
    free(buffer);
    return 0;
}

int v2_elf_protect(v2_space *space, const struct v2_elf_image *image,
                   const struct v2_elf_load *load, char *error,
                   size_t error_size)
{
    uint64_t page = v2_space_page_size(space);
    uint64_t pages = load->span / page;
    int run_prot = -1;
    uint64_t run_start = 0;

    for (uint64_t index = 0; index <= pages; index++) {
        int prot = -1;

        if (index < pages) {
            uint64_t address = load->start + index * page;
            prot = 0;
            for (int segment = 0; segment < image->segment_count; segment++) {
                uint64_t start = load->base + image->segments[segment].vaddr;
                uint64_t end = start + image->segments[segment].memsz;
                if (address < end && start < address + page) {
                    prot |= (int)image->segments[segment].flags;
                }
            }
        }

        if (prot == run_prot) {
            continue;
        }
        if (run_prot >= 0 && index > 0) {
            uint64_t start = run_start;
            uint64_t length = load->start + index * page - start;
            long long status = v2_space_protect(space, (void *)(uintptr_t)start,
                                                (size_t)length, run_prot);
            if (status != 0) {
                v2_error(error, error_size, "cannot apply segment permissions");
                return (int)status;
            }
            if ((run_prot & V2_PROT_EXEC) != 0) {
                v2_space_host(space)->flush_icache(v2_space_host(space)->ctx, (void *)(uintptr_t)start,
                                         (size_t)length);
            }
        }
        run_prot = prot;
        if (index < pages) {
            run_start = load->start + index * page;
        }
    }
    return 0;
}
