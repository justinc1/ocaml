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

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

open Std_internal

module Location_list_entry = struct
  type t = {
    start_of_code_symbol : Symbol.t;
    beginning_address_label : Linearize.label;
    ending_address_label : Linearize.label;
    expr : Location_expression.t;
  }

  let create ~start_of_code_symbol
             ~first_address_when_in_scope
             ~first_address_when_not_in_scope
             ~location_expression =
    { start_of_code_symbol;
      beginning_address_label = first_address_when_in_scope;
      ending_address_label = first_address_when_not_in_scope;
      expr = location_expression;
    }

  let expr_size t =
    let size = Location_expression.size t.expr in
    (* CR-someday mshinwell: maybe this size should be unsigned? *)
    assert (Int64.compare size 0xFFFFL < 0);
    Int16.of_int64_exn size

  let beginning_value t =
    Dwarf_value.Code_address_from_label_symbol_diff
      { upper = t.beginning_address_label;
        lower = t.start_of_code_symbol;
        offset_upper = 0;
      }

  let ending_value t =
    Dwarf_value.Code_address_from_label_symbol_diff
      { upper = t.ending_address_label;
        lower = t.start_of_code_symbol;
        (* It seems as if this should be "-1", but actually not.
           DWARF-4 spec p.30 (point 2):
           "...the first address past the end of the address range over
            which the location is valid." *)
        offset_upper = 0;
      }

  let size t =
    let v1 = beginning_value t in
    let v2 = ending_value t in
    let v3 = Dwarf_value.Int16 (expr_size t) in
    let (+) = Int64.add in
    Dwarf_value.size v1 + Dwarf_value.size v2 + Dwarf_value.size v3
      + Location_expression.size t.expr

  let emit t asm =
    let module A = (val asm : Asm_directives.S) in
    Dwarf_value.emit (beginning_value t) asm;
    Dwarf_value.emit (ending_value t) asm;
    A.int16 (expr_size t);
    Location_expression.emit t.expr asm
end

module Base_address_selection_entry = struct
  type t = Symbol.t

  let create ~base_address_symbol = base_address_symbol

  let to_dwarf_values t =
    [Dwarf_value.Absolute_code_address Target_addr.highest;
     Dwarf_value.Code_address_from_symbol t;
    ]

  let size t =
    List.fold (to_dwarf_values t)
      ~init:Int64.zero
      ~f:(fun acc v -> Int64.add acc (Dwarf_value.size v))

  let emit t asm =
    List.iter (to_dwarf_values t) ~f:(fun v -> Dwarf_value.emit v asm)
end

type t =
  | Location_list_entry of Location_list_entry.t
  | Base_address_selection_entry of Base_address_selection_entry.t

let create_location_list_entry ~start_of_code_symbol
                               ~first_address_when_in_scope
                               ~first_address_when_not_in_scope
                               ~location_expression =
  Location_list_entry (
    Location_list_entry.create ~start_of_code_symbol
      ~first_address_when_in_scope
      ~first_address_when_not_in_scope
      ~location_expression)

let create_base_address_selection_entry ~base_address_symbol =
  Base_address_selection_entry (
    Base_address_selection_entry.create ~base_address_symbol)

let size = function
  | Location_list_entry entry ->
    Location_list_entry.size entry
  | Base_address_selection_entry entry ->
    Base_address_selection_entry.size entry

let emit t asm =
  match t with
  | Location_list_entry entry ->
    Location_list_entry.emit entry asm
  | Base_address_selection_entry entry ->
    Base_address_selection_entry.emit entry asm

let compare_ascending_vma t1 t2 =
  (* This relies on a certain ordering on labels.  See available_ranges.mli. *)
  match t1, t2 with
  | Base_address_selection_entry _, Base_address_selection_entry _ ->
    failwith "Location_list_entry.compare_ascending_vma: unsupported"
  | Base_address_selection_entry _, Location_list_entry _ -> -1
  | Location_list_entry _, Base_address_selection_entry _ -> 1
  | Location_list_entry entry1, Location_list_entry entry2 ->
    compare entry1.beginning_address_label entry2.beginning_address_label