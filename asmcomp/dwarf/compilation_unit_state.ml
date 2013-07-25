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

(* CR-soon mshinwell: fix uses of [open] *)
open Dwarf_low_dot_std
open Dwarf_low
open Std_internal

type t = {
  emitter : Emitter.t;
  source_file_path : string option;
  start_of_code_label : string;
  end_of_code_label : string;
  mutable externally_visible_functions : string list;
  mutable function_tags :
    (int * string * Tag.t * Dwarf_low.Attribute_value.t list) list;
  mutable debug_loc_table : Debug_loc_table.t;
}

let create ~emitter ~source_file_path ~start_of_code_label ~end_of_code_label =
  { emitter;
    source_file_path;
    start_of_code_label;
    end_of_code_label;
    externally_visible_functions = [];
    function_tags = [];
    debug_loc_table = Debug_loc_table.create ();
  }

let builtin_ocaml_type_label_value = "type_value"

let build_ocaml_type_tags () = [
  1, builtin_ocaml_type_label_value, Dwarf_low.Tag.base_type, [
    Dwarf_low.Attribute_value.create_name ~source_file_path:"value";
    Dwarf_low.Attribute_value.create_encoding
      ~encoding:Dwarf_low.Encoding_attribute.signed;
    Dwarf_low.Attribute_value.create_byte_size
      ~byte_size:8;
  ];
]

module Function = struct
  type t = string  (* function name, ahem *)
end

module Reg_location = struct
  type t = [
  | `Hard_register of int
  | `Stack of unit
  ]

  let hard_register ~reg_num = `Hard_register reg_num
  let stack () = `Stack ()
end

let start_function t ~linearized_fundecl =
  let function_name = linearized_fundecl.Linearize.fun_name in
  (* CR mshinwell: sort this source_file_path stuff out *)
  if t.source_file_path = None then function_name, linearized_fundecl else
  let starting_label = sprintf "Llr_begin_%s" function_name in
  let ending_label = sprintf "Llr_end_%s" function_name in
  Emitter.emit_label_declaration t.emitter starting_label;
  let live_ranges, fundecl =
    (* note that [process_fundecl] may modify [linearize_fundecl] *)
    Live_ranges.process_fundecl linearized_fundecl
  in
  let debug_loc_table, live_range_tags =
    List.fold live_ranges
      ~init:(t.debug_loc_table, [])
      ~f:(fun (debug_loc_table, live_range_tags) live_range ->
            let name = Live_ranges.One_live_range.unique_name live_range in
            let tag, attribute_values, debug_loc_table =
              (* CR mshinwell: should maybe return an option instead *)
              Live_ranges.One_live_range.to_dwarf live_range
                ~builtin_ocaml_type_label_value
                ~debug_loc_table
            in
            match attribute_values with
            | [] -> debug_loc_table, live_range_tags
            | _ ->
              let live_range_tag =
                2, function_name ^ "__var__" ^ name, tag, attribute_values
              in
              debug_loc_table, live_range_tag::live_range_tags)
  in
  let subprogram_tag =
    let tag =
      if List.length live_range_tags > 0 then
        Tag.subprogram
      else
        Tag.subprogram_with_no_children
    in
    let module AV = Attribute_value in
    1, function_name, tag, [
      AV.create_name ~source_file_path:function_name;
      AV.create_external ~is_visible_externally:true;
      AV.create_low_pc ~address_label:starting_label;
      AV.create_high_pc ~address_label:ending_label;
    ]
  in
  let this_function's_tags = subprogram_tag::(List.rev live_range_tags) in
  t.externally_visible_functions <-
    function_name::t.externally_visible_functions;
  t.debug_loc_table <- debug_loc_table;
  t.function_tags <- t.function_tags @ this_function's_tags;
  function_name, fundecl

