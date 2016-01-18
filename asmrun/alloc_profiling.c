/***********************************************************************/
/*                                                                     */
/*                               OCaml                                 */
/*                                                                     */
/*                 Mark Shinwell, Jane Street Europe                   */
/*                                                                     */
/*  Copyright 2013, Jane Street Holding                                */
/*                                                                     */
/*  Licensed under the Apache License, Version 2.0 (the "License");    */
/*  you may not use this file except in compliance with the License.   */
/*  You may obtain a copy of the License at                            */
/*                                                                     */
/*      http://www.apache.org/licenses/LICENSE-2.0                     */
/*                                                                     */
/*  Unless required by applicable law or agreed to in writing,         */
/*  software distributed under the License is distributed on an        */
/*  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,       */
/*  either express or implied.  See the License for the specific       */
/*  language governing permissions and limitations under the License.  */
/*                                                                     */
/***********************************************************************/

/* Runtime support for allocation profiling. */

#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifndef __APPLE__
#include <elf.h>
#endif
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>

#include "caml/alloc.h"
#include "caml/gc.h"
#include "caml/major_gc.h"
#include "caml/memory.h"
#include "caml/minor_gc.h"
#include "caml/mlvalues.h"
#include "caml/signals.h"

extern value caml_gc_full_major(value);

int ensure_alloc_profiling_dot_o_is_included = 42;

/* Determine the byte offset of a given section in an ELF file. */
CAMLprim value
caml_byte_offset_of_source_location_map_elf_section_contents(value v_executable,
                                                             value v_section_name)
{
#ifndef __APPLE__
  int fd;
  int bytes_read;
  char* filename;
  char* section_name;
  Elf64_Ehdr elf_header;
  Elf64_Half section_header_index;
  off_t section_header_string_table_file_offset;
  off_t file_offset;
  Elf64_Shdr section_header;
  off_t found_section_at_offset = -1;

  assert(Is_block(v_executable) && Tag_val(v_executable) == String_tag);
  assert(Is_block(v_section_name) && Tag_val(v_section_name) == String_tag);

  filename = strdup(String_val(v_executable));
  section_name = strdup(String_val(v_section_name));

  if (filename == NULL || section_name == NULL) {
    return Val_long(-1);
  }

  caml_enter_blocking_section();

  fd = open(filename, O_RDONLY);
  free(filename);
  if (fd < 0) {
    free(section_name);
    caml_leave_blocking_section();
    return Val_long(-1);
  }

  /* Read the ELF file header. */
  bytes_read = read(fd, &elf_header, sizeof(elf_header));
  /* CR mshinwell: extend to support 32-bit executables */
  if (bytes_read < sizeof(elf_header)
      || elf_header.e_ident[EI_CLASS] != ELFCLASS64
      || elf_header.e_shentsize != sizeof(Elf64_Shdr)) {
    free(section_name);
    (void) close(fd);
    caml_leave_blocking_section();
    return Val_long(-1);
  }

  /* Read the section header for the section header string table. */
  file_offset = elf_header.e_shoff + sizeof(section_header)*elf_header.e_shstrndx;
  if (lseek(fd, file_offset, SEEK_SET) < 0
      || read(fd, &section_header, sizeof(section_header)) < sizeof(section_header)) {
    free(section_name);
    (void) close(fd);
    caml_leave_blocking_section();
    return Val_long(-1);
  }
  section_header_string_table_file_offset = section_header.sh_offset;

  /* Iterate over each section looking for the desired section by name.  The name of
     each section is determined by reading a piece of the section header string table. */
  for (section_header_index = 0;
       found_section_at_offset == -1 && section_header_index < elf_header.e_shnum;
       section_header_index++) {
    char* desired_section_name;
    int name_of_this_section_does_not_match;

    if (lseek(fd, elf_header.e_shoff + sizeof(section_header)*section_header_index,
              SEEK_SET) < 0
        || read(fd, &section_header, sizeof(section_header)) < sizeof(section_header)
        || lseek(fd, section_header_string_table_file_offset + section_header.sh_name,
                 SEEK_SET) < 0) {
      free(section_name);
      (void) close(fd);
      caml_leave_blocking_section();
      return Val_long(-1);
    }

    desired_section_name = section_name;
    name_of_this_section_does_not_match = 0;
    while (!name_of_this_section_does_not_match && *desired_section_name) {
      char ch;
      if (read(fd, &ch, 1) < 1) {
        free(section_name);
        (void) close(fd);
        caml_leave_blocking_section();
        return Val_long(-1);
      }
      if (ch != *desired_section_name++) {
        name_of_this_section_does_not_match = 1;
      }
    }

    if (!name_of_this_section_does_not_match) {
      found_section_at_offset = section_header.sh_offset;
    }
  }

  free(section_name);
  (void) close(fd);
  caml_leave_blocking_section();

  return Val_long(found_section_at_offset);
#else
  /* Mac OS X does not use ELF. */
  v_executable = v_executable;
  v_section_name = v_section_name;
  return Val_long(-1);
#endif
}

