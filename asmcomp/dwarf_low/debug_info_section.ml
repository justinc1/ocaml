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

type t = {
  dies : Debugging_information_entry.t list;
}

let create ~tags_with_attribute_values =
  let rec create_terminators acc = function
    | 0 -> acc
    | n ->
      create_terminators (Debugging_information_entry.create_null () :: acc)
        (n - 1)
  in
  let next_abbreviation_code = ref 1 in
  (* CR mshinwell: the depth thing is nasty -- use a proper tree? *)
  let depth, dies =
    List.fold_left tags_with_attribute_values
      ~init:(0, [])
      ~f:(fun (current_depth, dies) 
              (depth, label_name, tag, attribute_values) ->
            let need_null_entry = depth < current_depth in
            let dies =
              if need_null_entry then
                create_terminators dies (current_depth - depth)
              else
                dies
            in
            let abbreviation_code =
              Abbreviation_code.of_int !next_abbreviation_code
            in
            next_abbreviation_code := !next_abbreviation_code + 1;
            let die =
              Debugging_information_entry.create ~label_name
                ~abbreviation_code
                ~tag
                ~attribute_values
            in
            depth, (die::dies))
  in
  Printf.printf "[INFO_SECTION] Needs to insert %d terminators\n%!" depth ;
  { dies = List.rev (create_terminators dies depth) }

let dwarf_version = Version.two
let debug_abbrev_offset =
  Value.as_four_byte_int_from_label "Ldebug_abbrev0"
let address_width_in_bytes_on_target = Value.as_byte 8

let size_without_first_word t =
  let total_die_size =
    List.fold_left t.dies
      ~init:0
      ~f:(fun size die -> size + Debugging_information_entry.size die)
  in
  Version.size dwarf_version
    + Value.size debug_abbrev_offset
    + Value.size address_width_in_bytes_on_target
    + total_die_size

let size t = 4 + size_without_first_word t

let emit t ~emitter =
  let size = size_without_first_word t in
  Value.emit (Value.as_four_byte_int size) ~emitter;
  Version.emit dwarf_version ~emitter;
  Value.emit debug_abbrev_offset ~emitter;
  Value.emit address_width_in_bytes_on_target ~emitter;
  List.iter t.dies ~f:(Debugging_information_entry.emit ~emitter)

let to_abbreviations_table t =
  let entries =
    List.fold_right t.dies
      ~init:[]
      ~f:(fun die entries ->
            match
              Debugging_information_entry.to_abbreviations_table_entry die
            with
            | None -> entries
            | Some entry -> entry::entries)
  in
  Abbreviations_table.create entries
