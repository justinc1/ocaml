(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

let constant_field ((expr : Flambda.t), provenance)
      : (Flambda.constant_defining_value_block_field
          * Flambda.symbol_provenance option) option =
  match expr with
  | Let { var; defining_expr = Normal (Const c); body = Var var' ; _ } ->
    assert(Variable.equal var var');
    (* This must be true since var is the only variable in scope *)
    Some (Flambda.Const c, provenance)
  | Let { var; defining_expr = Normal (Symbol s); body = Var var' ; _ } ->
    assert(Variable.equal var var');
    Some (Flambda.Symbol s, provenance)
  | _ ->
    None

let rec loop (program : Flambda.program_body) : Flambda.program_body =
  match program with
  | Initialize_symbol (symbol, tag, fields, program) ->
    let constant_fields =
      List.map constant_field fields
    in
    begin
      match Misc.Stdlib.List.some_if_all_elements_are_some constant_fields
    with
    | None ->
      Initialize_symbol (symbol, tag, fields, loop program)
    | Some fields ->
      let fields, provenances = List.split fields in
      (* For the moment just pick the provenance info from the first field. *)
      let provenance =
        match provenances with
        | provenance::_ -> provenance
        | [] -> Misc.fatal_error "Initialize_symbol with no fields"
      in
      Let_symbol (symbol, provenance, Block (tag, fields), loop program)
    end
  | Let_symbol (symbol, provenance, const, program) ->
    Let_symbol (symbol, provenance, const, loop program)
  | Let_rec_symbol (defs, program) ->
    Let_rec_symbol (defs, loop program)
  | Effect (expr, program) ->
    Effect (expr, loop program)
  | End symbol ->
    End symbol

let run (program : Flambda.program) =
  { program with
    program_body = loop program.program_body;
  }
