(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2013--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Std_internal

(* DWARF-4 standard section 6.1.2. *)

type t = {
  size : Int64.t;
  values : Dwarf_value.t list;
}

let create ~start_of_code_symbol ~end_of_code_symbol
      ~debug_info_label =
  let module V = Dwarf_value in
  let values = [
    (* The initial length is inserted here by the code below. *)
    V.Int16 (Int16.of_int_exn 2);  (* section version number *)
    (* N.B. The following offset is to the compilation unit *header*, not
       the compilation unit DIE. *)
    V.Offset_into_debug_info debug_info_label;
    V.Int8 (Int8.of_int_exn Arch.size_addr);
    V.Int8 Int8.zero;  (* flat address space *)
    (* end of header *)
    V.Code_address_from_symbol start_of_code_symbol;
    V.Code_address_from_symbol_diff
      { upper = end_of_code_symbol; lower = start_of_code_symbol; };
    V.Absolute_code_address Target_addr.zero;
    V.Absolute_code_address Target_addr.zero;
  ]
  in
  let size =
    List.fold_left values
      ~init:Int64.zero
      ~f:(fun size value -> Int64.add size (V.size value))
  in
  { size; values; }

let size t = t.size

let emit t asm =
  Initial_length.emit (Initial_length.create t.size) asm;
  List.iter t.values ~f:(fun v -> Dwarf_value.emit v asm)