static const uint64_t BUILTIN_RETURN_ADDRESS_FAILURE = 1ull << 4;
static const uint64_t CONSTANT_CLOSURE = 2ull << 4;
static const uint64_t STRUCTURED_CONSTANT = 3ull << 4;
static const uint64_t COMPILATION_UNIT = 4ull << 4;

void
caml_dump_allocators_of_minor_heap_blocks (const char* output_file)
{
  FILE* fp;
  value* ptr;
  uint64_t num_blocks_in_minor_heap = 0ull;
  uint64_t num_blocks_in_minor_heap_with_profinfo = 0ull;

  fp = fopen(output_file, "w");
  if (fp == NULL) {
    fprintf(stderr, "couldn't open file '%s' for heap block dump\n", output_file);
    return;
  }

  assert(((uintnat) caml_young_ptr) % sizeof(value) == 0);
  ptr = (value*) caml_young_ptr;
  assert(ptr >= (value*) caml_young_start);
  while (ptr < (value*) caml_young_end) {
    header_t hd;
    value value_in_minor_heap;
    uint64_t approx_instr_pointer;

    ptr++;
    value_in_minor_heap = (value) ptr;
    assert(Is_young(value_in_minor_heap));
    assert(Is_block(value_in_minor_heap));

    hd = Hd_val(value_in_minor_heap);

    /* We do not expect the value to be promoted, since this function
       should not be called during a minor collection. */
    assert(hd != 0);

    approx_instr_pointer = Decode_profinfo_hd(hd);
    num_blocks_in_minor_heap++;
    if (approx_instr_pointer != 0ull) {
      num_blocks_in_minor_heap_with_profinfo++;
      fprintf(fp, "%p %lld\n", (void*) approx_instr_pointer,
              (unsigned long long) Whsize_val(value_in_minor_heap));
    }

    ptr += Wosize_val(value_in_minor_heap);
  }

  fprintf(fp, "num blocks in minor heap %lld\n",
    (unsigned long long) num_blocks_in_minor_heap);
  fprintf(fp, "num blocks in minor heap with profinfo %lld\n",
    (unsigned long long) num_blocks_in_minor_heap_with_profinfo);

  fclose(fp);
}

CAMLprim value
caml_dump_allocators_of_minor_heap_blocks_from_ocaml (value output_file)
{
  assert(Is_block(output_file));
  caml_dump_allocators_of_minor_heap_blocks(String_val(output_file));
  return Val_unit;
}

