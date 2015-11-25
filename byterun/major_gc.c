/***********************************************************************/
/*                                                                     */
/*                                OCaml                                */
/*                                                                     */
/*             Damien Doligez, projet Para, INRIA Rocquencourt         */
/*                                                                     */
/*  Copyright 1996 Institut National de Recherche en Informatique et   */
/*  en Automatique.  All rights reserved.  This file is distributed    */
/*  under the terms of the GNU Library General Public License, with    */
/*  the special exception on linking described in file ../LICENSE.     */
/*                                                                     */
/***********************************************************************/

#include <limits.h>
#include <math.h>

#include "caml/compact.h"
#include "caml/custom.h"
#include "caml/config.h"
#include "caml/fail.h"
#include "caml/finalise.h"
#include "caml/freelist.h"
#include "caml/gc.h"
#include "caml/gc_ctrl.h"
#include "caml/major_gc.h"
#include "caml/misc.h"
#include "caml/mlvalues.h"
#include "caml/roots.h"
#include "caml/weak.h"

#if defined (NATIVE_CODE) && defined (NO_NAKED_POINTERS)
#define NATIVE_CODE_AND_NO_NAKED_POINTERS
#else
#undef NATIVE_CODE_AND_NO_NAKED_POINTERS
#endif

uintnat caml_percent_free;
uintnat caml_major_heap_increment;
CAMLexport char *caml_heap_start;
char *caml_gc_sweep_hp;
int caml_gc_phase;        /* always Phase_mark, Phase_sweep, or Phase_idle */
static value *gray_vals;
static value *gray_vals_cur, *gray_vals_end;
static asize_t gray_vals_size;
static int heap_is_pure;   /* The heap is pure if the only gray objects
                              below [markhp] are also in [gray_vals]. */
uintnat caml_allocated_words;
uintnat caml_dependent_size, caml_dependent_allocated;
double caml_extra_heap_resources;
uintnat caml_fl_wsz_at_phase_change = 0;

extern char *caml_fl_merge;  /* Defined in freelist.c. */

static char *markhp, *chunk, *limit;

int caml_gc_subphase;     /* Subphase_{main,weak1,weak2,final} */
static value *weak_prev;

int caml_major_window = 1;
double caml_major_ring[Max_major_window] = { 0. };
int caml_major_ring_index = 0;
double caml_major_work_credit = 0.0;
double caml_gc_clock = 0.0;

#ifdef DEBUG
static unsigned long major_gc_counter = 0;
#endif

void (*caml_major_gc_hook)(void) = NULL;

static void realloc_gray_vals (void)
{
  value *new;

  Assert (gray_vals_cur == gray_vals_end);
  if (gray_vals_size < caml_stat_heap_wsz / 32){
    caml_gc_message (0x08, "Growing gray_vals to %"
                           ARCH_INTNAT_PRINTF_FORMAT "uk bytes\n",
                     (intnat) gray_vals_size * sizeof (value) / 512);
    new = (value *) realloc ((char *) gray_vals,
                             2 * gray_vals_size * sizeof (value));
    if (new == NULL){
      caml_gc_message (0x08, "No room for growing gray_vals\n", 0);
      gray_vals_cur = gray_vals;
      heap_is_pure = 0;
    }else{
      gray_vals = new;
      gray_vals_cur = gray_vals + gray_vals_size;
      gray_vals_size *= 2;
      gray_vals_end = gray_vals + gray_vals_size;
    }
  }else{
    gray_vals_cur = gray_vals + gray_vals_size / 2;
    heap_is_pure = 0;
  }
}

