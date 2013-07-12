(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2013, Jane Street Holding                                *)
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

open Std_internal

module Location_list_entry = struct
  type t = {
    start_of_code_label : string;
    beginning_address_label : string;
    ending_address_label : string;
    expr : Location_expression.t;
  }

  let create ~start_of_code_label
             ~first_address_when_in_scope
             ~first_address_when_not_in_scope
             ~location_expression =
    { start_of_code_label;
      beginning_address_label = first_address_when_in_scope;
      ending_address_label = first_address_when_not_in_scope;
      expr = location_expression;
    }

  let expr_size t = Location_expression.size t.expr

  (* CR mshinwell: probably only correct for 64 bit *)
  let size t = 8 + 8 + 2 + (expr_size t)

  let emit t ~emitter =
    Value.emit
      (Value.as_code_address_from_label_diff
        t.beginning_address_label t.start_of_code_label)
      ~emitter;
    Value.emit
      (Value.as_code_address_from_label_diff
        t.ending_address_label t.start_of_code_label)
      ~emitter;
    Value.emit (Value.as_two_byte_int (expr_size t)) ~emitter;
    Location_expression.emit t.expr ~emitter
end

module Base_address_selection_entry = struct
  type t = string

  let create ~base_address_label = base_address_label

  let to_dwarf_values t =
    let largest_code_address = Int64.minus_one in
    [Value.as_code_address largest_code_address;
     Value.as_code_address_from_label t;
    ]

  let size t =
    List.fold (to_dwarf_values t)
      ~init:0
      ~f:(fun acc v -> acc + Value.size v)

  let emit t ~emitter =
    List.iter (to_dwarf_values t) ~f:(Value.emit ~emitter)
end

type t =
  | Location_list_entry of Location_list_entry.t
  | Base_address_selection_entry of Base_address_selection_entry.t

let create_location_list_entry ~start_of_code_label
                               ~first_address_when_in_scope
                               ~first_address_when_not_in_scope
                               ~location_expression =
  Location_list_entry (
    Location_list_entry.create ~start_of_code_label
      ~first_address_when_in_scope
      ~first_address_when_not_in_scope
      ~location_expression)

let create_base_address_selection_entry ~base_address_label =
  Base_address_selection_entry (
    Base_address_selection_entry.create ~base_address_label)

let size = function
  | Location_list_entry entry ->
    Location_list_entry.size entry
  | Base_address_selection_entry entry ->
    Base_address_selection_entry.size entry

let emit t ~emitter =
  match t with
  | Location_list_entry entry ->
    Location_list_entry.emit entry ~emitter
  | Base_address_selection_entry entry ->
    Base_address_selection_entry.emit entry ~emitter
