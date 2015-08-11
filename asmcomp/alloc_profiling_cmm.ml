(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2015, Jane Street Group, LLC                             *)
(*                                                                     *)
(*  Licensed under the Apache License, Version 2.0 (the "License");    *)
(*  you may not use this file except in compliance with the License.   *)
(*  You may obtain a copy of the License at                            *)
(*                                                                     *)
(*      http://www.apache.org/licenses/LICENSE-2.0                     *)
(*                                                                     *)
(*  Unless required by applicable law or agreed to in writing,         *)
(*  software distributed under the License is distributed on an        *)
(*  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,       *)
(*  either express or implied.  See the License for the specific       *)
(*  language governing permissions and limitations under the License.  *)
(*                                                                     *)
(***********************************************************************)

let index_within_node = ref 0
let alloc_profiling_node = ref (Cvar (Ident.create "dummy"))
let alloc_profiling_node_ident = ref (Ident.create "dummy")
let direct_calls = Hashtbl.create 42

let reset ~alloc_profiling_node_ident:ident =
  index_within_node := 0;
  alloc_profiling_node := Cvar ident;
  alloc_profiling_node_ident = ref ident;
  Hashtbl.clear direct_calls

let code_to_allocate_trie_node ~max_index_within_node =
  let header =
    Cmmgen.black_block_header Obj.first_non_constant_constructor_tag size
  in
  let open Cmm in
  Cop (Cextcall ("caml_allocation_profiling_allocate_node", [| Int |],
      false, Debuginfo.none),
    [Cconst_int (2 + max_index_within_node);
     Cconst_natint header;
    ])

let code_for_function_prologue ~node ~max_index_within_node =
  let node_hole = Ident.create "node_hole" in
  let new_node = Ident.create "new_node" in
  let open Cmm in
  Clet (node_hole, Cop (Calloc_profiling_node_hole, []),
    Clet (node, Cop (Cload Word, [Cvar node_hole]),
      Cifthenelse (Cop (Ccmpi Cne, [Cvar node; Cconst_int 1]),
        Cvar node,
        Clet (new_node,
          code_to_allocate_trie_node ~max_index_within_node,
          Csequence (
            Cop (Cstore Word, [Cvar node_hole; Cvar new_node]),
            Cvar new_node)))))

let code_for_allocation_point ~value's_header ~node =
  let existing_profinfo = Ident.create "existing_profinfo" in
  let profinfo = Ident.create "profinfo" in
  let pc = Ident.create "pc" in
  let address_of_profinfo = Ident.create "address_of_profinfo" in
  let offset_into_node = Arch.size_addr * !index_within_node in
  incr index_within_node;
  let open Cmm in
  let generate_new_profinfo =
    (* This will generate a static branch to a function that should usually
       be in the cache, which hopefully gives a good code size/performance
       balance. *)
    Clet (pc, Cop (Cor, [
        Cop (Clsl, [Cop (Cprogram_counter, []); Cconst_int 2]);
        Cconst_int 1]),
      Cop (Cextcall ("caml_alloc_profiling_generate_profinfo", [| Int |],
          false, Debuginfo.none),
        [Cvar pc; Cvar address_of_profinfo]))
  in
  (* Check if we have already allocated a profinfo value for this allocation
     point with the current backtrace.  If so, use that value; if not,
     allocate a new one. *)
  Clet (address_of_profinfo,
    begin if offset_into_node <> 0 then
      Cop (Cadda, [
        Cvar node;
        Cconst_int offset_into_node;
      ])
    else
      Cvar node
    end,
    Clet (existing_profinfo, Cop (Cload Word, [Cvar address_of_profinfo]),
      Clet (profinfo,
        Cifthenelse (
          Cop (Ccmpa Cne, [Cvar existing_profinfo; Cconst_pointer 1]),
          Cvar existing_profinfo,
          generate_new_profinfo),
        (* [profinfo] is already shifted by [PROFINFO_SHIFT]. *)
        Cop (Cor, [Cvar profinfo; Cconst_natint value's_header]))))

type callee =
  | Direct of string
  | Indirect of Cmm.expression

let code_for_call ~node ~index_within_node ~callee ~is_tail =
  let open Cmm in
  let place_within_node = Ident.create "place_within_node" in
  Clet (place_within_node,
    begin if index_within_node = 0 then
      node
    else
      Cop (Caddi, [
        node;
        Cconst_int (index_within_node * Arch.size_addr);
      ])
    end,
    match callee with
    | Direct callee ->
      let callee_addr =
        Cop (Cor, [Cop (Clsl, [Cconst_symbol callee; Cconst_int 2]);
          Cconst_int 3])
      in
      if not is_tail then
        Csequence (
          Cop (Cstore Word, [Cvar place_within_node; callee_addr]),
          Cop (Calloc_profiling_load_node_hole_ptr, [
            Cop (Caddi, [Cvar place_within_node; Cconst_int Arch.size_addr])
          ]))
      else
        Csequence (
          Cop (Cstore Word, [Cvar place_within_node; callee_addr]),
          Clet (node_hole,
            Cop (Caddi, [Cvar place_within_node; Cconst_int Arch.size_addr]),
            Csequence (
              (* For tail calls, we write a pointer back to the current node
                 into the relevant entry of that same node, and then proceed as
                 usual.  The prologue of the function being tail called will
                 then re-use the same node. *)
              Cop (Cstore Word, [Cvar node_hole; node]),
              Cop (Calloc_profiling_load_node_hole_ptr, [Cvar node_hole]))))
    | Indirect callee ->
      let node_hole_ptr = Ident.create "node_hole_ptr" in
      Clet (node_hole_ptr,
        Cop (Cextcall ("caml_allocation_profiling_indirect_node_hole_ptr",
          [callee; Cvar place_within_node]))))

class instruction_selection = object (self)
  inherit Selectgen.selector_generic as super

  method private instrument_direct_call ~lbl ~is_tail =
    let call_point_index =
      match Hashtbl.find direct_calls lbl with
      | index -> index
      | exception Not_found ->
        let index = !next_call_point_index in
        incr next_call_point_index;
        Hashtbl.add direct_calls lbl index;
        index
    in
    let instrumentation =
      Alloc_profiling_cmm.code_for_call
        ~node:!alloc_profiling_node
        ~callee:(Alloc_profiling_cmm.Direct lbl)
        ~is_tail
        ~call_point_index:!index_within_node
    in
    incr index_within_node;
    ignore (self#emit_expr env instrumentation)

  method private instrument_indirect_call ~callee ~is_tail =
    let call_point_index =
      let index = !next_call_point_index in
      incr next_call_point_index;
      index
    in
    let callee_ident = Ident.create "callee" in
    let callee_expr = Cmm.Cvar callee_ident in
    let instrumentation =
      Alloc_profiling_cmm.code_for_call
        ~node:!alloc_profiling_node
        ~callee:(Alloc_profiling_cmm.Indirect callee_expr)
        ~is_tail
        ~call_point_index:!index_within_node
    in
    incr index_within_node;
    let env = Tbl.add callee_ident callee env in
    ignore (self#emit_expr env instrumentation)

  method private maybe_instrument desc ~arg ~res =
    match desc with
    | Iop (Icall_imm lbl) ->
      self#instrument_direct_call ~callee:(Direct lbl) ~is_tail:false
    | Iop Icall_self#ind ->
      self#instrument_indirect_call ~callee:(Indirect arg.(0)) ~is_tail:false
    | Iop (Itaself#ilcall_imm lbl) ->
      self#instrument_direct_call ~callee:(Direct lbl) ~is_tail:true
    | Iop Itaself#ilcall_ind ->
      self#instrument_indirect_call ~callee:(Indirect arg.(0)) ~is_tail:true
    | Iop (Iextcall lbl) ->
      self#instrument_direct_call ~callee:(Direct lbl) ~is_tail:false
    | _ -> ()

  method private emit_prologue f ~env_after_main_prologue
        ~last_insn_of_main_prologue =
    if !Clflags.allocation_profiling then begin
      let needs_prologue =
        true
      in
      if needs_prologue then begin
        let prologue_cmm =
          Alloc_profiling_cmm.code_for_function_prologue
            ~num_instrumented_alloc_points:!num_instrumented_alloc_points
            ~num_direct_call_points:!next_direct_call_point_index
        in
        (* Splice the allocation prologue after the main prologue but before the
           function body.  Remember that [instr_seq] points at the last
           instruction (the list is in reverse order). *)
        let last_insn_of_body = instr_seq in
        let first_insn_of_body = ref dummy_instr in
        while not (instr_seq == last_insn_of_main_prologue) do
          first_insn_of_body := instr_seq;
          instr_seq <- instr_seq.next
        done;
        instr_seq <- last_insn_of_main_prologue;
        let node_temp_reg =
          match self#emit_expr env_after_main_prologue prologue_cmm with
          | None ->
            Misc.fatal_error "Alloc_profiling prologue instruction \
                selection did not yield a destination register"
          | Some node_temp_reg -> node_temp_reg
        in
        let node_reg = Tbl.find node env_after_main_prologue in
        self#insert_moves node_temp_reg node_reg;
        if not (!first_insn_of_body == dummy_instr) then begin
          (!first_insn_of_body).next <- instr_seq;
          instr_seq <- last_insn_of_body
        end
      end
    end

  method! insert_debug desc dbg arg res =
    if !Clflags.allocation_profiling then maybe_instrument desc ~arg ~res;
    super#insert_debug desc dbg arg res

  method! insert desc arg res =
    if !Clflags.allocation_profiling then maybe_instrument desc ~arg ~res;
    super#insert desc dbg arg res

  method! initial_env () =
    if !Clflags.allocation_profiling then
      Tbl.add !alloc_profiling_node_ident (self#regs_for typ_int) Tbl.empty
    else
      Tbl.empty

  method! emit_fundecl f =
    if !Clflags.allocation_profiling then begin
      reset ~alloc_profiling_node_ident:f.Cmm.fun_alloc_profiling_node
    in
    super#emit_fundecl f

  method! after_body f ~env_after_prologue ~last_insn_of_prologue =
    if !Clflags.allocation_profiling then begin
      self#emit_prologue f ~env_after_main_prologue:env_after_prologue
        ~last_insn_of_main_prologue:last_insn_of_prologue
    else
      ()
end
