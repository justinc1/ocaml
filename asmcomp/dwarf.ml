(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2013--2014, Jane Street Holding                          *)
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

open Dwarf_low_dot_std.Dwarf_low

module Available_subrange = Available_ranges.Available_subrange
module Available_range = Available_ranges.Available_range
module String = struct
  include String
  module Set = Set.Make (String)
end

(* DWARF-related state for a single compilation unit. *)
type t = {
  compilation_unit_proto_die : Proto_DIE.t;
  emitter : Emitter.t;
  debug_loc_table : Debug_loc_table.t;
  debug_line_label : Linearize.label;
  start_of_code_symbol : string;
  end_of_code_symbol : string;
  start_of_data_symbol : string;
  source_file_path : string;
  mutable available_ranges_and_fundecl
    : (Available_ranges.t * Linearize.fundecl) option;
  mutable externally_visible_functions : string list;
  mutable have_emitted_dwarf_for_mangled_names : String.Set.t;
  mutable emitted : bool;
  mutable module_value_bindings
    : (Path.t * Ident.t * Types.type_expr * Ident.t * int) list;
  mutable global_approx : Clambda.value_approximation array;
  fundecl_proto_die_cache : (string, Proto_DIE.t) Hashtbl.t;
}

let create ~source_file_path ~emit_string ~emit_symbol ~emit_label
      ~emit_label_declaration ~emit_section_declaration
      ~emit_switch_to_section ~start_of_code_symbol ~end_of_code_symbol
      ~target ~module_value_bindings ~start_of_data_symbol =
  let emitter =
    Emitter.create ~emit_string
      ~emit_symbol
      ~emit_label
      ~emit_label_declaration
      ~emit_section_declaration
      ~emit_switch_to_section
      ~target
  in
  let debug_line_label = Linearize.new_label () in
  let source_file_path, directory =
    match source_file_path with
    (* CR-soon mshinwell: think about the source file path stuff *)
    | None -> "<unknown>", Sys.getcwd ()
    | Some path ->
      if Filename.is_relative path then
        let dir = Sys.getcwd () in
        Filename.concat dir path, dir
      else
        path, Filename.dirname path
  in
  let compilation_unit_proto_die =
    let attribute_values =
      let producer_name = Printf.sprintf "ocamlopt %s" Sys.ocaml_version in [
        Attribute_value.create_producer ~producer_name;
        Attribute_value.create_name source_file_path;
        Attribute_value.create_comp_dir ~directory;
        Attribute_value.create_low_pc_from_symbol ~symbol:start_of_code_symbol;
        Attribute_value.create_high_pc_from_symbol ~symbol:end_of_code_symbol;
        Attribute_value.create_stmt_list
          ~section_offset_label:
            (Section_names.starting_label Section_names.debug_line);
      ]
    in
    Proto_DIE.create ~parent:None
      ~tag:Tag.compile_unit
      ~attribute_values
  in
  let debug_loc_table = Debug_loc_table.create () in
  { compilation_unit_proto_die;
    externally_visible_functions = [];
    emitter;
    debug_loc_table;
    debug_line_label;
    start_of_code_symbol;
    end_of_code_symbol;
    start_of_data_symbol;
    source_file_path;
    available_ranges_and_fundecl = None;
    have_emitted_dwarf_for_mangled_names = String.Set.empty;
    emitted = false;
    module_value_bindings;
    global_approx = [| |];
    fundecl_proto_die_cache = Hashtbl.create 42;
  }

(* Build a new DWARF type for [ident].  Each identifier has its
   own type, which is basically its stamped name, and is nothing to do with
   its inferred OCaml type.  The inferred type may be recovered by the
   debugger by extracting the stamped name and then using that as a key
   for lookup into the .cmt file for the appropriate module. *)