void
caml_dump_allocators_of_major_heap_blocks (const char* output_file,
                                           int sample_strings)
{
  char* chunk;
  FILE* fp;
  uint64_t blue;
  uint64_t accounted_for;
  uint64_t builtin_return_address_failures;
  uint64_t constant_closures, structured_constants, compilation_units;
  uint64_t unaccounted_for = 0ull;
  uint64_t unaccounted_for_by_tag[256];
  int tag;

  blue = 0ull;
  accounted_for = 0ull;
  builtin_return_address_failures = 0ull;
  constant_closures = 0ull;
  structured_constants = 0ull;
  compilation_units = 0ull;

  for (tag = 0; tag < 256; tag++) {
    unaccounted_for_by_tag[tag] = 0ull;
  }

  fp = fopen(output_file, "w");
  if (fp == NULL) {
    fprintf(stderr, "couldn't open file '%s' for heap block dump\n", output_file);
    return;
  }

  chunk = caml_heap_start;

  while (chunk != NULL) {
    char* hp;
    char* limit;

    hp = chunk;
    limit = chunk + Chunk_size (chunk);

    while (hp < limit) {
      header_t hd = Hd_hp (hp);
      switch (Color_hd(hd)) {
        case Caml_blue:
          blue += Whsize_hd(hd);
          break;

        default: {
          uint64_t approx_instr_pointer;

          approx_instr_pointer = Decode_profinfo_hd(hd);
          if (approx_instr_pointer == BUILTIN_RETURN_ADDRESS_FAILURE) {
            builtin_return_address_failures += Whsize_hd(hd);
          } else if (approx_instr_pointer == CONSTANT_CLOSURE) {
            constant_closures += Whsize_hd(hd);
          } else if (approx_instr_pointer == STRUCTURED_CONSTANT) {
            structured_constants += Whsize_hd(hd);
          } else if (approx_instr_pointer == COMPILATION_UNIT) {
            compilation_units += Whsize_hd(hd);
          } else if (approx_instr_pointer != 0ull) {
            uint64_t size_in_words_including_header;
            const char* colour;

            size_in_words_including_header = Whsize_hd(hd);
            switch (Color_hd(hd)) {
              case Caml_black: colour = "b"; break;
              case Caml_gray: colour = "g"; break;
              case Caml_white: colour = "w"; break;
              default: assert(0);
            }

            accounted_for += Whsize_hd(hd);

            fprintf(fp, "%p %lld %s\n", (void*) approx_instr_pointer,
                    (unsigned long long) size_in_words_including_header, colour);
          }
          else {
            unaccounted_for += Whsize_hd(hd);
            unaccounted_for_by_tag[Tag_hd(hd)]++;
            if (sample_strings > 0) {
              fprintf(fp, "example value (tag %d) with no profiling info: %p (first field %p)\n",
                Tag_hd(hd), (void*) (Op_hp(hp)), (void*) *(Op_hp(hp)));
              sample_strings--;
            }
          }
          break;
        }
      }
      hp += Bhsize_hd (hd);
      Assert (hp <= limit);
    }

    chunk = Chunk_next (chunk);
  }

  fprintf(fp, "word size (incl headers) of non-blue blocks with profiling info: %lld\n", (unsigned long long) accounted_for);
  fprintf(fp, "word size (incl headers) of non-blue blocks with no profiling info: %lld\n  by tag: ", (unsigned long long) unaccounted_for);
  for (tag = 0; tag < 256; tag++) {
    if (unaccounted_for_by_tag[tag] > 0) {
      fprintf(fp, "tag(%d)=%lld ", tag, (unsigned long long) unaccounted_for_by_tag[tag]);
    }
  }
  fprintf(fp, "\n");
  fprintf(fp, "word size (incl headers) with __builtin_return_address failures: %lld\n",
    (unsigned long long) builtin_return_address_failures);
  fprintf(fp, "word size (incl headers) of constant closures: %lld\n",
    (unsigned long long) constant_closures);
  fprintf(fp, "word size (incl headers) of structured constants: %lld\n",
    (unsigned long long) structured_constants);
  fprintf(fp, "word size (incl headers) of compilation unit blocks: %lld\n",
    (unsigned long long) compilation_units);
  fprintf(fp, "word size (incl headers) of blue blocks: %lld\n", (unsigned long long) blue);
  fprintf(fp, "word size (incl headers) of all blocks: %lld\n", (unsigned long long) (blue + accounted_for + unaccounted_for));
  fprintf(fp, "caml_stat_heap_wsz in words: %lld\n", (unsigned long long) caml_stat_heap_wsz / sizeof(value));

  fclose(fp);
}

