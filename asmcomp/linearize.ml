(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Transformation of Mach code into a list of pseudo-instructions. *)

open Reg
open Mach

type label = int

let label_counter = ref 99

let phantom_let_labels = ref Numbers.Int.Set.empty

let new_label() = incr label_counter; !label_counter

type instruction =
  { mutable desc: instruction_desc;
    mutable next: instruction;
    arg: Reg.t array;
    res: Reg.t array;
    dbg: Debuginfo.t;
    live: Reg.Set.t;
    mutable available_before: Reg.Set.t;
  }

and instruction_desc =
  | Lprologue
  | Lend
  | Lop of operation
  | Lreloadretaddr
  | Lreturn
  | Llabel of label
  | Lbranch of label
  | Lcondbranch of test * label
  | Lcondbranch3 of label option * label option * label option
  | Lswitch of label array
  | Lsetuptrap of label
  | Lpushtrap
  | Lpoptrap
  | Lraise of Lambda.raise_kind
  | Lcapture_stack_offset of int option ref

let has_fallthrough = function
  | Lreturn | Lbranch _ | Lswitch _ | Lraise _
  | Lop Itailcall_ind | Lop (Itailcall_imm _) -> false
  | _ -> true

(* Ranges of phantom let expressions, used for emitting debugging
   information. *)

type phantom_let_range =
  { starting_label : label;
    ending_label : label;
    ident : Ident.t;
    provenance : Clambda.ulet_provenance;
    defining_expr : Mach.phantom_defining_expr;
  }

(* Indexed by the numeric identifiers on [Iphantom_let_start] and
   [Iphantom_let_end]. *)
let phantom_let_ranges_by_number = ref Numbers.Int.Map.empty
(* Indexed by phantom identifiers. *)
let phantom_let_ranges = ref (Ident.empty : phantom_let_range Ident.tbl)

(* Function declarations *)

type fundecl =
  { fun_name: string;
    fun_body: instruction;
    fun_fast: bool;
    fun_dbg : Debuginfo.t;
    fun_human_name : string;
    fun_arity : int;
    fun_module_path : Path.t option;
    fun_phantom_let_ranges : phantom_let_range Ident.tbl
  }

(* Invert a test *)

let invert_integer_test = function
    Isigned cmp -> Isigned(Cmm.negate_comparison cmp)
  | Iunsigned cmp -> Iunsigned(Cmm.negate_comparison cmp)

let invert_test = function
    Itruetest -> Ifalsetest
  | Ifalsetest -> Itruetest
  | Iinttest(cmp) -> Iinttest(invert_integer_test cmp)
  | Iinttest_imm(cmp, n) -> Iinttest_imm(invert_integer_test cmp, n)
  | Ifloattest(cmp, neg) -> Ifloattest(cmp, not neg)
  | Ieventest -> Ioddtest
  | Ioddtest -> Ieventest

(* The "end" instruction *)

let rec end_instr =
  { desc = Lend;
    next = end_instr;
    arg = [||];
    res = [||];
    dbg = Debuginfo.none;
    live = Reg.Set.empty;
    available_before = Reg.Set.empty; }

(* Cons an instruction (live, debug empty) *)

let instr_cons d a r n ~available_before =
  { desc = d; next = n; arg = a; res = r;
    dbg = Debuginfo.none; live = Reg.Set.empty;
    available_before; }

(* Cons a simple instruction (arg, res, live empty). *)

let cons_instr d n ~available_before =
  { desc = d; next = n; arg = [||]; res = [||];
    dbg = Debuginfo.none; live = Reg.Set.empty;
    available_before; }

(* Like [cons_instr], but takes availability information from the given
   instruction. *)

let cons_instr_same_avail d n =
  cons_instr d n ~available_before:n.available_before

(* Build an instruction with arg, res, dbg, live, available_before taken from
   the given Mach.instruction *)

let copy_instr d i n =
  { desc = d; next = n;
    arg = i.Mach.arg; res = i.Mach.res;
    dbg = i.Mach.dbg; live = i.Mach.live;
    available_before = i.Mach.available_before; }