let create_type_proto_die ~parent ~ident ~source_file_path =
  let ident =
    match ident with
    | `Ident ident -> Ident.unique_name ident
    | `Unique_name name -> name
  in
  Proto_DIE.create ~parent
    ~tag:Tag.base_type
    ~attribute_values:[
      Attribute_value.create_name ("__ocaml" ^ source_file_path ^ " " ^ ident);
      Attribute_value.create_encoding ~encoding:Encoding_attribute.signed;
      Attribute_value.create_byte_size ~byte_size:Arch.size_addr;
    ]

let die_name_from_function_name fun_name =
  "camlDIE__" ^ fun_name

let dots_to_double_underscores path_as_string =
  let num_dots = ref 0 in
  let length = String.length path_as_string in
  for i = 0 to length - 1 do
    if String.get path_as_string i = '.' then incr num_dots
  done;
  let num_dots = !num_dots in
  if num_dots < 1 then
    path_as_string
  else begin
    let new_path_as_string = Bytes.create (length + num_dots) in
    let pos = ref 0 in
    for i = 0 to length - 1 do
      let chr = String.get path_as_string i in
      if chr <> '.' then
        Bytes.set new_path_as_string !pos chr
      else begin
        Bytes.set new_path_as_string !pos '_';
        incr pos;
        Bytes.set new_path_as_string !pos '_'
      end;
      incr pos
    done;
    Bytes.to_string new_path_as_string
  end

let path_to_mangled_name path =
  let rec traverse_path = function
    | Path.Pident ident -> Some (Ident.name ident)
    (* CR-someday mshinwell: handle [Papply] *)
    | Path.Papply _ -> None
    | Path.Pdot (path, component, _) ->
      match traverse_path path with
      | None -> None
      | Some path -> Some (path ^ "__" ^ component)
  in
  match traverse_path path with
  | None -> None
  | Some path ->
    match !Clflags.for_package with
    | None -> Some ("caml" ^ path)
    | Some pack ->
      (* [pack] may contain a dot; if so, it must be replaced by the
         double underscore encoding. *)
      let pack = dots_to_double_underscores pack in
      Some (Printf.sprintf "caml%s__%s" pack path)

(* Create DWARF to describe a structure member that has no corresponding
   fundecl.  The member may still be a function: for example, [g] in the
   case where [f] has a fundecl and the user writes [let g = f].  For these
   cases we use the global approximation constructed during closure conversion
   to emit DWARF describing functions rather than plain variables.  This is
   important to ensure debugger functionality (e.g. setting breakpoints) works
   correctly.
   If the function returns [Some (new_sym, old_sym)] then assembly must be
   emitted to define a global function symbol [new_sym] whose value is equal
   to [old_sym].  (This is required since the presence of a subprogram DIE
   alone does not seem to be sufficient for gdb to identify a function, which
   is unfortunate.)
   This function is only for structures in the static data section, not
   heap-allocated structures, since the (relocatable) addresses of the members
   are written directly into the DWARF. *)