CAMLprim value
caml_dump_allocators_of_major_heap_blocks_from_ocaml (value output_file,
                                                      value sample_strings)
{
  assert(Is_block(output_file) && Tag_val(output_file) == String_tag);
  caml_dump_allocators_of_major_heap_blocks(String_val(output_file),
    Int_val(sample_strings));
  return Val_unit;
}

CAMLprim value
caml_where_was_this_allocated (value v)
{
  uint64_t approx_instr_pointer;
  CAMLparam0();
  CAMLlocal1(v_approx_instr_pointer);
  value v_result;

  if (!Is_block(v)) {
    CAMLreturn(Val_long(0));  /* None */
  }

  approx_instr_pointer = Decode_profinfo_hd (Hd_val (v));

  if (approx_instr_pointer == 0ull) {
    CAMLreturn(Val_long(0));  /* None */
  }

  v_approx_instr_pointer = caml_copy_int64(approx_instr_pointer);

  v_result = caml_alloc_small(1, 0 /* Some */);
  Field(v_result, 0) = v_approx_instr_pointer;

  CAMLreturn(v_result);
}

CAMLprim value
caml_forget_where_values_were_allocated (value v_unit)
{
  char* chunk;

  assert(v_unit == Val_unit);

  caml_gc_full_major(Val_unit);

  chunk = caml_heap_start;

  while (chunk != NULL) {
    char* hp;
    char* limit;

    hp = chunk;
    limit = chunk + Chunk_size (chunk);

    while (hp < limit) {
      header_t hd = Hd_hp (hp);
      Hd_hp (hp) = Make_header_with_profinfo (Wosize_hd(hd), Tag_hd(hd), Color_hd(hd), 0);
      hp += Bhsize_hd (hd);
      Assert (hp <= limit);
    }

    chunk = Chunk_next (chunk);
  }

  return v_unit;
}

void
caml_dump_heapgraph(const char* node_output_file, const char* edge_output_file)
{
  char* chunk;
  FILE* node_fp;
  FILE* edge_fp;

  node_fp = fopen(node_output_file, "w");
  if (node_fp == NULL) {
    fprintf(stderr, "couldn't open file '%s' for heap graph dump\n", node_output_file);
    return;
  }

  edge_fp = fopen(edge_output_file, "w");
  if (edge_fp == NULL) {
    fprintf(stderr, "couldn't open file '%s' for heap graph dump\n", edge_output_file);
    return;
  }

  caml_gc_full_major(Val_unit);

  chunk = caml_heap_start;

  while (chunk != NULL) {
    char* hp;
    char* limit;

    hp = chunk;
    limit = chunk + Chunk_size (chunk);

    while (hp < limit) {
      header_t hd_parent = Hd_hp (hp);
      switch (Color_hd(hd_parent)) {
        case Caml_blue:
          break;

        default: {
          uint64_t approx_instr_pointer_parent;

          approx_instr_pointer_parent = Decode_profinfo_hd (hd_parent);

          if (approx_instr_pointer_parent != 0ull) {
            if (Tag_hd(hd_parent) < No_scan_tag) {
              mlsize_t field;
              value parent;

              parent = Val_hp(hp);
              assert(Is_block(parent));

              for (field = 0; field < Wosize_val(parent); field++) {
                value child;
                child = Field(parent, field);

                if (Is_block(child) && Is_in_value_area(child)) {
                  uint64_t approx_instr_pointer_child;
                  header_t hd_child;

                  hd_child = Hd_val(child);
                  approx_instr_pointer_child = Decode_profinfo_hd (hd_child);

                  if (approx_instr_pointer_child != 0ull) {
                    fprintf(edge_fp, "B %p,%d,%lld\n",
                      (void*) approx_instr_pointer_parent,
                      Tag_hd(hd_parent),
                      (unsigned long long) Wosize_hd(hd_parent));
                    fprintf(edge_fp, "B %p,%d,%lld\n",
                      (void*) approx_instr_pointer_child,
                      Tag_val(hd_child),
                      (unsigned long long) Wosize_hd(hd_child));
                    fprintf(edge_fp, "E %p,%p\n",
                            (void*) approx_instr_pointer_parent,
                            (void*) approx_instr_pointer_child);
                  }
                }
              }
            }
          }
          break;
        }
      }
      hp += Bhsize_hd (hd_parent);
      Assert (hp <= limit);
    }

    chunk = Chunk_next (chunk);
  }

  fclose(node_fp);
  fclose(edge_fp);
}

