/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* Machine-dependent interface with the asm code */

#ifndef CAML_STACK_H
#define CAML_STACK_H

#ifdef CAML_INTERNALS

/* Macros to access the stack frame */

#ifdef TARGET_sparc
#define Saved_return_address(sp) *((intnat *)((sp) + 92))
#define Callback_link(sp) ((struct caml_context *)((sp) + 104))
#endif

#ifdef TARGET_i386
#define Saved_return_address(sp) *((intnat *)((sp) - 4))
#ifndef SYS_win32
#define Callback_link(sp) ((struct caml_context *)((sp) + 16))
#else
#define Callback_link(sp) ((struct caml_context *)((sp) + 8))
#endif
#endif

#ifdef TARGET_power
#if defined(MODEL_ppc)
#define Saved_return_address(sp) *((intnat *)((sp) - 4))
#define Callback_link(sp) ((struct caml_context *)((sp) + 16))
#elif defined(MODEL_ppc64)
#define Saved_return_address(sp) *((intnat *)((sp) + 16))
#define Callback_link(sp) ((struct caml_context *)((sp) + (48 + 32)))
#elif defined(MODEL_ppc64le)
#define Saved_return_address(sp) *((intnat *)((sp) + 16))
#define Callback_link(sp) ((struct caml_context *)((sp) + (32 + 32)))
#else
#error "TARGET_power: wrong MODEL"
#endif
#define Already_scanned(sp, retaddr) ((retaddr) & 1)
#define Mask_already_scanned(retaddr) ((retaddr) & ~1)
#define Mark_scanned(sp, retaddr) Saved_return_address(sp) = (retaddr) | 1
#endif

#ifdef TARGET_s390x
#define Saved_return_address(sp) *((intnat *)((sp) - SIZEOF_PTR))
#define Trap_frame_size 16
#define Callback_link(sp) ((struct caml_context *)((sp) + Trap_frame_size))
#endif

#ifdef TARGET_arm
#define Saved_return_address(sp) *((intnat *)((sp) - 4))
#define Callback_link(sp) ((struct caml_context *)((sp) + 8))
#endif

#ifdef TARGET_amd64
#define Saved_return_address(sp) *((intnat *)((sp) - 8))
#define Callback_link(sp) ((struct caml_context *)((sp) + 16))
#endif

#ifdef TARGET_arm64
#define Saved_return_address(sp) *((intnat *)((sp) - 8))
#define Callback_link(sp) ((struct caml_context *)((sp) + 16))
#endif

/* Structure of OCaml callback contexts */

struct caml_context {
  char * bottom_of_stack;       /* beginning of OCaml stack chunk */
  uintnat last_retaddr;         /* last return address in OCaml code */
  value * gc_regs;              /* pointer to register block */
#ifdef WITH_SPACETIME
  void* trie_node;
#endif
};

/* Structure of frame descriptors */

typedef struct {
  uintnat retaddr;
  unsigned short frame_size;
  unsigned short num_live;
  unsigned short live_ofs[1];
} frame_descr;

/* Hash table of frame descriptors */

extern frame_descr ** caml_frame_descriptors;
extern int caml_frame_descriptors_mask;

#define Hash_retaddr(addr) \
  (((uintnat)(addr) >> 3) & caml_frame_descriptors_mask)

extern void caml_init_frame_descriptors(void);
extern void caml_register_frametable(intnat *);
extern void caml_unregister_frametable(intnat *);
extern void caml_register_dyn_global(void *);

extern uintnat caml_stack_usage (void);
extern uintnat (*caml_stack_usage_hook)(void);

/* Declaration of variables used in the asm code */
extern char * caml_top_of_stack;
extern char * caml_bottom_of_stack;
extern uintnat caml_last_return_address;
extern value * caml_gc_regs;
extern char * caml_exception_pointer;
extern value * caml_globals[];
extern char caml_globals_map[];
extern intnat caml_globals_inited;
extern intnat * caml_frametable[];

/* Size of the stack in bytes for the current thread.  There are two
   special values:

    0 => this is the main thread, whose size may be dynamic.
    -1 => stack size unknown (and it's not the main thread)
*/
extern size_t caml_stack_size;

CAMLextern frame_descr * caml_next_frame_descriptor(uintnat * pc, char ** sp);

#endif /* CAML_INTERNALS */

#endif /* CAML_STACK_H */