(*
   Label the beginning of the given instruction sequence.
   - If the sequence starts with a branch, jump over it.
   - If the sequence is the end, (tail call position), just do nothing
*)

let rec skip_phantom_let_labels insn =
  match insn.desc with
  | Llabel lbl when Numbers.Int.Set.mem lbl !phantom_let_labels ->
    skip_phantom_let_labels insn.next
  | _ -> insn

let get_label n =
  match (skip_phantom_let_labels n).desc with
  | Lbranch lbl -> (lbl, n)
  | Llabel lbl -> (lbl, n)
  | Lend -> (-1, n)
  | _ ->
    let lbl = new_label() in
    (lbl, cons_instr_same_avail (Llabel lbl) n)

(* Check the fallthrough label *)
let check_label n = match n.desc with
  | Lbranch lbl -> lbl
  | Llabel lbl -> lbl
  | _ -> -1

(* Discard all instructions, with the exception of certain ones for managing
   available ranges (for debug info generation) up to the next label.
   This function is to be called before adding a non-terminating
   instruction. *)

let discard_dead_code ?map_last_non_dead_insn n =
  let rec discard n ~insns_to_keep_rev =
    match n.desc with
    | Lend
    (* Do not discard Lpoptrap/Lpushtrap or Istackoffset instructions,
       as this may cause a stack imbalance later during assembler generation. *)
    | Lpoptrap | Lpushtrap
    | Lop (Istackoffset _) -> n, insns_to_keep_rev
    | Llabel lbl when not (Numbers.Int.Set.mem lbl !phantom_let_labels) ->
      n, insns_to_keep_rev
    | Llabel _ | Lcapture_stack_offset _ ->
      discard n.next ~insns_to_keep_rev:(n :: insns_to_keep_rev)
    | _ -> discard n.next ~insns_to_keep_rev
  in
  let first_non_dead_insn, insns_to_keep_rev =
    discard n ~insns_to_keep_rev:[]
  in
  let first_non_dead_insn =
    match map_last_non_dead_insn with
    | None -> first_non_dead_insn
    | Some f -> f first_non_dead_insn
  in
  List.fold_left (fun output insn ->
      insn.next <- output;
      insn)
    first_non_dead_insn
    insns_to_keep_rev

(*
   Add a branch in front of a continuation.
   Discard dead code in the continuation.
   Does not insert anything if we're just falling through
   or if we jump to dead code after the end of function (lbl=-1)
*)

let add_branch lbl n ~available_before =
  if lbl >= 0 then
    discard_dead_code n ~map_last_non_dead_insn:(fun n1 ->
      match n1.desc with
      | Llabel lbl1 when lbl1 = lbl -> n1
      | _ -> cons_instr (Lbranch lbl) n1 ~available_before)
  else
    discard_dead_code n

let try_depth = ref 0

(* Association list:
   exit handler -> (handler label, handler avail-before, try-nesting factor) *)

let exit_label = ref []

let find_exit_label_try_depth k =
  try
    List.assoc k !exit_label
  with
  | Not_found -> Misc.fatal_error "Linearize.find_exit_label"

let find_exit_label k =
  let (label, available_before, t) = find_exit_label_try_depth k in
  assert(t = !try_depth);
  label, available_before

let is_next_catch n = match !exit_label with
| (n0,(_,_,t))::_  when n0=n && t = !try_depth -> true
| _ -> false

let local_exit k =
  match find_exit_label_try_depth k with
  | _, _, depth -> depth = !try_depth

(* Linearize an instruction [i]: add it in front of the continuation [n] *)