let create_dwarf_for_non_fundecl_structure_member t ~path ~ident ~typ:_ ~global
      ~pos ~parent =
  match path_to_mangled_name path with
  | None -> None
  | Some path ->
    match path_to_mangled_name (Path.Pident global) with
    | None -> None
    | Some global ->
      let name = path ^ "__" ^ (Ident.unique_name ident) in
      assert (pos >= 0 && pos < Array.length t.global_approx);
      (* This next check excludes the members with fundecls, for which we
         have already constructed proto-DIEs. *)
      if String.Set.mem name t.have_emitted_dwarf_for_mangled_names then
        None
      else begin
        let module C = Clambda in
        match t.global_approx.(pos) with
        | C.Value_closure (fun_desc, _) ->
          (* The member is actually a function.  (The fundecl may not actually
             be in the compilation unit currently being emitted...) *)
          let fun_name = fun_desc.C.fun_label in
          begin
            try
              let subprogram_proto_die =
                Hashtbl.find t.fundecl_proto_die_cache fun_name
              in
              (* If we get here, the fundecl corresponding to the member must
                 be in the current compilation unit.
                 DW_TAG_imported_declaration (DWARF-4 spec section 3.2.3)
                 doesn't seem to work properly in gdb, so just duplicate the
                 proto-DIE and change its name.
              *)
              let subprogram_proto_die =
                Proto_DIE.duplicate_as_sibling subprogram_proto_die
              in
              Proto_DIE.change_name_attribute_value subprogram_proto_die
                ~new_name:(Ident.name ident)
            with Not_found -> begin
              (* The function declaration is in another compilation unit. *)
              let die_symbol = die_name_from_function_name fun_name in
              Proto_DIE.create_ignore
                ~parent:(Some t.compilation_unit_proto_die)
                ~tag:Tag.subprogram
                ~attribute_values:[
                  Attribute_value.create_name name;
                  Attribute_value.create_specification_different_unit
                    ~die_symbol;
                ]
            end
          end;
          Some (name, fun_name)  (* see comment above *)
        | C.Value_tuple _
        | C.Value_unknown
        (* CR-soon mshinwell: in the [Value_const] case, describe a constant. *)
        | C.Value_const _
        | C.Value_global_field (_, _) ->
          (* The member is either of unknown approximation or a non-function,
             in which case it is described in DWARF as a normal variable. *)
          let type_proto_die =
            create_type_proto_die ~parent:(Some t.compilation_unit_proto_die)
              ~ident:(`Ident ident) ~source_file_path:t.source_file_path
          in
          (* For the moment, just deem these values to be accessible always,
             even before the module initializers have been run.  (Before
             the initializers have run they will be printed as "()" in the
             debugger.) *)
          let single_location_description =
            let simple_location_description =
              Simple_location_description.at_offset_from_symbol
                ~base:t.start_of_data_symbol
                ~symbol:global
                ~offset_in_bytes:(pos * Arch.size_addr)
            in
            Single_location_description.of_simple_location_description
              simple_location_description
          in
          Proto_DIE.create_ignore ~parent:(Some parent)
            ~tag:Tag.variable
            ~attribute_values:[
              Attribute_value.create_name name;
              Attribute_value.create_type
                ~proto_die:(Proto_DIE.reference type_proto_die);
              Attribute_value.create_single_location_description
                single_location_description;
              Attribute_value.create_external ~is_visible_externally:true;
            ];
          None
      end

let pre_emission_dwarf_for_function t ~fundecl =
  if t.available_ranges_and_fundecl <> None then begin
    failwith "Dwarf.pre_emission_dwarf_for_function"
  end;
  let name = fundecl.Linearize.fun_name in
  assert (not (String.Set.mem name t.have_emitted_dwarf_for_mangled_names));
  t.have_emitted_dwarf_for_mangled_names
    <- String.Set.add name t.have_emitted_dwarf_for_mangled_names;
  let available_ranges, fundecl = Available_ranges.create ~fundecl in
  t.available_ranges_and_fundecl <- Some (available_ranges, fundecl);
  fundecl

let location_list_entry ~fundecl ~available_subrange =
  let reg = Available_subrange.reg available_subrange in
  let location_expression =
    let module LE = Location_expression in
    match reg.Reg.loc with
    | Reg.Unknown -> assert false  (* probably a bug in available_regs.ml *)
    | Reg.Reg reg_number -> Some (LE.in_register reg_number)
    | Reg.Stack _ ->
      match Available_subrange.offset_from_stack_ptr available_subrange with
      | None -> assert false  (* emit.mlp should have set the offset *)
      | Some offset_in_bytes ->
        Some (LE.at_offset_from_stack_pointer ~offset_in_bytes)
  in
  match location_expression with
  | None -> None
  | Some location_expression ->
    (* CR-someday: rename to "_when_available". *)
    let first_address_when_in_scope =
      Available_subrange.start_pos available_subrange
    in
    let first_address_when_not_in_scope =
      Available_subrange.end_pos available_subrange
    in
    let entry =
      Location_list_entry.create_location_list_entry
        ~start_of_code_symbol:fundecl.Linearize.fun_name
        ~first_address_when_in_scope
        ~first_address_when_not_in_scope
        ~location_expression
    in
    Some entry

let dwarf_for_identifier t ~fundecl ~function_proto_die ~lexical_block_cache
      ~ident ~is_unique ~range =
  let (start_pos, end_pos) as cache_key = Available_range.extremities range in
  let parent_proto_die =
    if Available_range.is_parameter range then begin
      (* Parameters need to be children of the function in question. *)
      function_proto_die
    end else begin
      (* Local variables need to be children of "lexical blocks", which in turn
         are children of the function.  We use a cache to avoid creating more
         than one proto-DIE for any given lexical block position and size. *)
      try Hashtbl.find lexical_block_cache cache_key
      with Not_found -> begin
        let lexical_block_proto_die =
          Proto_DIE.create ~parent:(Some function_proto_die)
            ~tag:Tag.lexical_block
            ~attribute_values:[
              Attribute_value.create_low_pc ~address_label:start_pos;
              Attribute_value.create_high_pc ~address_label:end_pos;
            ]
        in
        Hashtbl.add lexical_block_cache cache_key lexical_block_proto_die;
        lexical_block_proto_die
      end
    end
  in
  (* Build a location list that identifies where the value of [ident] may be
     found at runtime, indexed by program counter range, and insert the list
     into the .debug_loc table. *)
  let location_list_attribute_value =
    (* DWARF-4 spec 2.6.2: "In the case of a compilation unit where all of the
       machine code is contained in a single contiguous section, no base
       address selection entry is needed."
       However, we tried this (and emitted plain label addresses rather than
       deltas in [Location_list_entry]), and the addresses were wrong in the
       final executable.  Oh well. *)
    let base_address_selection_entry =
      Location_list_entry.create_base_address_selection_entry
        ~base_address_symbol:fundecl.Linearize.fun_name
    in
    let location_list_entries =
      Available_range.fold range
        ~init:[]
        ~f:(fun location_list_entries ~available_subrange ->
           match location_list_entry ~fundecl ~available_subrange with
           | None -> location_list_entries
           | Some entry -> entry::location_list_entries)
    in
    let location_list =
      Location_list.create
        (base_address_selection_entry :: location_list_entries)
    in
    Debug_loc_table.insert t.debug_loc_table ~location_list
  in
  let type_proto_die =
    create_type_proto_die ~parent:(Some t.compilation_unit_proto_die)
      ~ident:(`Ident ident) ~source_file_path:t.source_file_path
  in
  (* If the unstamped name of [ident] is unambiguous within the function,
     then use it; otherwise, emit the stamped name. *)
  let name_for_ident =
    if is_unique then Ident.name ident else Ident.unique_name ident
  in
  let tag =
    if Available_range.is_parameter range then Tag.formal_parameter
    else Tag.variable
  in
  Proto_DIE.create_ignore ~parent:(Some parent_proto_die)
    ~tag
    ~attribute_values:[
      Attribute_value.create_name name_for_ident;
      Attribute_value.create_type
        ~proto_die:(Proto_DIE.reference type_proto_die);
      location_list_attribute_value;
    ]