CAMLprim value
caml_dump_heapgraph_from_ocaml(value node_output_file, value edge_output_file)
{
  assert(Is_block(node_output_file) && Tag_val(node_output_file) == String_tag);
  assert(Is_block(edge_output_file) && Tag_val(edge_output_file) == String_tag);

  caml_dump_heapgraph(String_val(node_output_file), String_val(edge_output_file));

  return Val_unit;
}

#define MAX_LOG2_OBJECT_SIZE 9
typedef struct {
  uint64_t num_words_by_log2_object_size[MAX_LOG2_OBJECT_SIZE + 1];
  uint64_t num_blocks_by_log2_object_size[MAX_LOG2_OBJECT_SIZE + 1];
  uint64_t total_words;
  uint64_t total_blocks;
} lifetime_bucket;
static lifetime_bucket* lifetime_buckets_minor = NULL;
static lifetime_bucket* lifetime_buckets_major = NULL;
static double lifetime_log10_bytes_min = 2.0;
static double lifetime_log10_bytes_max = 8.0;
static uint64_t num_lifetime_buckets = 1000;
static double lifetime_bucket_width;
extern uintnat caml_lifetime_shift;

static void
init_lifetime_buckets(void)
{
  char* bytes_min_env;
  char* bytes_max_env;
  char* num_buckets_env;

  bytes_min_env = getenv("CAML_LIFETIME_MIN_BYTES");
  bytes_max_env = getenv("CAML_LIFETIME_MAX_BYTES");
  num_buckets_env = getenv("CAML_LIFETIME_NUM_BUCKETS");

  if (bytes_min_env) {
    lifetime_log10_bytes_min = log((double) atoll(bytes_min_env)) / log(10.0);
  }
  if (bytes_max_env) {
    lifetime_log10_bytes_max = log((double) atoll(bytes_max_env)) / log(10.0);
  }
  if (num_buckets_env) {
    num_lifetime_buckets = (uint64_t) atoll(num_buckets_env);
  }

  if (lifetime_log10_bytes_min > lifetime_log10_bytes_max) {
    fprintf(stderr, "maximum lifetime must be greater than minimum\n");
    abort();
  }

  lifetime_buckets_minor =
    (lifetime_bucket*) calloc(num_lifetime_buckets, sizeof(lifetime_bucket));
  lifetime_buckets_major =
    (lifetime_bucket*) calloc(num_lifetime_buckets, sizeof(lifetime_bucket));

  lifetime_bucket_width =
    (lifetime_log10_bytes_max - lifetime_log10_bytes_min) / num_lifetime_buckets;
}

