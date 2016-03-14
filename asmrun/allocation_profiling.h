/***********************************************************************/
/*                                                                     */
/*                               OCaml                                 */
/*                                                                     */
/*           Mark Shinwell and Leo White, Jane Street Europe           */
/*                                                                     */
/*  Copyright 2013--2015, Jane Street Group, LLC                       */
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

typedef enum {
  CALL,
  ALLOCATION
} c_node_type;

/* Layout of static nodes:

   OCaml GC header with tag zero
   Tail call words:
   1. PC value at the start of the function corresponding to this node,
      shifted left by 1, with bottom bit then set.
   2. Pointer forming a cyclic list through the nodes involved in any tail
      call chain.
   A sequence of:
   - An allocation point (two words):
     1. PC value, shifted left by 2, with bottom bit then set.  Bit 1 being
        clear enables allocation points to be distinguished from call points.
     2. Profinfo value [that gets written into the value's header]
   - A direct OCaml -> OCaml call point (three words):
     1. Call site PC value, shifted left by 2, with bits 0 and 1 then set
     2. Callee's PC value, shifted left by 2, with bit 0 set
     3. Pointer to callee's node, which will always be a static node.
   - An indirect OCaml -> OCaml call point (two words):
     1. Call site PC value, shifted left by 2, with bits 0 and 1 then set
     2. Pointer to dynamic node.  Note that this dynamic node is really
        part of the static node that points to it.  This pointer not having
        its bottom bit set enables it to be distinguished from the second word
        of a direct call point.  The dynamic node will only contain CALL
        entries, pointing at the callee(s).
   XXX what about indirect OCaml -> C?  Same as indirect OCaml -> OCaml.
   - A direct OCaml -> C call point (three words):
     1. Call site PC value, shifted left by 2, with bits 0 and 1 then set
     2. Callee's PC value, shifted left by 2, with bit 0 set
     3. Pointer to callee's node, which will always be a dynamic node.

   All pointers between nodes point at the word immediately after the
   GC headers, and everything is traversable using the normal OCaml rules.
   Any direct call entries for tail calls must come before any other call
   point or allocation point words.  This is to make them easier to
   initialize.

   Layout of dynamic nodes, which consist of >= 1 part(s) in a linked list:

   OCaml GC header with tag one
   PC value, shifted left by 2, with bottom bit then set.  Bit 1 then
   indicates:
     - bit 1 set => this is a call point
     - bit 1 clear => this is an allocation point
   XXX this next part is wrong for indirect dynamic nodes.  They have
   the callee address.
   The PC is either the PC of an allocation point or a *call site*, never the
     address of a callee.  This means that more conflation between nodes may
     occur than for OCaml parts of the trie.  This can be recovered afterwards
     by checking which function every PC value inside a C node corresponds to,
     and making more trie nodes if required.
   Pointer to callee's node (for a call point), or profinfo value.
   Pointer to the next part of the current node in the linked list, or
     [Val_unit] if this is the last part.

   On entry to an OCaml function:
   If the node hole pointer register has the bottom bit set, then the function
   is being tail called:
   - If the node hole is empty, the callee must create a new node and link
     it into the tail chain.  The node hole pointer will point at the tail
     chain.
   - Otherwise the node should be used as normal.
   Otherwise (not a tail call):
   - If the node hole is empty, the callee must create a new node, but the
     tail chain is untouched.
   - Otherwise the node should be used as normal.
*/

/* Classification of nodes (OCaml or C) with corresponding GC tags. */
#define OCaml_node_tag 0
#define C_node_tag 1
#define Is_ocaml_node(node) (Is_block(node) && Tag_val(node) == OCaml_node_tag)
#define Is_c_node(node) (Is_block(node) && Tag_val(node) == C_node_tag)

/* The header words are:
   1. The node program counter.
   2. The tail link. */
#define Node_num_header_words 2

/* The "node program counter" at the start of an OCaml node. */
#define Node_pc(node) (Field(node, 0))
#define Encode_node_pc(pc) (((value) pc) | 1)
#define Decode_node_pc(encoded_pc) ((void*) (encoded_pc & ~1))

/* The circular linked list of tail-called functions within OCaml nodes. */
#define Tail_link(node) (Field(node, 1))

