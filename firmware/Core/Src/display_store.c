#include "display_store.h"

#include <stddef.h>
#include <string.h>

#include "crc.h"
#include "main.h"

#define DISPLAY_STORE_SLOT_COUNT 2U
#define DISPLAY_STORE_SLOT_SIZE (6U * 1024U)
#define DISPLAY_STORE_HEADER_SIZE 64U
#define DISPLAY_STORE_NO_SLOT 0xFFU

/* PREPARED and COMMITTED use different Flash double-words. STM32G0 Flash
 * ECC does not permit an already-programmed double-word to be used as a
 * conventional bit-clearing state variable. */
#define DISPLAY_STORE_STAGE_MARKER UINT64_C(0x3150525044434E53)
#define DISPLAY_STORE_COMMIT_MARKER UINT64_C(0x31544D4344434E53)
#define DISPLAY_STORE_ERASED UINT64_C(0xFFFFFFFFFFFFFFFF)
#define DISPLAY_STORE_PATTERN_MASK 0x7FU
#define DISPLAY_STORE_BATCH_CLEAN 0x80U

typedef struct {
    uint64_t stage_marker;
    uint64_t commit_marker;
    uint32_t generation;
    uint32_t image_crc32;
    uint16_t transfer_id;
    uint16_t expected_sequence;
    uint16_t expected_offset;
    uint8_t pattern_id;
    uint8_t format_version;
    uint32_t metadata_crc32;
    uint8_t reserved[28];
} display_store_header_t;

_Static_assert(sizeof(display_store_header_t) == DISPLAY_STORE_HEADER_SIZE,
               "display store header must be 64 bytes");
_Static_assert((NC_IMAGE_SIZE % 8U) == 0U,
               "display image size must be a multiple of 8");

extern uint8_t __display_store_start__;

static uint8_t committed_slot;
static uint8_t pending_slot;
static uint32_t newest_generation;

static uintptr_t slot_address(uint8_t slot)
{
    return (uintptr_t)&__display_store_start__ +
           (uintptr_t)slot * DISPLAY_STORE_SLOT_SIZE;
}

static const display_store_header_t *slot_header(uint8_t slot)
{
    return (const display_store_header_t *)slot_address(slot);
}

static const uint8_t *slot_image(uint8_t slot)
{
    return (const uint8_t *)(slot_address(slot) + DISPLAY_STORE_HEADER_SIZE);
}

static uint32_t metadata_crc(const display_store_header_t *header)
{
    return nc_crc32_ieee((const uint8_t *)&header->generation, 16U);
}

static bool slot_valid(uint8_t slot)
{
    const display_store_header_t *header = slot_header(slot);
    if ((header->stage_marker != DISPLAY_STORE_STAGE_MARKER) ||
        ((header->commit_marker != DISPLAY_STORE_ERASED) &&
         (header->commit_marker != DISPLAY_STORE_COMMIT_MARKER)) ||
        (header->expected_offset != NC_IMAGE_SIZE) ||
        ((header->format_version != NC_IMAGE_FORMAT_NATIVE_1BPP) &&
         (header->format_version != NC_IMAGE_FORMAT_GRAY4_PLANE)) ||
        (header->metadata_crc32 != metadata_crc(header))) {
        return false;
    }
    return nc_crc32_ieee(slot_image(slot), NC_IMAGE_SIZE) ==
           header->image_crc32;
}

static bool generation_is_newer(uint32_t candidate, uint32_t reference)
{
    return (int32_t)(candidate - reference) > 0;
}