void caml_darken (value v, value *p /* not used */)
{
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
  if (Is_block (v) && !Is_young (v) && Wosize_val (v) > 0) {
#else
  if (Is_block (v) && Is_in_heap (v)) {
#endif
    header_t h = Hd_val (v);
    tag_t t = Tag_hd (h);
    if (t == Infix_tag){
      v -= Infix_offset_val(v);
      h = Hd_val (v);
      t = Tag_hd (h);
    }
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
    /* We insist that naked pointers to outside the heap point to things that
       look like values with headers coloured black.  This isn't always
       strictly necessary but is essential in certain cases---in particular
       when the value is allocated in a read-only section.  (For the values
       where it would be safe it is a performance improvement since we avoid
       putting them on the grey list.) */
    CAMLassert (Is_in_heap (v) || Is_black_hd (h));
#endif
    CAMLassert (!Is_blue_hd (h));
    if (Is_white_hd (h)){
      if (t < No_scan_tag){
        Hd_val (v) = Grayhd_hd (h);
        *gray_vals_cur++ = v;
        if (gray_vals_cur >= gray_vals_end) realloc_gray_vals ();
      }else{
        Hd_val (v) = Blackhd_hd (h);
      }
    }
  }
}

static void start_cycle (void)
{
  Assert (caml_gc_phase == Phase_idle);
  Assert (gray_vals_cur == gray_vals);
  caml_gc_message (0x01, "Starting new major GC cycle\n", 0);
  caml_darken_all_roots_start ();
  caml_gc_phase = Phase_mark;
  caml_gc_subphase = Subphase_roots;
  markhp = NULL;
#ifdef DEBUG
  ++ major_gc_counter;
  caml_heap_check ();
#endif
}

/* We may stop the slice inside values, in order to avoid large latencies
   on large arrays. In this case, [current_value] is the partially-marked
   value and [current_index] is the index of the next field to be marked.
*/
static value current_value = 0;
static mlsize_t current_index = 0;

#ifdef CAML_INSTR
#define INSTR(x) x
#else
#define INSTR(x) /**/
#endif

static void mark_slice (intnat work)
{
  value *gray_vals_ptr;  /* Local copy of [gray_vals_cur] */
  value v, child;
  header_t hd, chd;
  mlsize_t size, i, start, end; /* [start] is a local copy of [current_index] */
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
  int marking_closure = 0;
#endif
#ifdef CAML_INSTR
  int slice_fields = 0;
  int slice_pointers = 0;
#endif

  caml_gc_message (0x40, "Marking %ld words\n", work);
  caml_gc_message (0x40, "Subphase = %ld\n", caml_gc_subphase);
  gray_vals_ptr = gray_vals_cur;
  v = current_value;
  start = current_index;
  while (work > 0){
    if (v == 0 && gray_vals_ptr > gray_vals){
      CAMLassert (start == 0);
      v = *--gray_vals_ptr;
      CAMLassert (Is_gray_val (v));
    }
    if (v != 0){
      hd = Hd_val(v);
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
      marking_closure =
        (Tag_hd (hd) == Closure_tag || Tag_hd (hd) == Infix_tag);
#endif
      Assert (Is_gray_hd (hd));
      size = Wosize_hd (hd);
      end = start + work;
      if (Tag_hd (hd) < No_scan_tag){
        start = size < start ? size : start;
        end = size < end ? size : end;
        CAMLassert (end > start);
        INSTR (slice_fields += end - start;)
        INSTR (if (size > end)
                 CAML_INSTR_INT ("major/mark/slice/remain", size - end);)
        for (i = start; i < end; i++){
          child = Field (v, i);
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
          if (Is_block (child)
                && ! Is_young (child)
                && Wosize_val (child) > 0  /* Atoms never need to be marked. */
                /* Closure blocks contain code pointers at offsets that cannot
                   be reliably determined, so we always use the page table when
                   marking such values. */
                && (!marking_closure || Is_in_heap (child))) {
#else
          if (Is_block (child) && Is_in_heap (child)) {
#endif
            INSTR (++ slice_pointers;)
            chd = Hd_val (child);
            if (Tag_hd (chd) == Forward_tag){
              value f = Forward_val (child);
              if (Is_block (f)
                  && (!Is_in_value_area(f) || Tag_val (f) == Forward_tag
                      || Tag_val (f) == Lazy_tag || Tag_val (f) == Double_tag)){
                /* Do not short-circuit the pointer. */
              }else{
                Field (v, i) = f;
                if (Is_block (f) && Is_young (f) && !Is_young (child))
                  Add_to_ref_table (caml_ref_table, &Field (v, i));
              }
            }else if (Tag_hd(chd) == Infix_tag) {
              child -= Infix_offset_val(child);
              chd = Hd_val(child);
            }
#ifdef NATIVE_CODE_AND_NO_NAKED_POINTERS
            /* See [caml_darken] for a description of this assertion. */
            CAMLassert (Is_in_heap (child) || Is_black_hd (chd));
#endif
            if (Is_white_hd (chd)){
              Hd_val (child) = Grayhd_hd (chd);
              *gray_vals_ptr++ = child;
              if (gray_vals_ptr >= gray_vals_end) {
                gray_vals_cur = gray_vals_ptr;
                realloc_gray_vals ();
                gray_vals_ptr = gray_vals_cur;
              }
            }
          }
        }
        if (end < size){
          work = 0;
          start = end;
          /* [v] doesn't change. */
          CAMLassert (Is_gray_val (v));
        }else{
          CAMLassert (end == size);
          Hd_val (v) = Blackhd_hd (hd);
          work -= Whsize_wosize(end - start);
          start = 0;
          v = 0;
        }
      }else{
        /* The block doesn't contain any pointers. */
        CAMLassert (start == 0);
        Hd_val (v) = Blackhd_hd (hd);
        work -= Whsize_wosize(size);
        v = 0;
      }
    }else if (markhp != NULL){
      if (markhp == limit){
        chunk = Chunk_next (chunk);
        if (chunk == NULL){
          markhp = NULL;
        }else{
          markhp = chunk;
          limit = chunk + Chunk_size (chunk);
        }
      }else{
        if (Is_gray_val (Val_hp (markhp))){
          Assert (gray_vals_ptr == gray_vals);
          CAMLassert (v == 0 && start == 0);
          v = Val_hp (markhp);
        }
        markhp += Bhsize_hp (markhp);
      }
    }else if (!heap_is_pure){
      heap_is_pure = 1;
      chunk = caml_heap_start;
      markhp = chunk;
      limit = chunk + Chunk_size (chunk);
    }else{
      switch (caml_gc_subphase){
      case Subphase_roots: {
        intnat work_done;
        gray_vals_cur = gray_vals_ptr;
        work_done = caml_darken_all_roots_slice (work);
        gray_vals_ptr = gray_vals_cur;
        if (work_done < work){
          caml_gc_subphase = Subphase_main;
        }
        work -= work_done;
      }
        break;
      case Subphase_main: {
        /* The main marking phase is over.  Start removing weak pointers to
           dead values. */
        caml_gc_subphase = Subphase_weak1;
        weak_prev = &caml_weak_list_head;
      }
        break;
      case Subphase_weak1: {
        value cur, curfield;
        mlsize_t sz, i;
        header_t hd;

        cur = *weak_prev;
        if (cur != (value) NULL){
          hd = Hd_val (cur);
          sz = Wosize_hd (hd);
          for (i = 1; i < sz; i++){
            curfield = Field (cur, i);
          weak_again:
            if (curfield != caml_weak_none
                && Is_block (curfield) && Is_in_heap_or_young (curfield)){
              if (Tag_val (curfield) == Forward_tag){
                value f = Forward_val (curfield);
                if (Is_block (f)) {
                  if (!Is_in_value_area(f) || Tag_val (f) == Forward_tag
                      || Tag_val (f) == Lazy_tag || Tag_val (f) == Double_tag){
                    /* Do not short-circuit the pointer. */
                  }else{
                    Field (cur, i) = curfield = f;
                    if (Is_block (f) && Is_young (f))
                      Add_to_ref_table (caml_weak_ref_table, &Field (cur, i));
                    goto weak_again;
                  }
                }
              }
              if (Is_white_val (curfield) && !Is_young (curfield)){
                Field (cur, i) = caml_weak_none;
              }
            }
          }
          weak_prev = &Field (cur, 0);
          work -= Whsize_hd (hd);
        }else{
          /* Subphase_weak1 is done.
             Handle finalised values and start removing dead weak arrays. */
          gray_vals_cur = gray_vals_ptr;
          caml_final_update ();
          gray_vals_ptr = gray_vals_cur;
          if (gray_vals_ptr > gray_vals){
            v = *--gray_vals_ptr;
            CAMLassert (start == 0);
          }
          caml_gc_subphase = Subphase_weak2;
          weak_prev = &caml_weak_list_head;
        }
      }
        break;
      case Subphase_weak2: {
        value cur;
        header_t hd;

        cur = *weak_prev;
        if (cur != (value) NULL){
          hd = Hd_val (cur);
          if (Color_hd (hd) == Caml_white){
            /* The whole array is dead, remove it from the list. */
            *weak_prev = Field (cur, 0);
          }else{
            weak_prev = &Field (cur, 0);
          }
          work -= 1;
        }else{
          /* Subphase_weak2 is done.  Go to Subphase_final. */
          caml_gc_subphase = Subphase_final;
        }
      }
        break;
      case Subphase_final: {
        /* Initialise the sweep phase. */
        caml_gc_sweep_hp = caml_heap_start;
        caml_fl_init_merge ();
        caml_gc_phase = Phase_sweep;
        chunk = caml_heap_start;
        caml_gc_sweep_hp = chunk;
        limit = chunk + Chunk_size (chunk);
        work = 0;
        caml_fl_wsz_at_phase_change = caml_fl_cur_wsz;
        if (caml_major_gc_hook) (*caml_major_gc_hook)();
      }
        break;
      default: Assert (0);
      }
    }
  }
  gray_vals_cur = gray_vals_ptr;
  current_value = v;
  current_index = start;
  INSTR (CAML_INSTR_INT ("major/mark/slice/fields#", slice_fields);)
  INSTR (CAML_INSTR_INT ("major/mark/slice/pointers#", slice_pointers);)
}

static void sweep_slice (intnat work)
{
  char *hp;
  header_t hd;

  caml_gc_message (0x40, "Sweeping %ld words\n", work);
  while (work > 0){
    if (caml_gc_sweep_hp < limit){
      hp = caml_gc_sweep_hp;
      hd = Hd_hp (hp);
      work -= Whsize_hd (hd);
      caml_gc_sweep_hp += Bhsize_hd (hd);
      switch (Color_hd (hd)){
      case Caml_white:
        if (Tag_hd (hd) == Custom_tag){
          void (*final_fun)(value) = Custom_ops_val(Val_hp(hp))->finalize;
          if (final_fun != NULL) final_fun(Val_hp(hp));
        }
        caml_gc_sweep_hp = (char *) caml_fl_merge_block (Val_hp (hp));
        break;
      case Caml_blue:
        /* Only the blocks of the free-list are blue.  See [freelist.c]. */
        caml_fl_merge = Bp_hp (hp);
        break;
      default:          /* gray or black */
        Assert (Color_hd (hd) == Caml_black);
        Hd_hp (hp) = Whitehd_hd (hd);
        break;
      }
      Assert (caml_gc_sweep_hp <= limit);
    }else{
      chunk = Chunk_next (chunk);
      if (chunk == NULL){
        /* Sweeping is done. */
        ++ caml_stat_major_collections;
        work = 0;
        caml_gc_phase = Phase_idle;
      }else{
        caml_gc_sweep_hp = chunk;
        limit = chunk + Chunk_size (chunk);
      }
    }
  }
}

#ifdef CAML_INSTR
static char *mark_slice_name[] = {
  /* 0 */ NULL,
  /* 1 */ NULL,
  /* 2 */ NULL,
  /* 3 */ NULL,
  /* 4 */ NULL,
  /* 5 */ NULL,
  /* 6 */ NULL,
  /* 7 */ NULL,
  /* 8 */ NULL,
  /* 9 */ NULL,
  /* 10 */  "major/mark_roots",
  /* 11 */  "major/mark_main",
  /* 12 */  "major/mark_weak1",
  /* 13 */  "major/mark_weak2",
  /* 14 */  "major/mark_final",
};
#endif

/* The main entry point for the major GC. Called about once for each
   minor GC. [howmuch] is the amount of work to do:
   -1 if the GC is triggered automatically
   0 to let the GC compute the amount of work
   [n] to make the GC do enough work to (on average) free [n] words
 */
void caml_major_collection_slice (intnat howmuch)
{
  double p, dp, filt_p, spend;
  intnat computed_work;
  int i;
  /*
     Free memory at the start of the GC cycle (garbage + free list) (assumed):
                 FM = caml_stat_heap_wsz * caml_percent_free
                      / (100 + caml_percent_free)

     Assuming steady state and enforcing a constant allocation rate, then
     FM is divided in 2/3 for garbage and 1/3 for free list.
                 G = 2 * FM / 3
     G is also the amount of memory that will be used during this cycle
     (still assuming steady state).

     Proportion of G consumed since the previous slice:
                 PH = caml_allocated_words / G
                    = caml_allocated_words * 3 * (100 + caml_percent_free)
                      / (2 * caml_stat_heap_wsz * caml_percent_free)
     Proportion of extra-heap resources consumed since the previous slice:
                 PE = caml_extra_heap_resources
     Proportion of total work to do in this slice:
                 P  = max (PH, PE)

     Here, we insert a time-based filter on the P variable to avoid large
     latency spikes in the GC, so the P below is a smoothed-out version of
     the P above.

     Amount of marking work for the GC cycle:
                 MW = caml_stat_heap_wsz * 100 / (100 + caml_percent_free)
                      + caml_incremental_roots_count
     Amount of sweeping work for the GC cycle:
                 SW = caml_stat_heap_wsz

     In order to finish marking with a non-empty free list, we will
     use 40% of the time for marking, and 60% for sweeping.

     Let MT be the time spent marking, ST the time spent sweeping, and TT
     the total time for this cycle. We have:
                 MT = 40/100 * TT
                 ST = 60/100 * TT

     Amount of time to spend on this slice:
                 T  = P * TT = P * MT / (40/100) = P * ST / (60/100)

     Since we must do MW work in MT time or SW work in ST time, the amount
     of work for this slice is:
                 MS = P * MW / (40/100)  if marking
                 SS = P * SW / (60/100)  if sweeping

     Amount of marking work for a marking slice:
                 MS = P * MW / (40/100)
                 MS = P * (caml_stat_heap_wsz * 250 / (100 + caml_percent_free)
                           + 2.5 * caml_incremental_roots_count)
     Amount of sweeping work for a sweeping slice:
                 SS = P * SW / (60/100)
                 SS = P * caml_stat_heap_wsz * 5 / 3

     This slice will either mark MS words or sweep SS words.
  */

  if (caml_major_slice_begin_hook != NULL) (*caml_major_slice_begin_hook) ();
  CAML_INSTR_SETUP (tmr, "major");

  p = (double) caml_allocated_words * 3.0 * (100 + caml_percent_free)
      / caml_stat_heap_wsz / caml_percent_free / 2.0;
  if (caml_dependent_size > 0){
    dp = (double) caml_dependent_allocated * (100 + caml_percent_free)
         / caml_dependent_size / caml_percent_free;
  }else{
    dp = 0.0;
  }
  if (p < dp) p = dp;
  if (p < caml_extra_heap_resources) p = caml_extra_heap_resources;
  if (p > 0.3) p = 0.3;
  CAML_INSTR_INT ("major/work/extra#",
                  (uintnat) (caml_extra_heap_resources * 1000000));

  caml_gc_message (0x40, "ordered work = %ld words\n", howmuch);
  caml_gc_message (0x40, "allocated_words = %"
                         ARCH_INTNAT_PRINTF_FORMAT "u\n",
                   caml_allocated_words);
  caml_gc_message (0x40, "extra_heap_resources = %"
                         ARCH_INTNAT_PRINTF_FORMAT "uu\n",
                   (uintnat) (caml_extra_heap_resources * 1000000));
  caml_gc_message (0x40, "raw work-to-do = %"
                         ARCH_INTNAT_PRINTF_FORMAT "du\n",
                   (intnat) (p * 1000000));

  for (i = 0; i < caml_major_window; i++){
    caml_major_ring[i] += p / caml_major_window;
  }

  if (caml_gc_clock >= 1.0){
    caml_gc_clock -= 1.0;
    ++caml_major_ring_index;
    if (caml_major_ring_index >= caml_major_window){
      caml_major_ring_index = 0;
    }
  }
  if (howmuch == -1){
    /* auto-triggered GC slice: spend work credit on the current bucket,
       then do the remaining work, if any */
    /* Note that the minor GC guarantees that the major slice is called in
       automatic mode (with [howmuch] = -1) at least once per clock tick.
       This means we never leave a non-empty bucket behind. */
    spend = fmin (caml_major_work_credit,
                  caml_major_ring[caml_major_ring_index]);
    caml_major_work_credit -= spend;
    filt_p = caml_major_ring[caml_major_ring_index] - spend;
    caml_major_ring[caml_major_ring_index] = 0.0;
  }else{
    /* forced GC slice: do work and add it to the credit */
    if (howmuch == 0){
      /* automatic setting: size of next bucket
         we do not use the current bucket, as it may be empty */
      int i = caml_major_ring_index + 1;
      if (i >= caml_major_window) i = 0;
      filt_p = caml_major_ring[i];
    }else{
      /* manual setting */
      filt_p = (double) howmuch * 3.0 * (100 + caml_percent_free)
               / caml_stat_heap_wsz / caml_percent_free / 2.0;
    }
    caml_major_work_credit += filt_p;
  }

  p = filt_p;

  caml_gc_message (0x40, "filtered work-to-do = %"
                         ARCH_INTNAT_PRINTF_FORMAT "du\n",
                   (intnat) (p * 1000000));

  if (caml_gc_phase == Phase_idle){
    start_cycle ();
    CAML_INSTR_TIME (tmr, "major/roots");
    p = 0;
    goto finished;
  }

  if (p < 0){
    p = 0;
    goto finished;
  }

  if (caml_gc_phase == Phase_mark){
    computed_work = (intnat) (p * (caml_stat_heap_wsz * 250
                                   / (100 + caml_percent_free)
                                   + caml_incremental_roots_count));
  }else{
    computed_work = (intnat) (p * caml_stat_heap_wsz * 5 / 3);
  }
  caml_gc_message (0x40, "computed work = %ld words\n", computed_work);
  if (caml_gc_phase == Phase_mark){
    CAML_INSTR_INT ("major/work/mark#", computed_work);
    mark_slice (computed_work);
    CAML_INSTR_TIME (tmr, mark_slice_name[caml_gc_subphase]);
    caml_gc_message (0x02, "!", 0);
    /*
    remaining_p = remaining_work / (Wsize_bsize (caml_stat_heap_size) * 250
                                    / (100 + caml_percent_free)
                                    + caml_incremental_roots_count);
    */
  }else{
    Assert (caml_gc_phase == Phase_sweep);
    CAML_INSTR_INT ("major/work/sweep#", computed_work);
    sweep_slice (computed_work);
    CAML_INSTR_TIME (tmr, "major/sweep");
    caml_gc_message (0x02, "$", 0);
  }

  if (caml_gc_phase == Phase_idle){
    caml_compact_heap_maybe ();
    CAML_INSTR_TIME (tmr, "major/check_and_compact");
  }

 finished:
  caml_gc_message (0x40, "work-done = %"
                         ARCH_INTNAT_PRINTF_FORMAT "du\n",
                   (intnat) (p * 1000000));

  /* if some of the work was not done, take it back from the credit
     or spread it over the buckets. */
  p = filt_p - p;
  spend = fmin (p, caml_major_work_credit);
  caml_major_work_credit -= spend;
  if (p > spend){
    p -= spend;
    p /= caml_major_window;
    for (i = 0; i < caml_major_window; i++) caml_major_ring[i] += p;
  }

  caml_stat_major_words += caml_allocated_words;
  caml_allocated_words = 0;
  caml_dependent_allocated = 0;
  caml_extra_heap_resources = 0.0;
  if (caml_major_slice_end_hook != NULL) (*caml_major_slice_end_hook) ();
}

/* This does not call [caml_compact_heap_maybe] because the estimates of
   free and live memory are only valid for a cycle done incrementally.
   Besides, this function itself is called by [caml_compact_heap_maybe].
*/
void caml_finish_major_cycle (void)
{
  if (caml_gc_phase == Phase_idle) start_cycle ();
  while (caml_gc_phase == Phase_mark) mark_slice (LONG_MAX);
  Assert (caml_gc_phase == Phase_sweep);
  while (caml_gc_phase == Phase_sweep) sweep_slice (LONG_MAX);
  Assert (caml_gc_phase == Phase_idle);
  caml_stat_major_words += caml_allocated_words;
  caml_allocated_words = 0;
}

/* Call this function to make sure [bsz] is greater than or equal
   to both [Heap_chunk_min] and the current heap increment.
*/
asize_t caml_clip_heap_chunk_wsz (asize_t wsz)
{
  asize_t result = wsz;
  uintnat incr;

  /* Compute the heap increment as a word size. */
  if (caml_major_heap_increment > 1000){
    incr = caml_major_heap_increment;
  }else{
    incr = caml_stat_heap_wsz / 100 * caml_major_heap_increment;
  }

  if (result < incr){
    result = incr;
  }
  if (result < Heap_chunk_min){
    result = Heap_chunk_min;
  }
  return result;
}

/* [heap_size] is a number of bytes */
void caml_init_major_heap (asize_t heap_size)
{
  int i;

  caml_stat_heap_wsz = caml_clip_heap_chunk_wsz (Wsize_bsize (heap_size));
  caml_stat_top_heap_wsz = caml_stat_heap_wsz;
  Assert (Bsize_wsize (caml_stat_heap_wsz) % Page_size == 0);
  caml_heap_start =
    (char *) caml_alloc_for_heap (Bsize_wsize (caml_stat_heap_wsz));
  if (caml_heap_start == NULL)
    caml_fatal_error ("Fatal error: cannot allocate initial major heap.\n");
  Chunk_next (caml_heap_start) = NULL;
  caml_stat_heap_wsz = Wsize_bsize (Chunk_size (caml_heap_start));
  caml_stat_heap_chunks = 1;
  caml_stat_top_heap_wsz = caml_stat_heap_wsz;

  if (caml_page_table_add(In_heap, caml_heap_start,
                          caml_heap_start + Bsize_wsize (caml_stat_heap_wsz))
      != 0) {
    caml_fatal_error ("Fatal error: cannot allocate "
                      "initial page table.\n");
  }

  caml_fl_init_merge ();
  caml_make_free_blocks ((value *) caml_heap_start,
                         caml_stat_heap_wsz, 1, Caml_white);
  caml_gc_phase = Phase_idle;
  gray_vals_size = 2048;
  gray_vals = (value *) malloc (gray_vals_size * sizeof (value));
  if (gray_vals == NULL)
    caml_fatal_error ("Fatal error: not enough memory for the gray cache.\n");
  gray_vals_cur = gray_vals;
  gray_vals_end = gray_vals + gray_vals_size;
  heap_is_pure = 1;
  caml_allocated_words = 0;
  caml_extra_heap_resources = 0.0;
  for (i = 0; i < Max_major_window; i++) caml_major_ring[i] = 0.0;
}

void caml_set_major_window (int w){
  uintnat total = 0;
  int i;
  if (w == caml_major_window) return;
  CAMLassert (w <= Max_major_window);
  /* Collect the current work-to-do from the buckets. */
  for (i = 0; i < caml_major_window; i++){
    total += caml_major_ring[i];
  }
  /* Redistribute to the new buckets. */
  for (i = 0; i < w; i++){
    caml_major_ring[i] = total / w;
  }
  caml_major_window = w;
}