/* The convention for pointers from OCaml nodes to other nodes.  There are
   two special cases:
   1. [Val_unit] means "uninitialized", and further, that this is not a
      tail call point.  (Tail call points are pre-initialized, as in case 2.)
   2. If the bottom bit is set, and the value is not [Val_unit], this is a
      tail call point. */
#define Encode_tail_caller_node(node) ((node) | 1)
#define Decode_tail_caller_node(node) ((node) & ~1)
#define Is_tail_caller_node_encoded(node) (((node) & 1) == 1)

/* Classification as to whether an encoded PC value at the start of a group
   of words within a node is either:
   (a) a direct or an indirect call point; or
   (b) an allocation point. */
#define Call_or_allocation_point(node, offset) \
  (((Field(node, offset) & 3) == 1) ? ALLOCATION : CALL)

/* Allocation points within OCaml nodes. */
#define Encode_alloc_point_pc(pc) ((((value) pc) << 2) | 1)
#define Decode_alloc_point_pc(pc) ((void*) (((value) pc) >> 2))
#define Encode_alloc_point_profinfo(profinfo) (Val_long(profinfo))
#define Decode_alloc_point_profinfo(profinfo) (Long_val(profinfo))
#define Alloc_point_pc(node, offset) (Field(node, offset))
#define Alloc_point_profinfo(node, offset) (Field(node, (offset) + 1))

/* Direct call points (tail or non-tail) within OCaml nodes.
   They hold the PC of the call site, the PC upon entry to the callee and
   a pointer to the child node. */
#define Direct_num_fields 3
#define Direct_pc_call_site(node,offset) (Field(node, offset))
#define Direct_pc_callee(node,offset) (Field(node, (offset) + 1))
#define Direct_callee_node(node,offset) (Field(node, (offset) + 2))
/* The following two are used for indirect call points too. */
#define Encode_call_point_pc(pc) ((((value) pc) << 2) | 3)
#define Decode_call_point_pc(pc) ((void*) (((value) pc) >> 2))

/* Indirect call points (tail or non-tail) within OCaml nodes.
   They hold the PC of the call site and a linked list of (PC upon entry
   to the callee, pointer to child node) pairs.  The linked list is encoded
   using C nodes and should be thought of as part of the OCaml node itself. */
#define Indirect_num_fields 2
#define Indirect_pc_call_site(node,offset) (Field(node, offset))
#define Indirect_pc_linked_list(node,offset) (Field(node, (offset) + 1))

/* Encodings of the program counter value within a C node. */
#define Encode_c_node_pc_for_call(pc) ((((value) pc) << 2) | 3)
#define Encode_c_node_pc_for_alloc_point(pc) ((((value) pc) << 2) | 1)
#define Decode_c_node_pc(pc) ((void*) ((pc) >> 2))

typedef struct {
  uintnat gc_header;
  uintnat pc;           /* always has bit 0 set.  Bit 1 set => CALL. */
  union {
    value callee_node;  /* for CALL */
    value profinfo;   /* for ALLOCATION (encoded with [Val_long])*/
  } data;
  value next;           /* [Val_unit] for the end of the list */
} c_node; /* CR mshinwell: rename to dynamic_node */

extern value* caml_alloc_profiling_trie_node_ptr;
extern value* caml_alloc_profiling_finaliser_trie_root;

extern const uintnat caml_profinfo_lowest;
extern void caml_allocation_profiling_initialize(void);
extern uintnat caml_allocation_profiling_my_profinfo(void);
extern void caml_allocation_profiling_register_dynamic_library(
  const char* filename, void* address_of_code_begin);
extern c_node_type caml_allocation_profiling_classify_c_node(c_node* node);
extern c_node* caml_allocation_profiling_c_node_of_stored_pointer(
  value node_stored);
extern c_node* caml_allocation_profiling_c_node_of_stored_pointer_not_null(
  value node_stored);
extern value caml_allocation_profiling_stored_pointer_of_c_node(
  c_node* node);
extern value caml_allocation_profiling_min_override_profinfo (value v_unit);
extern value caml_allocation_profiling_max_override_profinfo (value v_unit);
extern void caml_allocation_profiling_register_thread(
  value* trie_node_root, value* finaliser_trie_node_root);