void display_store_init(void)
{
    committed_slot = DISPLAY_STORE_NO_SLOT;
    pending_slot = DISPLAY_STORE_NO_SLOT;
    newest_generation = 0U;

    for (uint8_t slot = 0U; slot < DISPLAY_STORE_SLOT_COUNT; ++slot) {
        if (!slot_valid(slot)) {
            continue;
        }
        const display_store_header_t *header = slot_header(slot);
        if ((newest_generation == 0U) ||
            generation_is_newer(header->generation, newest_generation)) {
            newest_generation = header->generation;
        }
        if (header->commit_marker == DISPLAY_STORE_COMMIT_MARKER) {
            if ((committed_slot == DISPLAY_STORE_NO_SLOT) ||
                generation_is_newer(header->generation,
                                    slot_header(committed_slot)->generation)) {
                committed_slot = slot;
            }
        }
    }

    /* A newer PREPARED frame means power was removed after staging or while
     * refreshing. Preserve it so the same Android transfer can resume. */
    for (uint8_t slot = 0U; slot < DISPLAY_STORE_SLOT_COUNT; ++slot) {
        if (!slot_valid(slot) ||
            (slot_header(slot)->commit_marker != DISPLAY_STORE_ERASED)) {
            continue;
        }
        const bool newer_than_committed =
            (committed_slot == DISPLAY_STORE_NO_SLOT) ||
            generation_is_newer(slot_header(slot)->generation,
                                slot_header(committed_slot)->generation);
        if (newer_than_committed &&
            ((pending_slot == DISPLAY_STORE_NO_SLOT) ||
             generation_is_newer(slot_header(slot)->generation,
                                 slot_header(pending_slot)->generation))) {
            pending_slot = slot;
        }
    }
}

bool display_store_has_committed(void)
{
    return committed_slot != DISPLAY_STORE_NO_SLOT;
}

const uint8_t *display_store_committed_image(void)
{
    return display_store_has_committed() ? slot_image(committed_slot) : NULL;
}

uint16_t display_store_committed_transfer_id(void)
{
    return display_store_has_committed()
               ? slot_header(committed_slot)->transfer_id
               : 0U;
}

uint16_t display_store_committed_sequence(void)
{
    return display_store_has_committed()
               ? slot_header(committed_slot)->expected_sequence
               : 0U;
}

uint8_t display_store_committed_pattern_id(void)
{
    return display_store_has_committed()
               ? (uint8_t)(slot_header(committed_slot)->pattern_id &
                           DISPLAY_STORE_PATTERN_MASK)
               : 0U;
}

uint8_t display_store_committed_format(void)
{
    return display_store_has_committed()
               ? slot_header(committed_slot)->format_version
               : 0U;
}

bool display_store_committed_batch_clean(void)
{
    return display_store_has_committed() &&
           ((slot_header(committed_slot)->pattern_id &
             DISPLAY_STORE_BATCH_CLEAN) != 0U);
}

bool display_store_has_pending(void)
{
    return pending_slot != DISPLAY_STORE_NO_SLOT;
}

const uint8_t *display_store_pending_image(void)
{
    return display_store_has_pending() ? slot_image(pending_slot) : NULL;
}

uint16_t display_store_pending_transfer_id(void)
{
    return display_store_has_pending()
               ? slot_header(pending_slot)->transfer_id
               : 0U;
}

uint16_t display_store_pending_sequence(void)
{
    return display_store_has_pending()
               ? slot_header(pending_slot)->expected_sequence
               : 0U;
}

uint8_t display_store_pending_pattern_id(void)
{
    return display_store_has_pending()
               ? (uint8_t)(slot_header(pending_slot)->pattern_id &
                           DISPLAY_STORE_PATTERN_MASK)
               : 0U;
}

uint8_t display_store_pending_format(void)
{
    return display_store_has_pending()
               ? slot_header(pending_slot)->format_version
               : 0U;
}

bool display_store_pending_batch_clean(void)
{
    return display_store_has_pending() &&
           ((slot_header(pending_slot)->pattern_id &
             DISPLAY_STORE_BATCH_CLEAN) != 0U);
}

static bool program_doubleword(uintptr_t address, const void *source)
{
    uint64_t value;
    memcpy(&value, source, sizeof(value));
    return HAL_FLASH_Program(FLASH_TYPEPROGRAM_DOUBLEWORD, (uint32_t)address,
                             value) == HAL_OK;
}