let rec linear i n =
  match i.Mach.desc with
    Iend -> n
  | Iop(Itailcall_ind | Itailcall_imm _ as op) ->
      copy_instr (Lop op) i (discard_dead_code n)
  | Iop(Imove | Ireload | Ispill)
    (* CR mshinwell: use function in Reg *)
    when i.Mach.arg.(0).shared.loc = i.Mach.res.(0).shared.loc ->
      (* The move may represent only a change in register naming: we
         preserve this by ensuring the target of the deleted move is
         in the available-before set of [i.Mach.next]. *)
      i.Mach.next.Mach.available_before
        <- Reg.Set.add i.Mach.res.(0) i.Mach.next.Mach.available_before;
      (* Make sure we don't lose [is_parameter]. *)
      i.Mach.res.(0).shared.is_parameter <- i.Mach.arg.(0).shared.is_parameter;
      linear i.Mach.next n
  | Iop op ->
      copy_instr (Lop op) i (linear i.Mach.next n)
  | Ireturn ->
      let n1 =
        copy_instr Lreturn i (discard_dead_code (linear i.Mach.next n))
      in
      if !Proc.contains_calls
      then cons_instr_same_avail Lreloadretaddr n1
      else n1
  | Iifthenelse(test, ifso, ifnot) ->
      let n1 = linear i.Mach.next n in
      begin match (ifso.Mach.desc, ifnot.Mach.desc, n1.desc) with
        Iend, _, Lbranch lbl ->
          copy_instr (Lcondbranch(test, lbl)) i (linear ifnot n1)
      | _, Iend, Lbranch lbl ->
          copy_instr (Lcondbranch(invert_test test, lbl)) i (linear ifso n1)
      | Iexit nfail1, Iexit nfail2, _
            when is_next_catch nfail1 && local_exit nfail2 ->
          let lbl2, _ = find_exit_label nfail2 in
          copy_instr
            (Lcondbranch (invert_test test, lbl2)) i (linear ifso n1)
      | Iexit nfail, _, _ when local_exit nfail ->
          let n2 = linear ifnot n1
          and lbl, _ = find_exit_label nfail in
          copy_instr (Lcondbranch(test, lbl)) i n2
      | _,  Iexit nfail, _ when local_exit nfail ->
          let n2 = linear ifso n1 in
          let lbl, _ = find_exit_label nfail in
          copy_instr (Lcondbranch(invert_test test, lbl)) i n2
      | Iend, _, _ ->
          let (lbl_end, n2) = get_label n1 in
          copy_instr (Lcondbranch(test, lbl_end)) i (linear ifnot n2)
      | _,  Iend, _ ->
          let (lbl_end, n2) = get_label n1 in
          copy_instr (Lcondbranch(invert_test test, lbl_end)) i
                     (linear ifso n2)
      | _, _, _ ->
        (* Should attempt branch prediction here *)
          let (lbl_end, n2) = get_label n1 in
          let (lbl_else, nelse) = get_label (linear ifnot n2) in
          copy_instr (Lcondbranch(invert_test test, lbl_else)) i
            (linear ifso (add_branch lbl_end nelse
              ~available_before:n2.available_before))
      end
  | Iswitch(index, cases) ->
      let lbl_cases = Array.make (Array.length cases) 0 in
      let (lbl_end, n1) = get_label(linear i.Mach.next n) in
      let n2 = ref (discard_dead_code n1) in
      for i = Array.length cases - 1 downto 0 do
        let (lbl_case, ncase) =
          get_label (linear cases.(i)
            (add_branch lbl_end !n2 ~available_before:n1.available_before))
        in
        lbl_cases.(i) <- lbl_case;
        n2 := discard_dead_code ncase
      done;
      (* Switches with 1 and 2 branches have been eliminated earlier.
         Here, we do something for switches with 3 branches. *)
      if Array.length index = 3 then begin
        let fallthrough_lbl = check_label !n2 in
        let find_label n =
          let lbl = lbl_cases.(index.(n)) in
          if lbl = fallthrough_lbl then None else Some lbl in
        copy_instr (Lcondbranch3(find_label 0, find_label 1, find_label 2))
                   i !n2
      end else
        copy_instr (Lswitch(Array.map (fun n -> lbl_cases.(n)) index)) i !n2
  | Iloop body ->
      let lbl_head = new_label() in
      let n1 = linear i.Mach.next n in
      let n2 =
        linear body (cons_instr (Lbranch lbl_head) n1
          ~available_before:i.Mach.available_before)
      in
      cons_instr_same_avail (Llabel lbl_head) n2
  | Icatch(io, body, handler) ->
      let (lbl_end, n1) = get_label(linear i.Mach.next n) in
      let (lbl_handler, n2) = get_label(linear handler n1) in
      let avail = n2.available_before in
      exit_label := (io, (lbl_handler, avail, !try_depth)) :: !exit_label ;
      let n3 =
        linear body (add_branch lbl_end n2
          ~available_before:n1.available_before)
      in
      exit_label := List.tl !exit_label;
      n3
  | Iexit nfail ->
      let lbl, available_before, t = find_exit_label_try_depth nfail in
      (* We need to re-insert dummy pushtrap (which won't be executed),
         so as to preserve stack offset during assembler generation.
         It would make sense to have a special pseudo-instruction
         only to inform the later pass about this stack offset
         (corresponding to N traps).
       *)
      let rec loop i tt =
        if t = tt then i
        else loop (cons_instr_same_avail Lpushtrap i) (tt - 1)
      in
      let n1 = loop (linear i.Mach.next n) !try_depth in
      let rec loop i tt =
        if t = tt then i
        else loop (cons_instr_same_avail Lpoptrap i) (tt - 1)
      in
      loop (add_branch lbl n1 ~available_before) !try_depth
  | Itrywith(body, handler) ->
      let (lbl_join, n1) = get_label (linear i.Mach.next n) in
      incr try_depth;
      let (lbl_body, n2) =
        get_label (cons_instr_same_avail Lpushtrap
                    (linear body (cons_instr_same_avail Lpoptrap n1))) in
      decr try_depth;
      cons_instr_same_avail (Lsetuptrap lbl_body)
        (linear handler (add_branch lbl_join n2
          ~available_before:n1.available_before))
  | Iraise k ->
      copy_instr (Lraise k) i (discard_dead_code n)
  | Iphantom_let_start (num, ident, provenance, defining_expr) ->
      let starting_label = new_label () in
      phantom_let_labels :=
        Numbers.Int.Set.add starting_label !phantom_let_labels;
      assert (not (Numbers.Int.Map.mem num !phantom_let_ranges_by_number));
      phantom_let_ranges_by_number :=
        Numbers.Int.Map.add num
          (starting_label, ident, provenance, defining_expr)
          !phantom_let_ranges_by_number;
      copy_instr (Llabel starting_label) i (linear i.Mach.next n)
  | Iphantom_let_end num ->
      begin match Numbers.Int.Map.find num !phantom_let_ranges_by_number with
      | (starting_label, ident, provenance, defining_expr) ->
          let ending_label = new_label () in
          let phantom_let_range =
            { starting_label;
              ending_label;
              ident;
              provenance;
              defining_expr;
            }
          in
(*
          assert (not (Ident.mem ident !phantom_let_ranges));*)
          phantom_let_labels :=
            Numbers.Int.Set.add ending_label !phantom_let_labels;
          phantom_let_ranges :=
            Ident.add ident phantom_let_range !phantom_let_ranges;
          copy_instr (Llabel ending_label) i (linear i.Mach.next n)
      | exception Not_found -> assert false
      end

(* CR-soon mshinwell: this is misleading---never called.
   It also cannot be called between functions or you end up with
   duplicate labels. *)
let reset () =
  label_counter := 99;
  exit_label := []

let reset_between_functions () =
  phantom_let_ranges := Ident.empty;
  phantom_let_ranges_by_number := Numbers.Int.Map.empty;
  phantom_let_labels := Numbers.Int.Set.empty

let add_prologue first_insn =
  { desc = Lprologue;
    next = first_insn;
    arg = [| |];
    res = [| |];
    dbg = first_insn.dbg;
    live = first_insn.live;
    available_before = first_insn.available_before;
  }

let fundecl f =
  let fun_body = add_prologue (linear f.Mach.fun_body end_instr) in
  let fun_phantom_let_ranges = !phantom_let_ranges in
  { fun_name = f.Mach.fun_name;
    fun_body;
    fun_fast = f.Mach.fun_fast;
    fun_dbg  = f.Mach.fun_dbg;
    fun_human_name = f.Mach.fun_human_name;
    fun_arity = Array.length f.Mach.fun_args;
    fun_module_path = f.Mach.fun_module_path;
    fun_phantom_let_ranges;
  }