void
caml_record_lifetime_sample(header_t hd, int in_major_heap, uint64_t now)
{
  uint64_t allocation_time;
  allocation_time = Decode_profinfo_hd(hd);

  if (allocation_time > 0) {  /* in case we failed to annotate a block */
    if (now >= allocation_time) {
      uint64_t lifetime;
      uint64_t bucket;
      double log10_lifetime;

      if (!lifetime_buckets_minor) {
        init_lifetime_buckets();
      }

      lifetime = now - allocation_time;
      log10_lifetime = log((double) (lifetime + 1)) / log(10.0);

      if (log10_lifetime >= lifetime_log10_bytes_min
            && log10_lifetime < lifetime_log10_bytes_max) {
        bucket = (log10_lifetime - lifetime_log10_bytes_min) / lifetime_bucket_width;

        if (bucket >= 0 && bucket < num_lifetime_buckets) {  /* just in case */
          lifetime_bucket* buckets;

          int log2_object_size = (int) (floor(log((double) (Wosize_hd(hd)))));
          if (log2_object_size > MAX_LOG2_OBJECT_SIZE) {
            log2_object_size = MAX_LOG2_OBJECT_SIZE;
          }

          buckets = in_major_heap ? lifetime_buckets_major : lifetime_buckets_minor;

          buckets[bucket].num_blocks_by_log2_object_size[log2_object_size]++;
          buckets[bucket].total_blocks++;

          buckets[bucket].num_words_by_log2_object_size[log2_object_size] += Wosize_hd(hd);
          buckets[bucket].total_words += Wosize_hd(hd);
        }
      }
    }
  }
}

void
caml_dump_lifetimes(void)
{
  uint64_t bucket;

  /* Output format (columns left to right):
        - centre of lifetime bucket, units are log10(bytes allocated)
        - total number of blocks in this lifetime bucket, minor heap
        - total number of words in this lifetime bucket, minor heap
        - total number of blocks in this lifetime bucket, major heap
        - total number of words in this lifetime bucket, major heap
        then a sequence of MAX_LOG2_OBJECT_SIZE+1 column sets, each as follows, giving
        object sizes in this lifetime bucket:
        - minimum number of words in a block in this size bucket
        - maximum number of words in a block in this size bucket
        - number of blocks in this size bucket, minor heap
        - number of words in this size bucket, minor heap
        - number of blocks in this size bucket, major heap
        - number of words in this size bucket, major heap
     Lines are not output for lifetime buckets that are empty.
  */

  for (bucket = 0ull; bucket < num_lifetime_buckets; bucket++) {
    int size_bucket;
    double centre_of_bucket =
      (lifetime_bucket_width * (double) bucket) + (lifetime_bucket_width / 2.0);

    if (lifetime_buckets_minor[bucket].total_blocks != 0ull
          || lifetime_buckets_major[bucket].total_words != 0ull) {
      fprintf(stderr, "%g %lld %lld %lld %lld",
        lifetime_log10_bytes_min + centre_of_bucket,
        (unsigned long long) lifetime_buckets_minor[bucket].total_blocks,
        (unsigned long long) lifetime_buckets_minor[bucket].total_words,
        (unsigned long long) lifetime_buckets_major[bucket].total_blocks,
        (unsigned long long) lifetime_buckets_major[bucket].total_words);
      for (size_bucket = 0; size_bucket <= MAX_LOG2_OBJECT_SIZE; size_bucket++) {
        fprintf(stderr, " %d %d %lld %lld %lld %lld",
          (int) (pow(2.0, size_bucket)),
          (int) (pow(2.0, size_bucket + 1) - 1),
          (unsigned long long)
            lifetime_buckets_minor[bucket].num_blocks_by_log2_object_size[size_bucket],
          (unsigned long long)
            lifetime_buckets_minor[bucket].num_words_by_log2_object_size[size_bucket],
          (unsigned long long)
            lifetime_buckets_major[bucket].num_blocks_by_log2_object_size[size_bucket],
          (unsigned long long)
            lifetime_buckets_major[bucket].num_words_by_log2_object_size[size_bucket]);
      }
      fprintf(stderr, "\n");
    }
  }
}