(*
let start_function t ~function_name ~arguments_and_locations =
  let starting_label = sprintf "Llr_begin_%s" function_name in
  let ending_label = sprintf "Llr_end_%s" function_name in
  Emitter.emit_label_declaration t.emitter starting_label;
  let debug_loc_table, argument_tags =
    List.fold arguments_and_locations
      ~init:(t.debug_loc_table, [])
      ~f:(fun (debug_loc_table, tags) (ident, pseudoreg_location) ->
            let location_expression =
              match pseudoreg_location with
              (* CR mshinwell: fix the stack case *)
              | `Stack () -> None
              | `Hard_register reg_number ->
                Some (Dwarf_low.Location_expression.in_register reg_number)
            in
            match location_expression with
            | None -> debug_loc_table, tags
            | Some location_expression ->
              let base_address_selection_entry =
                Dwarf_low.Location_list_entry.
                  create_base_address_selection_entry
                  ~base_address_label:starting_label
              in
              let location_list_entry =
                Dwarf_low.Location_list_entry.create_location_list_entry
                  ~start_of_code_label:starting_label
                  ~first_address_when_in_scope:starting_label
                  ~first_address_when_not_in_scope:ending_label  (* fixme *)
                  ~location_expression
              in
              let location_list =
                Dwarf_low.Location_list.create
                  [base_address_selection_entry; location_list_entry]
              in
              let debug_loc_table, loclistptr_attribute_value =
                Dwarf_low.Debug_loc_table.insert debug_loc_table
                  ~location_list
              in
              let arg_name = Ident.name ident in
              let tag =
                2, function_name ^ "__arg__" ^ (Ident.unique_name ident),
                  Dwarf_low.Tag.formal_parameter,
                  [Dwarf_low.Attribute_value.create_name
                     ~source_file_path:arg_name;
                   loclistptr_attribute_value;
                   Dwarf_low.Attribute_value.create_type
                     ~label_name:builtin_ocaml_type_label_value;
                  ]
              in
              debug_loc_table, tag::tags)
  in
  let subprogram_tag =
    let tag =
      if List.length argument_tags > 0 then
        Tag.subprogram
      else
        Tag.subprogram_with_no_children
    in
    let module AV = Attribute_value in
    1, function_name, tag, [
      AV.create_name ~source_file_path:function_name;
      AV.create_external ~is_visible_externally:true;
      AV.create_low_pc ~address_label:starting_label;
      AV.create_high_pc ~address_label:ending_label;
    ]
  in
  let this_function's_tags = subprogram_tag::(List.rev argument_tags) in
  t.externally_visible_functions <-
    function_name::t.externally_visible_functions;
  t.debug_loc_table <- debug_loc_table;
  t.function_tags <- t.function_tags @ this_function's_tags;
  function_name
*)

let end_function t function_name =
  Emitter.emit_label_declaration t.emitter (sprintf "Llr_end_%s" function_name)

let with_emitter emitter fs =
  List.iter (fun f -> f emitter) fs

let emit_debugging_info_prologue t =
  let module SN = Section_names in
  with_emitter t.emitter [
    Emitter.emit_section_declaration ~section_name:SN.debug_abbrev;
    Emitter.emit_label_declaration ~label_name:"Ldebug_abbrev0";
    Emitter.emit_section_declaration ~section_name:SN.debug_line;
    Emitter.emit_label_declaration ~label_name:"Ldebug_line0";
    Emitter.emit_section_declaration ~section_name:SN.debug_loc;
    Emitter.emit_label_declaration ~label_name:"Ldebug_loc0";
  ]

let emit_debugging_info_epilogue t =
  let emitter = t.emitter in
  let producer_name = sprintf "ocamlopt %s" Sys.ocaml_version in
  let compile_unit_attribute_values =
    let module AV = Attribute_value in
    let common = [
      AV.create_producer ~producer_name;
      AV.create_low_pc ~address_label:t.start_of_code_label;
      AV.create_high_pc ~address_label:t.end_of_code_label;
      AV.create_stmt_list ~section_offset_label:"Ldebug_line0";
      AV.create_comp_dir ~directory:(Sys.getcwd ());
    ]
    in
    match t.source_file_path with
    | None -> common
    | Some source_file_path -> (AV.create_name ~source_file_path)::common
  in
  let tags_with_attribute_values = [
    0, "compile_unit",
      Tag.compile_unit, compile_unit_attribute_values;
  ] @ (build_ocaml_type_tags ()) @ t.function_tags
  in
  let debug_info = Debug_info_section.create ~tags_with_attribute_values in
  let debug_abbrev = Debug_info_section.to_abbreviations_table debug_info in
  let pubnames_table =
    Pubnames_table.create
      ~externally_visible_functions:t.externally_visible_functions
      ~debug_info
  in
  let aranges_table =
    Aranges_table.create ~start_of_code_label:t.start_of_code_label
      ~end_of_code_label:t.end_of_code_label
  in
  let module SN = Section_names in
  (* CR-someday mshinwell: consider using [with_emitter] *)
  Emitter.emit_section_declaration emitter ~section_name:SN.debug_info;
  Emitter.emit_label_declaration emitter ~label_name:"Ldebug_info0";
  Debug_info_section.emit debug_info ~emitter;
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_abbrev;
  Abbreviations_table.emit debug_abbrev ~emitter;
  Emitter.emit_section_declaration emitter ~section_name:SN.debug_pubnames;
  Pubnames_table.emit pubnames_table ~emitter;
  Emitter.emit_section_declaration emitter ~section_name:SN.debug_aranges;
  Aranges_table.emit aranges_table ~emitter;
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_loc;
  Debug_loc_table.emit t.debug_loc_table ~emitter