let post_emission_dwarf_for_function t ~end_of_function_label =
  match t.available_ranges_and_fundecl with
  | None -> failwith "Dwarf.post_emission_dwarf_for_function"
  | Some (available_ranges, fundecl) ->
    let lexical_block_cache = Hashtbl.create 42 in
    let fun_name = fundecl.Linearize.fun_name in
    let type_proto_die =
      create_type_proto_die ~parent:(Some t.compilation_unit_proto_die)
        ~ident:(`Unique_name fun_name)
        ~source_file_path:t.source_file_path
    in
    (* Functions are described in two parts:
       - a "specification" (using DW_AT_specification) which contains all
         attribute values except for the name;
       - a DIE that references the specification.
       The reason for this division is so that we can reference the
       function's attribute values from a DIE in another compilation unit,
       but under a different name.  (For example if another compilation
       unit B binds a member of a structure to a function in the current
       unit A: in b.ml, "let bar = A.foo".)  See above. *)
    let specification_proto_die =
      Proto_DIE.create ~parent:(Some t.compilation_unit_proto_die)
        ~tag:Tag.subprogram
        ~attribute_values:[
          Attribute_value.create_external ~is_visible_externally:true;
          Attribute_value.create_low_pc_from_symbol
            ~symbol:fundecl.Linearize.fun_name;
          Attribute_value.create_high_pc ~address_label:end_of_function_label;
          Attribute_value.create_type
            ~proto_die:(Proto_DIE.reference type_proto_die);
        ]
    in
    (* CR-someday mshinwell: we probably don't need to add names (and hence
       global symbols) for functions not exported in the .mli for the current
       unit. *)
    (* The name of the specification DIE is used to reference it from other
       units. *)
    Proto_DIE.set_name specification_proto_die
      (die_name_from_function_name fun_name);
    let subprogram_proto_die =  (* "subprogram" means "function" for us. *)
      Proto_DIE.create ~parent:(Some t.compilation_unit_proto_die)
        ~tag:Tag.subprogram
        ~attribute_values:[
          Attribute_value.create_name fun_name;
          Attribute_value.create_specification_same_unit
            ~proto_die:(Proto_DIE.reference specification_proto_die);
        ]
    in
    (* For each identifier for which we have available ranges, construct
       DWARF information to describe how to access the values of such
       identifiers, indexed by program counter ranges. *)
    Available_ranges.fold available_ranges
      ~init:()
      ~f:(fun () -> dwarf_for_identifier t ~fundecl
        ~function_proto_die:subprogram_proto_die ~lexical_block_cache);
    Hashtbl.add t.fundecl_proto_die_cache fun_name subprogram_proto_die;
    t.externally_visible_functions
      <- fundecl.Linearize.fun_name::t.externally_visible_functions;
    t.available_ranges_and_fundecl <- None

let set_global_approx t ~global_approx =
  t.global_approx <- global_approx

let emit t =
  assert (not t.emitted);
  t.emitted <- true;
  let sym_aliases =
    ListLabels.fold_left t.module_value_bindings ~init:[]
      ~f:(fun sym_aliases (path, ident, typ, global, pos) ->
        let maybe_sym_alias =
          create_dwarf_for_non_fundecl_structure_member ~path ~ident ~typ
            ~global ~pos ~parent:t.compilation_unit_proto_die t
        in
        match maybe_sym_alias with
        | None -> sym_aliases
        | Some alias -> alias::sym_aliases)
  in
  let debug_info =
    Debug_info_section.create ~compilation_unit:t.compilation_unit_proto_die
  in
  Debug_info_section.assign_abbreviations debug_info;
  let _pubnames_table =
    Pubnames_table.create
      ~externally_visible_functions:t.externally_visible_functions
      ~debug_info
  in
  let aranges_table =
    Aranges_table.create ~start_of_code_symbol:t.start_of_code_symbol
      ~end_of_code_symbol:t.end_of_code_symbol
  in
  let module SN = Section_names in
  let emitter = t.emitter in
  Emitter.emit_switch_to_section emitter ~section_name:SN.text;
  ListLabels.iter sym_aliases ~f:(fun (new_sym, old_sym) ->
    Emitter.emit_symbol_alias emitter ~old_sym ~new_sym);
  ListLabels.iter SN.all ~f:(fun section_name ->
    Emitter.emit_section_declaration emitter ~section_name);
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_info;
  let debug_abbrev = Debug_info_section.emit debug_info ~emitter in
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_abbrev;
  Abbreviations_table.emit debug_abbrev ~emitter;
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_aranges;
  Aranges_table.emit aranges_table ~emitter;
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_loc;
  Debug_loc_table.emit t.debug_loc_table ~emitter;
  Emitter.emit_switch_to_section emitter ~section_name:SN.debug_str;
  Emitter.emit_strings emitter
