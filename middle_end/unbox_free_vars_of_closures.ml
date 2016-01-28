(**************************************************************************)
(*                                                                        *)
(*                                OCaml                                   *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file ../LICENSE.       *)
(*                                                                        *)
(**************************************************************************)

let pass_name = "unbox-free-vars-of-closures"
let () = Pass_wrapper.register ~pass_name

let run ~env ~(set_of_closures : Flambda.set_of_closures) =
  if !Clflags.classic_inlining then
    None
  else
    let funs, projection_defns, free_vars, done_something =
      Variable.Map.fold (fun fun_var
            (function_decl : Flambda.function_declaration)
            (funs, projection_defns, additional_free_vars, done_something) ->
          if function_decl.stub then
            funs, projection_defns, additional_free_vars, done_something
          else
            let extracted =
              let which_variables =
                Variable.Map.map (fun outer_var ->
                    let spec_to : Flambda.specialised_to =
                      { var = outer_var;
                        projectee = None;
                      }
                    in
                    spec_to)
                  set_of_closures.free_vars
              in
              Extract_projections.from_function_decl ~env ~function_decl
                ~which_variables
            in
            match extracted with
            | None ->
              funs, projection_defns, additional_free_vars, done_something
            | Some extracted ->
              let function_decl =
                Flambda.create_function_declaration
                  ~params:function_decl.params
                  ~body:function_decl.body
                  ~stub:function_decl.stub
                  ~dbg:function_decl.dbg
                  ~inline:function_decl.inline
                  ~is_a_functor:function_decl.is_a_functor
              in
Format.eprintf "UFV: new function decl %a\n%!"
  Flambda.print_function_declaration (fun_var, function_decl);
              let funs = Variable.Map.add fun_var function_decl funs in
              let projection_defns =
                Variable.Map.disjoint_union projection_defns
                  extracted.projection_defns_indexed_by_outer_vars
              in
              (* CR-soon mshinwell: Do the specialised_to thing for free_vars
                 as well. *)
              let new_inner_to_new_outer_vars =
                Variable.Map.map (fun (spec_to : Flambda.specialised_to) ->
                    spec_to.var)
                  extracted.new_inner_to_new_outer_vars
              in
              let additional_free_vars =
                try
                  Variable.Map.disjoint_union additional_free_vars
                    new_inner_to_new_outer_vars
                    ~eq:Variable.equal
                with _exn ->
                  Misc.fatal_errorf "Unbox_free_vars_of_closures: non-disjoint \
                      [free_vars] sets: %a vs. %a"
                    (Variable.Map.print Variable.print) additional_free_vars
                    (Variable.Map.print Variable.print)
                      set_of_closures.free_vars
              in
              funs, projection_defns, additional_free_vars, true)
        set_of_closures.function_decls.funs
        (Variable.Map.empty, Variable.Map.empty,
          set_of_closures.free_vars, false)
    in
    if not done_something then
      None
    else
      let function_decls =
        Flambda.update_function_declarations set_of_closures.function_decls
          ~funs
      in
      let set_of_closures =
        Flambda.create_set_of_closures ~function_decls ~free_vars
          ~specialised_args:set_of_closures.specialised_args
      in
      let expr =
        Variable.Map.fold (fun _projected_from projection_defns expr ->
            Variable.Map.fold Flambda.create_let projection_defns expr)
          projection_defns
          (Flambda_utils.name_expr (Set_of_closures set_of_closures)
            ~name:"unbox_free_vars_of_closures")
      in
      Some expr

let run ~env ~set_of_closures =
  Pass_wrapper.with_dump ~pass_name ~input:set_of_closures
    ~print_input:Flambda.print_set_of_closures
    ~print_output:Flambda.print
    ~f:(fun () -> run ~env ~set_of_closures)