bool display_store_stage(const uint8_t image[NC_IMAGE_SIZE],
                         uint16_t transfer_id, uint16_t expected_sequence,
                         uint8_t pattern_id, uint8_t image_format,
                         bool batch_clean)
{
    if ((image == NULL) ||
        ((image_format != NC_IMAGE_FORMAT_NATIVE_1BPP) &&
         (image_format != NC_IMAGE_FORMAT_GRAY4_PLANE))) {
        return false;
    }

    const uint8_t target_slot = committed_slot == 0U ? 1U : 0U;
    const uintptr_t base = slot_address(target_slot);
    display_store_header_t header;
    memset(&header, 0xFF, sizeof(header));
    header.stage_marker = DISPLAY_STORE_STAGE_MARKER;
    header.commit_marker = DISPLAY_STORE_ERASED;
    header.generation = newest_generation + 1U;
    if (header.generation == 0U) {
        header.generation = 1U;
    }
    header.image_crc32 = nc_crc32_ieee(image, NC_IMAGE_SIZE);
    header.transfer_id = transfer_id;
    header.expected_sequence = expected_sequence;
    header.expected_offset = NC_IMAGE_SIZE;
    header.pattern_id = (uint8_t)(pattern_id & DISPLAY_STORE_PATTERN_MASK);
    if (batch_clean) {
        header.pattern_id |= DISPLAY_STORE_BATCH_CLEAN;
    }
    header.format_version = image_format;
    header.metadata_crc32 = metadata_crc(&header);

    FLASH_EraseInitTypeDef erase = {
        .TypeErase = FLASH_TYPEERASE_PAGES,
        .Banks = FLASH_BANK_1,
        .Page = (uint32_t)((base - FLASH_BASE) / FLASH_PAGE_SIZE),
        .NbPages = DISPLAY_STORE_SLOT_SIZE / FLASH_PAGE_SIZE,
    };
    uint32_t page_error = 0U;
    bool ok = HAL_FLASH_Unlock() == HAL_OK;
    if (ok) {
        ok = HAL_FLASHEx_Erase(&erase, &page_error) == HAL_OK;
    }

    /* Image first, metadata second, PREPARED marker last. An interrupted
     * stage scans as invalid and the other slot remains untouched. */
    for (size_t offset = 0U; ok && (offset < NC_IMAGE_SIZE); offset += 8U) {
        ok = program_doubleword(base + DISPLAY_STORE_HEADER_SIZE + offset,
                                &image[offset]);
    }
    for (size_t offset = 16U; ok && (offset <= 32U); offset += 8U) {
        ok = program_doubleword(base + offset,
                                (const uint8_t *)&header + offset);
    }
    if (ok) {
        ok = program_doubleword(base, &header.stage_marker);
    }
    (void)HAL_FLASH_Lock();

    if (!ok || !slot_valid(target_slot) ||
        (slot_header(target_slot)->commit_marker != DISPLAY_STORE_ERASED)) {
        return false;
    }
    pending_slot = target_slot;
    newest_generation = header.generation;
    return true;
}

bool display_store_commit(void)
{
    if (!display_store_has_pending() || !slot_valid(pending_slot)) {
        return false;
    }
    const uintptr_t address = slot_address(pending_slot) +
                              offsetof(display_store_header_t, commit_marker);
    const uint64_t marker = DISPLAY_STORE_COMMIT_MARKER;
    bool ok = HAL_FLASH_Unlock() == HAL_OK;
    if (ok) {
        ok = program_doubleword(address, &marker);
    }
    (void)HAL_FLASH_Lock();
    if (!ok || (slot_header(pending_slot)->commit_marker != marker) ||
        !slot_valid(pending_slot)) {
        return false;
    }
    committed_slot = pending_slot;
    pending_slot = DISPLAY_STORE_NO_SLOT;
    return true;
}
